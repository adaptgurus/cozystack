[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-agent-service-repair'),
    [int]$LocalPlanWaitMinutes = 10
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
    throw "Repair request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'REPAIR_SEN2_AGENT_SERVICE_CONFLICT') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.targetNode -ne 'sen2' -or [string]$request.targetAddress -ne '10.10.10.12') {
    throw 'This correction is restricted to sen2 at 10.10.10.12.'
}
if (-not [bool]$request.correctErroneousRancherRoles) {
    throw 'The request does not authorize correcting the erroneous Rancher role labels.'
}
if (-not [bool]$request.restartRancherSystemAgentIfNeeded) {
    throw 'The request must explicitly authorize a Rancher system-agent restart if plan convergence stalls.'
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
foreach ($entry in $expectedValues.GetEnumerator()) {
    if ($entry.Key -eq 'EXPECTED_OLD_PLAN_SHA256') {
        if ($entry.Value -notmatch '^[0-9a-f]{64}$') {
            throw "Invalid expected SHA-256 value: $($entry.Key)"
        }
    }
    elseif ($entry.Value -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw "Invalid expected Kubernetes UID: $($entry.Key)"
    }
}
if ([string]$request.expectedErroneousRoleFieldManager -ne 'kubectl-label') {
    throw 'The expected erroneous role field manager must be kubectl-label.'
}

$shellPath = Join-Path $PSScriptRoot 'correct-sen2-worker-plan.sh'
if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
    throw "The worker-plan correction collector is missing: $shellPath"
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

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$historyPath = Join-Path $OutputDirectory 'worker-plan-local-convergence.jsonl'
$resultPath = Join-Path $OutputDirectory 'worker-plan-correction-result.json'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-worker-plan-secure-' + [Guid]::NewGuid().ToString('N'))
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
        [int]$ConnectTimeoutSeconds = 15
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
$sourceCorrectionPassed = $false
$localPlanConverged = $false
$systemAgentRestarted = $false
$sourcePreflight = $null
$sourceConvergence = $null
$lastLocalState = $null
$failure = $null

try {
    $exports = [System.Collections.Generic.List[string]]::new()
    [void]$exports.Add("export LAYERSENTRY_NODE_PASSWORD_B64='$nodePasswordB64'")
    foreach ($entry in $expectedValues.GetEnumerator()) {
        [void]$exports.Add("export $($entry.Key)='$($entry.Value)'")
    }
    $correctionShell = Get-Content -LiteralPath $shellPath -Raw -Encoding UTF8
    $remoteCorrection = (($exports -join "`n") + "`n" + $correctionShell)
    $sourceResult = Invoke-NodeScript `
        -Address '10.10.10.11' `
        -Label 'sen2-authoritative-worker-plan-correction' `
        -Script $remoteCorrection `
        -ConnectTimeoutSeconds 20
    if ($sourceResult.ExitCode -ne 0 -or $sourceResult.RawStdout -notmatch '(?m)^LAYERSENTRY_SEN2_AUTHORITATIVE_WORKER_PLAN:PASS\s*$') {
        throw "The authoritative sen2 worker-plan correction failed with SSH exit code $($sourceResult.ExitCode)."
    }
    $sourceCorrectionPassed = $true
    $preflightMatch = [regex]::Match($sourceResult.RawStdout, '(?m)^LAYERSENTRY_WORKER_PLAN_PREFLIGHT=(\{.+\})$')
    if ($preflightMatch.Success) {
        $sourcePreflight = $preflightMatch.Groups[1].Value | ConvertFrom-Json
    }
    $convergenceMatch = [regex]::Match($sourceResult.RawStdout, '(?m)^LAYERSENTRY_WORKER_PLAN_CONVERGED=(\{.+\})$')
    if ($convergenceMatch.Success) {
        $sourceConvergence = $convergenceMatch.Groups[1].Value | ConvertFrom-Json
    }

    $checkTemplate = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-worker-plan-check.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r' || true)
server_enabled=$(sudo -n systemctl is-enabled rke2-server.service 2>&1 || true)
server_active=$(sudo -n systemctl is-active rke2-server.service 2>&1 || true)
agent_enabled=$(sudo -n systemctl is-enabled rke2-agent.service 2>&1 || true)
agent_active=$(sudo -n systemctl is-active rke2-agent.service 2>&1 || true)
system_agent_active=$(sudo -n systemctl is-active rancher-system-agent.service 2>&1 || true)
kubelet_open=false
if timeout 3 bash -c '</dev/tcp/127.0.0.1/10250' >/dev/null 2>&1; then kubelet_open=true; fi
printf 'LAYERSENTRY_SEN2_WORKER_PLAN_LOCAL:planType=%s:serverEnabled=%s:serverActive=%s:agentEnabled=%s:agentActive=%s:systemAgentActive=%s:kubelet10250=%s\n' \
  "$plan_type" "$server_enabled" "$server_active" "$agent_enabled" "$agent_active" "$system_agent_active" "$kubelet_open"
if [ "$plan_type" = 'agent' ]; then
  echo 'LAYERSENTRY_SEN2_LOCAL_WORKER_PLAN:PASS'
  exit 0
fi
exit 10
'@
    $checkScript = $checkTemplate.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $restartTemplate = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-system-agent-restart.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
sudo -n systemctl restart rancher-system-agent.service
sleep 3
state=$(sudo -n systemctl is-active rancher-system-agent.service 2>&1 || true)
echo "LAYERSENTRY_SYSTEM_AGENT_RESTARTED:state=${state}"
if [ "$state" != 'active' ]; then exit 11; fi
'@
    $restartScript = $restartTemplate.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)

    $deadline = (Get-Date).ToUniversalTime().AddMinutes($LocalPlanWaitMinutes)
    $attempt = 0
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $attempt++
        try {
            $check = Invoke-NodeScript `
                -Address '10.10.10.12' `
                -Label ('sen2-worker-plan-local-{0:D3}' -f $attempt) `
                -Script $checkScript `
                -ConnectTimeoutSeconds 10
            $stateMatch = [regex]::Match($check.RawStdout, '(?m)^LAYERSENTRY_SEN2_WORKER_PLAN_LOCAL:(.+)$')
            $stateText = if ($stateMatch.Success) { $stateMatch.Groups[1].Value.Trim() } else { $null }
            $lastLocalState = $stateText
            $localPlanConverged = ($check.ExitCode -eq 0 -and $check.RawStdout -match '(?m)^LAYERSENTRY_SEN2_LOCAL_WORKER_PLAN:PASS\s*$')
            [ordered]@{
                attempt = $attempt
                capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                sshExitCode = $check.ExitCode
                state = $stateText
                passed = $localPlanConverged
                systemAgentRestarted = $systemAgentRestarted
            } | ConvertTo-Json -Compress | Add-Content -LiteralPath $historyPath -Encoding UTF8
            if ($localPlanConverged) {
                break
            }
        }
        catch {
            [ordered]@{
                attempt = $attempt
                capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                sshExitCode = $null
                state = $null
                passed = $false
                failure = [string]$_.Exception.Message
                systemAgentRestarted = $systemAgentRestarted
            } | ConvertTo-Json -Compress | Add-Content -LiteralPath $historyPath -Encoding UTF8
        }

        if (-not $systemAgentRestarted -and $attempt -ge 6) {
            $restart = Invoke-NodeScript `
                -Address '10.10.10.12' `
                -Label 'sen2-rancher-system-agent-restart' `
                -Script $restartScript `
                -ConnectTimeoutSeconds 10
            if ($restart.ExitCode -ne 0 -or $restart.RawStdout -notmatch '(?m)^LAYERSENTRY_SYSTEM_AGENT_RESTARTED:state=active\s*$') {
                throw "The authorized sen2 rancher-system-agent restart failed with exit code $($restart.ExitCode)."
            }
            $systemAgentRestarted = $true
        }
        Start-Sleep -Seconds 10
    }
    if (-not $localPlanConverged) {
        throw "sen2 did not consume the corrected worker plan within $LocalPlanWaitMinutes minutes. Last state: $lastLocalState"
    }

    Write-Host 'LAYERSENTRY SEN2 AUTHORITATIVE WORKER PLAN AND LOCAL PLAN CONVERGENCE: PASS'
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
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        targetNode = 'sen2'
        targetMachine = 'fleet-local/custom-81a2c5e94b13'
        sourceCorrectionPassed = $sourceCorrectionPassed
        sourcePreflight = $sourcePreflight
        sourceConvergence = $sourceConvergence
        localWorkerPlanConsumed = $localPlanConverged
        rancherSystemAgentRestarted = $systemAgentRestarted
        lastLocalState = $lastLocalState
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        passed = ($sourceCorrectionPassed -and $localPlanConverged)
        failure = $failure
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding UTF8

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
