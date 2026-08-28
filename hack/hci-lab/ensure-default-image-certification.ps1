# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$KubectlPath = 'C:\hci-tools\kubectl.exe',
    [string]$KubeconfigPath = 'C:\hci-state\cozystack-hci-lab\kubeconfig',
    [string]$EvidenceRoot = '',
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PackageName = 'cozystack.vm-default-images'
$PackageSourceName = 'cozystack.vm-default-images'
$ReleaseNamespace = 'cozy-system'
$ReleaseName = 'vm-default-images'
$PublicNamespace = 'cozy-public'
$StorageClass = 'replicated'
$ImageName = 'ubuntu-24.04'
$DataVolumeName = "vm-default-images-$ImageName"
$FixtureAnnotation = 'layersentry.io/hci-certification-default-image'
$FixtureAnnotationValue = 'true'
$ImageUrl = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img'

if (-not (Test-Path $KubectlPath)) { throw "kubectl missing: $KubectlPath" }
if (-not (Test-Path $KubeconfigPath)) { throw "kubeconfig missing: $KubeconfigPath" }
$env:KUBECONFIG = $KubeconfigPath

function Invoke-KubectlText {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    $output = @()
    $exitCode = 1
    try {
        # kubectl may write diagnostics such as "No resources found" to stderr
        # while returning success. Preserve the output, but judge success only
        # by the native exit code.
        $ErrorActionPreference = 'Continue'
        $output = @(& $KubectlPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output += $_.Exception.Message
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($output | Out-String).TrimEnd())
        Lines = $output
    }
}

function Invoke-Kubectl {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $result = Invoke-KubectlText -Arguments $Arguments
    if ($result.Text) { Write-Host $result.Text }
    if ($result.ExitCode -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed with exit code $($result.ExitCode)"
    }
}

function Get-KubectlObject {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $result = Invoke-KubectlText -Arguments @($Arguments + @('-o','json'))
    if ($result.ExitCode -ne 0 -or -not $result.Text) { return $null }
    try { return ($result.Text | ConvertFrom-Json) } catch { return $null }
}

function Test-ReadyCondition($Object) {
    if (-not $Object) { return $false }
    foreach ($condition in @($Object.status.conditions)) {
        if ([string]$condition.type -eq 'Ready' -and [string]$condition.status -eq 'True') {
            return $true
        }
    }
    return $false
}

function Wait-Until {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Condition,
        [Parameter(Mandatory=$true)][string]$Description,
        [int]$Timeout = $TimeoutSeconds,
        [int]$IntervalSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    $lastError = $null
    do {
        try {
            $result = @(& $Condition)
            if ($result.Count -gt 0 -and [bool]$result[-1]) { return }
        } catch {
            $lastError = $_.Exception.Message
            Write-Host "Transient error waiting for ${Description}: $lastError"
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)

    if ($lastError) { throw "Timed out waiting for $Description. Last error: $lastError" }
    throw "Timed out waiting for $Description"
}

function Get-BoundPlatformImagePvcs {
    $pvcs = Get-KubectlObject -Arguments @('get','pvc','-n',$PublicNamespace)
    if (-not $pvcs) { return @() }
    return @($pvcs.items | Where-Object {
        [string]$_.metadata.name -like 'vm-default-images-*' -and
        [string]$_.status.phase -eq 'Bound'
    })
}

function Write-Evidence {
    if (-not $EvidenceRoot) { return }
    New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
    $captures = @(
        @{ Name='default-image-package.txt'; Args=@('get','packages.cozystack.io',$PackageName,'-o','yaml') },
        @{ Name='default-image-helmrelease.txt'; Args=@('get','helmrelease.helm.toolkit.fluxcd.io','-n',$ReleaseNamespace,$ReleaseName,'-o','yaml') },
        @{ Name='default-image-datavolumes.txt'; Args=@('get','datavolumes.cdi.kubevirt.io','-n',$PublicNamespace,'-o','wide') },
        @{ Name='default-image-pvcs.txt'; Args=@('get','pvc','-n',$PublicNamespace,'-o','wide') },
        @{ Name='default-image-events.txt'; Args=@('get','events','-n',$PublicNamespace,'--sort-by=.lastTimestamp') }
    )
    foreach ($capture in $captures) {
        $result = Invoke-KubectlText -Arguments $capture.Args
        @("# kubectl $($capture.Args -join ' ')") + @($result.Lines) + @("# exit=$($result.ExitCode)") |
            Set-Content -Path (Join-Path $EvidenceRoot $capture.Name) -Encoding utf8
    }
}

Write-Host 'Validating product default-image prerequisites.'
$source = Get-KubectlObject -Arguments @('get','packagesources.cozystack.io',$PackageSourceName)
if (-not (Test-ReadyCondition $source)) {
    throw "$PackageSourceName PackageSource is not Ready; refusing to create a certification fixture."
}

$storageClassObject = Get-KubectlObject -Arguments @('get','storageclass',$StorageClass)
if (-not $storageClassObject) { throw "Required StorageClass '$StorageClass' does not exist." }
if ([string]$storageClassObject.provisioner -ne 'linstor.csi.linbit.com') {
    throw "StorageClass '$StorageClass' is not LINSTOR-backed; refusing certification fixture."
}

$existingBound = @(Get-BoundPlatformImagePvcs)
if ($existingBound.Count -gt 0) {
    Write-Host "A Bound product platform image already exists: $($existingBound[0].metadata.name). No fixture mutation required."
    Write-Evidence
    exit 0
}

$existingPackage = Get-KubectlObject -Arguments @('get','packages.cozystack.io',$PackageName)
if ($existingPackage) {
    $owned = [string]$existingPackage.metadata.annotations.$FixtureAnnotation
    if ($owned -ne $FixtureAnnotationValue) {
        Write-Host "$PackageName already exists without the LayerSentry certification ownership annotation. Waiting for its own image import without changing administrator-managed values."
        try {
            Wait-Until -Description 'an administrator-managed Bound vm-default-images PVC' -Condition {
                return (@(Get-BoundPlatformImagePvcs).Count -gt 0)
            }
            Write-Evidence
            exit 0
        } catch {
            Write-Evidence
            throw "$PackageName is administrator-managed but produced no Bound platform image within the timeout; refusing to overwrite it. $($_.Exception.Message)"
        }
    }
}

$packageYaml = @"
apiVersion: cozystack.io/v1alpha1
kind: Package
metadata:
  name: $PackageName
  annotations:
    $FixtureAnnotation: "$FixtureAnnotationValue"
spec:
  variant: default
  components:
    vm-default-images:
      values:
        storageClass: "$StorageClass"
        images:
          - name: $ImageName
            url: "$ImageUrl"
            storage: 20Gi
            os:
              family: Linux
              name: Ubuntu
              version: "24.04"
            architecture: amd64
            description: "Ubuntu 24.04 LTS certification image"
"@

$tempFile = Join-Path $env:TEMP "layersentry-default-image-$PID.yaml"
try {
    [IO.File]::WriteAllText($tempFile,$packageYaml,[Text.UTF8Encoding]::new($false))
    Invoke-Kubectl 'apply' '-f' $tempFile
} finally {
    Remove-Item -Force $tempFile -ErrorAction SilentlyContinue
}

Wait-Until -Description "$PackageName Package Ready" -Condition {
    Test-ReadyCondition (Get-KubectlObject -Arguments @('get','packages.cozystack.io',$PackageName))
}

Wait-Until -Description "$ReleaseNamespace/$ReleaseName HelmRelease Ready" -Condition {
    Test-ReadyCondition (Get-KubectlObject -Arguments @('get','helmrelease.helm.toolkit.fluxcd.io','-n',$ReleaseNamespace,$ReleaseName))
}

Wait-Until -Description "$PublicNamespace/$DataVolumeName DataVolume Succeeded" -Condition {
    $dv = Get-KubectlObject -Arguments @('get','datavolumes.cdi.kubevirt.io','-n',$PublicNamespace,$DataVolumeName)
    return ($dv -and [string]$dv.status.phase -eq 'Succeeded')
}

Wait-Until -Description "$PublicNamespace/$DataVolumeName PVC Bound on replicated storage" -Condition {
    $pvc = Get-KubectlObject -Arguments @('get','pvc','-n',$PublicNamespace,$DataVolumeName)
    return (
        $pvc -and
        [string]$pvc.status.phase -eq 'Bound' -and
        [string]$pvc.spec.storageClassName -eq $StorageClass
    )
}

$finalPackage = Get-KubectlObject -Arguments @('get','packages.cozystack.io',$PackageName)
if ([string]$finalPackage.metadata.annotations.$FixtureAnnotation -ne $FixtureAnnotationValue) {
    throw 'Certification fixture ownership annotation changed unexpectedly after reconciliation.'
}

Write-Evidence
Write-Host "Product default-image certification fixture PASS: $PublicNamespace/$DataVolumeName is Bound on $StorageClass."
