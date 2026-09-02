[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-source-continuation-06')
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
    throw "Continuation request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'REPAIR_SEN2_AGENT_SERVICE_CONFLICT') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.targetNode -ne 'sen2' -or [string]$request.targetAddress -ne '10.10.10.12') {
    throw 'This continuation is restricted to sen2 at 10.10.10.12.'
}
if ([string]$request.primaryNode -ne '10.10.10.11') {
    throw 'The authoritative source must be checked through sen1 at 10.10.10.11.'
}
if (-not [bool]$request.sourceCorrectionAlreadyPassed) {
    throw 'The request must bind this continuation to the completed source correction.'
}
if (-not [bool]$request.verifyAuthoritativeWorkerStateOnly) {
    throw 'The request must authorize a read-only authoritative source verification.'
}
if ([bool]$request.mutateAuthoritativeSource) {
    throw 'This continuation must not mutate the authoritative Rancher objects.'
}
if ([string]$request.previousAuthoritativeRunId -ne '33634372658') {
    throw 'The request is not bound to the authoritative correction run 33634372658.'
}
if ([string]$request.previousVerifierRunId -ne '33637662758') {
    throw 'The request is not bound to the stopped post-source verifier run 33637662758.'
}
foreach ($forbidden in @(
    'reinstallOrWipeDisks',
    'deleteRke2Data',
    'acceptEula',
    'writeCredentialValuesToEvidence',
    'productionReleaseApprovalImplied'
)) {
    if ([bool]$request.$forbidden) {
        throw "Forbidden request flag is true: $forbidden"
    }
}

$expectedValues = [ordered]@{
    EXPECTED_CAPI_MACHINE_UID = [string]$request.expectedCapiMachineUid
    EXPECTED_RKE_BOOTSTRAP_UID = [string]$request.expectedRkeBootstrapUid
    EXPECTED_CUSTOM_MACHINE_UID = [string]$request.expectedCustomMachineUid
    EXPECTED_PLAN_SECRET_UID = [string]$request.expectedPlanSecretUid
    EXPECTED_OLD_PLAN_SHA256 = [string]$request.expectedOldPlanSha256
}
foreach ($key in @(
    'EXPECTED_CAPI_MACHINE_UID',
    'EXPECTED_RKE_BOOTSTRAP_UID',
    'EXPECTED_CUSTOM_MACHINE_UID',
    'EXPECTED_PLAN_SECRET_UID'
)) {
    if ($expectedValues[$key] -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw "Invalid expected Kubernetes UID: $key"
    }
}
if ($expectedValues['EXPECTED_OLD_PLAN_SHA256'] -notmatch '^[0-9a-f]{64}$') {
    throw 'Invalid expected failing-plan SHA-256.'
}

$shellPath = Join-Path $PSScriptRoot 'verify-sen2-worker-source-continuation-06.sh'
if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw "Current source-verification script is missing: $shellPath"
}
if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Protected credential file is missing: $CredentialPath"
}
$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nodePassword = [string]$credentials.nodePassword
if ([string]::IsNullOrWhiteSpace($nodePassword) -or $nodePassword.Length -lt 16) {
    throw 'The protected node password is missing or invalid.'
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
$resultPath = Join-Path $OutputDirectory 'source-verification-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-sen2-source-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $temporaryDirectory

$ssh = Get-Command -Name 'ssh.exe' -ErrorAction Stop | Select-Object -First 1
$passwordPath = Join-Path $temporaryDirectory 'node-password.txt'
$askPassPath = Join-Path $temporaryDirectory 'askpass.cmd'
Write-Utf8NoBom -Path $passwordPath -Value ($nodePassword + "`r`n")
Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$passwordPath`"`r`n")
$oldAskPass = [Environment]::GetEnvironmentVariable('SSH_ASKPASS')
$oldAskPassRequire = [Environment]::GetEnvironmentVariable('SSH_ASKPASS_REQUIRE')
$oldDisplay = [Environment]::GetEnvironmentVariable('DISPLAY')
$env:SSH_ASKPASS = $askPassPath
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'LayerSentry'

function Invoke-NodeScript {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$ConnectTimeoutSeconds = 20
    )

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $scriptFile = Join-Path $temporaryDirectory ($safeLabel + '.sh')
    $stdoutFile = Join-Path $temporaryDirectory ($safeLabel + '.stdout.raw')
    $stderrFile = Join-Path $temporaryDirectory ($safeLabel + '.stderr.raw')
    $evidenceFile = Join-Path $OutputDirectory ($safeLabel + '.txt')
    Write-Utf8NoBom -Path $scriptFile -Value (($Script -replace "`r`n", "`n").TrimStart([char]0xFEFF))

    $arguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
        "rancher@$Address",
        'bash', '-s'
    )
    $process = Start-Process `
        -FilePath $ssh.Source `
        -ArgumentList $arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardInput $scriptFile `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile
    $stdout = [string](Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
    $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
    Write-Utf8NoBom -Path $evidenceFile -Value (Protect-Text -Text ($stdout + "`n===ssh-stderr===`n" + $stderr))
    Remove-Item -LiteralPath $scriptFile, $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        RawStdout = $stdout
        EvidencePath = $evidenceFile
    }
}

$startedAt = (Get-Date).ToUniversalTime()
$passed = $false
$currentState = $null
$failure = $null

try {
    $exports = [System.Collections.Generic.List[string]]::new()
    [void]$exports.Add("export LAYERSENTRY_NODE_PASSWORD_B64='$nodePasswordB64'")
    foreach ($entry in $expectedValues.GetEnumerator()) {
        [void]$exports.Add("export $($entry.Key)='$($entry.Value)'")
    }
    $shellSource = Get-Content -LiteralPath $shellPath -Raw -Encoding UTF8
    $remoteScript = (($exports -join "`n") + "`n" + $shellSource)
    $remoteResult = Invoke-NodeScript `
        -Address '10.10.10.11' `
        -Label 'sen2-current-worker-source-read-only' `
        -Script $remoteScript
    if ($remoteResult.ExitCode -ne 0 -or $remoteResult.RawStdout -notmatch '(?m)^LAYERSENTRY_SEN2_CURRENT_WORKER_SOURCE:PASS\s*$') {
        throw "Current authoritative worker-source verification failed with SSH exit code $($remoteResult.ExitCode)."
    }
    $stateMatch = [regex]::Match($remoteResult.RawStdout, '(?m)^LAYERSENTRY_CURRENT_WORKER_SOURCE=(\{.+\})$')
    if (-not $stateMatch.Success) {
        throw 'Current authoritative source verification did not emit structured evidence.'
    }
    $currentState = $stateMatch.Groups[1].Value | ConvertFrom-Json
    $passed = $true
    Write-Host 'LAYERSENTRY SEN2 CURRENT AUTHORITATIVE WORKER SOURCE: PASS'
}
catch {
    $failure = [string]$_.Exception.Message
    throw
}
finally {
    $finishedAt = (Get-Date).ToUniversalTime()
    [ordered]@{
        schemaVersion = '1.0'
        requestId = [string]$request.requestId
        previousAuthoritativeRunId = [string]$request.previousAuthoritativeRunId
        previousVerifierRunId = [string]$request.previousVerifierRunId
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        targetNode = 'sen2'
        targetMachine = 'fleet-local/custom-81a2c5e94b13'
        verificationReadOnly = $true
        sourceCorrectionAlreadyPassed = $true
        currentAuthoritativeWorkerState = $currentState
        authoritativeSourceModified = $false
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        passed = $passed
        failure = $failure
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry sen2 current worker-source verification

- Current authoritative worker-only state verified: **$passed**
- Verification was read-only: **true**
- Authoritative source modified: **false**
- VM reinstalled or disk wiped: **false**
- Production release approved: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

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
