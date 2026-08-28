# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$StateRoot = 'C:\hci-state\cozystack-hci-lab',
    [string]$KubectlPath = 'C:\hci-tools\kubectl.exe',
    [int]$NamespaceTimeoutSeconds = 900,
    [int]$ControllerTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Namespace = 'cozy-network-fabric-controller'
$SecretName = 'network-fabric-talosconfig'
$SecretKey = 'talosconfig'
$ControllerName = 'network-fabric-controller'
$TalosconfigPath = Join-Path $StateRoot 'talosconfig'
$KubeconfigPath = Join-Path $StateRoot 'kubeconfig'

function Invoke-NativeText {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments=@()
    )

    $saved = $ErrorActionPreference
    $output = @()
    $exitCode = 1
    try {
        # Windows PowerShell 5.1 can promote native stderr to a terminating
        # NativeCommandError when ErrorActionPreference=Stop. Native exit code
        # remains authoritative while stderr is captured for non-secret errors.
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output += $_.Exception.Message
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $saved
    }

    [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = (($output | ForEach-Object { $_.ToString() }) -join "`n").TrimEnd()
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Condition,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
        [int]$IntervalSeconds = 5,
        [string]$Description = 'condition'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = @(& $Condition)
            if ($result.Count -gt 0 -and [bool]$result[-1]) { return }
        } catch {
            Write-Host "Transient error while waiting for ${Description}: $($_.Exception.Message)"
        }
        if ((Get-Date) -ge $deadline) { break }
        Write-Host "Waiting for $Description ..."
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Description"
}

function Get-KubectlObject {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)

    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @($Arguments + @('-o','json'))
    if ($probe.ExitCode -ne 0 -or -not $probe.Text) { return $null }
    try { return ($probe.Text | ConvertFrom-Json) } catch { return $null }
}

function Test-ReadyCondition {
    param([Parameter(Mandatory=$true)]$Object)

    if (-not $Object) { return $false }
    foreach ($condition in @($Object.status.conditions)) {
        if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') { return $true }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $KubectlPath -PathType Leaf)) {
    throw "kubectl missing: $KubectlPath"
}
if (-not (Test-Path -LiteralPath $KubeconfigPath -PathType Leaf)) {
    throw "kubeconfig missing: $KubeconfigPath"
}
if (-not (Test-Path -LiteralPath $TalosconfigPath -PathType Leaf)) {
    throw "Talos client configuration missing; refusing to create $Namespace/$SecretName"
}
if ((Get-Item -LiteralPath $TalosconfigPath).Length -le 0) {
    throw 'Talos client configuration is empty; refusing NetworkFabric credential reconciliation'
}

$env:KUBECONFIG = $KubeconfigPath

Wait-Until -TimeoutSeconds $NamespaceTimeoutSeconds -IntervalSeconds 5 -Description "namespace $Namespace" -Condition {
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','namespace',$Namespace,'-o','name')
    return ($probe.ExitCode -eq 0)
}

# Build the desired Secret entirely in memory. The payload is never emitted to
# stdout, an Actions artifact, a repository file, or a command-line argument.
$manifestProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @(
    'create','secret','generic',$SecretName,
    '--namespace',$Namespace,
    "--from-file=$SecretKey=$TalosconfigPath",
    '--dry-run=client',
    '-o','json'
)
if ($manifestProbe.ExitCode -ne 0 -or -not $manifestProbe.Text) {
    throw 'Failed to build NetworkFabric Talos Secret manifest in memory'
}

try {
    $desiredSecret = $manifestProbe.Text | ConvertFrom-Json
} catch {
    throw 'Generated NetworkFabric Talos Secret manifest is not valid JSON'
}
if (-not $desiredSecret.data -or -not $desiredSecret.data.$SecretKey) {
    throw "Generated Secret does not contain required key '$SecretKey'"
}

# Apply via stdin so secret data never appears in process arguments or logs.
$saved = $ErrorActionPreference
$applyOutput = @()
$applyExitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    $applyOutput = @($manifestProbe.Text | & $KubectlPath 'apply' '-f' '-' 2>&1)
    $applyExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $saved
}
if ($applyExitCode -ne 0) {
    # Do not echo kubectl stderr here because validation errors can include
    # serialized Secret content. Keep the failure fail-closed and payload-free.
    throw "NetworkFabric Talos Secret apply failed with exit code $applyExitCode"
}

$labelProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @(
    'label','secret',$SecretName,'--namespace',$Namespace,
    'app.kubernetes.io/managed-by=layersentry-hci-bootstrap',
    'layersentry.io/purpose=network-fabric-talos-client',
    '--overwrite'
)
if ($labelProbe.ExitCode -ne 0) {
    throw "NetworkFabric Talos Secret labeling failed with exit code $($labelProbe.ExitCode)"
}

# Re-read and compare the mounted source bytes without logging either value.
$actualSecret = Get-KubectlObject -Arguments @('get','secret','-n',$Namespace,$SecretName)
if (-not $actualSecret -or -not $actualSecret.data -or -not $actualSecret.data.$SecretKey) {
    throw 'NetworkFabric Talos Secret did not persist with the required key'
}
try {
    $actualBytes = [Convert]::FromBase64String([string]$actualSecret.data.$SecretKey)
} catch {
    throw 'NetworkFabric Talos Secret contains invalid base64 data'
}
$localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TalosconfigPath).Hash
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $actualHash = ([BitConverter]::ToString($sha.ComputeHash($actualBytes))).Replace('-','')
} finally {
    $sha.Dispose()
}
if ($actualHash -ne $localHash) {
    throw 'NetworkFabric Talos Secret does not match the preserved local Talos configuration'
}
Write-Host "Reconciled $Namespace/$SecretName from preserved local Talos state; credential payload suppressed."

Wait-Until -TimeoutSeconds $ControllerTimeoutSeconds -IntervalSeconds 10 -Description "HelmRelease $Namespace/$ControllerName Ready" -Condition {
    $hr = Get-KubectlObject -Arguments @('get','hr','-n',$Namespace,$ControllerName)
    return (Test-ReadyCondition -Object $hr)
}

Wait-Until -TimeoutSeconds $ControllerTimeoutSeconds -IntervalSeconds 10 -Description "deployment $Namespace/$ControllerName fully available" -Condition {
    $deployment = Get-KubectlObject -Arguments @('get','deployment','-n',$Namespace,$ControllerName)
    if (-not $deployment) { return $false }
    $desired = [int]$deployment.spec.replicas
    if ($desired -lt 1) { return $false }
    return (
        [int]$deployment.status.readyReplicas -eq $desired -and
        [int]$deployment.status.availableReplicas -eq $desired -and
        [int]$deployment.status.updatedReplicas -eq $desired
    )
}

Wait-Until -TimeoutSeconds $ControllerTimeoutSeconds -IntervalSeconds 10 -Description 'all NetworkFabric controller pods Ready' -Condition {
    $pods = Get-KubectlObject -Arguments @(
        'get','pods','-n',$Namespace,'-l','app.kubernetes.io/name=network-fabric-controller'
    )
    if (-not $pods -or @($pods.items).Count -lt 1) { return $false }
    foreach ($pod in @($pods.items)) {
        if ([string]$pod.status.phase -ne 'Running') { return $false }
        $ready = $false
        foreach ($condition in @($pod.status.conditions)) {
            if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') {
                $ready = $true
                break
            }
        }
        if (-not $ready) { return $false }
    }
    return $true
}

Write-Host 'NetworkFabric controller credential prerequisite and live readiness are verified.'
