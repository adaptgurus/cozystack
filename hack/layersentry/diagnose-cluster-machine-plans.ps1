[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-cluster-machine-plan-diagnostic')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    [System.IO.File]::WriteAllText(
        $Path,
        $Value,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Protect-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            $fullControl,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Diagnostic request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'READ_ONLY_CLUSTER_MACHINE_PLAN_DIAGNOSTIC') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.primaryNodeAddress -ne '10.10.10.11') {
    throw 'The diagnostic primary node must be 10.10.10.11.'
}
if ([bool]$request.modifyClusterState) {
    throw 'The machine-plan diagnostic must not modify cluster state.'
}
if ([bool]$request.writeCredentialValuesToEvidence) {
    throw 'Credential values must not be written to evidence.'
}
if ([bool]$request.productionReleaseApprovalImplied) {
    throw 'A diagnostic request cannot imply production approval.'
}

$shellPath = Join-Path $PSScriptRoot 'diagnose-cluster-machine-plan-details.sh'
if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw "The detailed role-source collector is missing: $shellPath"
}
if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Protected credential file is missing: $CredentialPath"
}

$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nodePassword = [string]$credentials.nodePassword
if ([string]::IsNullOrWhiteSpace($nodePassword)) {
    throw 'Protected node password is missing.'
}
$nodePasswordB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))
[string[]]$sensitiveValues = @(
    [string]$credentials.nodePassword,
    [string]$credentials.clusterToken,
    [string]$credentials.adminPassword,
    $nodePasswordB64
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

function Protect-Text {
    param([AllowNull()][string]$Text)

    $safe = [string]$Text
    foreach ($secret in $sensitiveValues) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $safe = $safe.Replace($secret, '[REDACTED]')
        }
    }
    $safe = [regex]::Replace(
        $safe,
        '(?i)K10[a-z0-9]{20,}::server:[a-z0-9]{20,}',
        '[REDACTED-RKE2-TOKEN]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?im)^(\s*(?:token|password|authorization|credential|rke2_token)\s*[:=]).+$',
        '$1 [REDACTED]'
    )
    return $safe
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-machine-plan-detail-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $temporaryDirectory

$ssh = Get-Command -Name 'ssh.exe' -ErrorAction Stop | Select-Object -First 1
$passwordPath = Join-Path $temporaryDirectory 'node-password.txt'
$askPassPath = Join-Path $temporaryDirectory 'askpass.cmd'
$scriptPath = Join-Path $temporaryDirectory 'machine-plan-details.sh'
$stdoutPath = Join-Path $temporaryDirectory 'machine-plan-details.stdout.raw'
$stderrPath = Join-Path $temporaryDirectory 'machine-plan-details.stderr.raw'
Write-Utf8NoBom -Path $passwordPath -Value ($nodePassword + "`r`n")
Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$passwordPath`"`r`n")
$shellText = Get-Content -LiteralPath $shellPath -Raw -Encoding UTF8
$remoteText = "export LAYERSENTRY_NODE_PASSWORD_B64='$nodePasswordB64'`n" + $shellText
Write-Utf8NoBom -Path $scriptPath -Value (($remoteText -replace "`r`n", "`n").TrimStart([char]0xFEFF))

$oldAskPass = [Environment]::GetEnvironmentVariable('SSH_ASKPASS')
$oldAskPassRequire = [Environment]::GetEnvironmentVariable('SSH_ASKPASS_REQUIRE')
$oldDisplay = [Environment]::GetEnvironmentVariable('DISPLAY')
$env:SSH_ASKPASS = $askPassPath
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'LayerSentry'

$startedAt = (Get-Date).ToUniversalTime()
$exitCode = $null
$completed = $false
$failure = $null

try {
    $arguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'ConnectTimeout=15',
        'rancher@10.10.10.11',
        'bash', '-s'
    )
    $process = Start-Process `
        -FilePath $ssh.Source `
        -ArgumentList $arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardInput $scriptPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $exitCode = [int]$process.ExitCode
    $stdout = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
    $stderr = [string](Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
    $safeOutput = Protect-Text -Text ($stdout + "`n===ssh-stderr===`n" + $stderr)
    Write-Utf8NoBom `
        -Path (Join-Path $OutputDirectory 'cluster-machine-plan-details.txt') `
        -Value $safeOutput

    $completed = ($exitCode -eq 0 -and $stdout -match '(?m)^===DIAGNOSTIC-COMPLETE===\s*$')
    if (-not $completed) {
        throw "Detailed machine-plan diagnostic failed with SSH exit code $exitCode."
    }
    Write-Host 'LAYERSENTRY DETAILED MACHINE PLAN ROLE-SOURCE DIAGNOSTIC: PASS'
}
catch {
    $failure = [string]$_.Exception.Message
    throw
}
finally {
    $finishedAt = (Get-Date).ToUniversalTime()
    [ordered]@{
        schemaVersion = '2.0'
        requestId = [string]$request.requestId
        sourceCommit = $env:GITHUB_SHA
        workflowRunId = $env:GITHUB_RUN_ID
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        primaryNodeAddress = '10.10.10.11'
        targetMachine = 'fleet-local/custom-81a2c5e94b13'
        comparisonMachine = 'fleet-local/custom-a5a2c67354be'
        sshExitCode = $exitCode
        diagnosticCompleted = $completed
        clusterStateModified = $false
        credentialValuesWrittenToEvidence = $false
        productionReleaseApproved = $false
        failure = $failure
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8

    [Environment]::SetEnvironmentVariable('SSH_ASKPASS', $oldAskPass)
    [Environment]::SetEnvironmentVariable('SSH_ASKPASS_REQUIRE', $oldAskPassRequire)
    [Environment]::SetEnvironmentVariable('DISPLAY', $oldDisplay)
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $nodePassword = $null
    $nodePasswordB64 = $null
    $credentials = $null
}
