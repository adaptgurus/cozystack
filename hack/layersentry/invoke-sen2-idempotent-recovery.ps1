[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-agent-service-repair'),
    [int]$InitialWaitMinutes = 15,
    [int]$StableSamples = 24,
    [int]$StableIntervalSeconds = 30
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
    throw "Recovery request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'REPAIR_SEN2_AGENT_SERVICE_CONFLICT') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.targetNode -ne 'sen2' -or [string]$request.targetAddress -ne '10.10.10.12') {
    throw 'This recovery is restricted to sen2 at 10.10.10.12.'
}
if ([string]$request.expectedRancherdRole -ne 'agent') {
    throw 'The expected rancherd role must be agent.'
}
if ([string]$request.expectedRancherdServerUrl -ne 'https://10.10.10.11:443') {
    throw 'The expected rancherd server URL must be the verified sen1 endpoint.'
}
if (-not [bool]$request.disableConflictingRke2Server) {
    throw 'The request must authorize disabling only the conflicting rke2-server service when required.'
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

$stabilityPath = Join-Path $PSScriptRoot 'validate-sen2-agent-stability.ps1'
$repairPath = Join-Path $PSScriptRoot 'invoke-sen2-agent-service-repair-bound.ps1'
foreach ($path in @($stabilityPath, $repairPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required recovery source is missing: $path"
    }
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
$decisionPath = Join-Path $OutputDirectory 'recovery-decision.json'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-sen2-idempotent-decision-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $temporaryDirectory

$ssh = Get-Command -Name 'ssh.exe' -ErrorAction Stop | Select-Object -First 1
$passwordPath = Join-Path $temporaryDirectory 'node-password.txt'
$askPassPath = Join-Path $temporaryDirectory 'askpass.cmd'
$scriptPath = Join-Path $temporaryDirectory 'preflight.sh'
$stdoutPath = Join-Path $temporaryDirectory 'preflight.stdout.raw'
$stderrPath = Join-Path $temporaryDirectory 'preflight.stderr.raw'
$evidencePath = Join-Path $OutputDirectory 'sen2-idempotent-decision-preflight.txt'
Write-Utf8NoBom -Path $passwordPath -Value ($nodePassword + "`r`n")
Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$passwordPath`"`r`n")
$oldAskPass = [Environment]::GetEnvironmentVariable('SSH_ASKPASS')
$oldAskPassRequire = [Environment]::GetEnvironmentVariable('SSH_ASKPASS_REQUIRE')
$oldDisplay = [Environment]::GetEnvironmentVariable('DISPLAY')
$env:SSH_ASKPASS = $askPassPath
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'LayerSentry'

$preflightTemplate = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-idempotent-decision.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then
  echo 'LAYERSENTRY_IDEMPOTENT_DECISION_ERROR:yq-not-found'
  exit 71
fi
hostname_value=$(hostname | tr -d '\r\n')
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r\n' || true)
server_enabled=$(sudo -n systemctl is-enabled rke2-server.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
server_active=$(sudo -n systemctl is-active rke2-server.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
agent_enabled=$(sudo -n systemctl is-enabled rke2-agent.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
agent_active=$(sudo -n systemctl is-active rke2-agent.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
system_agent_active=$(sudo -n systemctl is-active rancher-system-agent.service 2>&1 | tail -n 1 | tr -d '\r\n' || true)
kubelet_open=false
if timeout 3 bash -c '</dev/tcp/127.0.0.1/10250' >/dev/null 2>&1; then kubelet_open=true; fi
agent_process=false
if ps -ef | grep -E '[r]ke2[[:space:]]+agent' >/dev/null 2>&1; then agent_process=true; fi
server_process=false
if ps -ef | grep -E '[r]ke2[[:space:]]+server' >/dev/null 2>&1; then server_process=true; fi
printf 'LAYERSENTRY_IDEMPOTENT_DECISION_STATE:hostname=%s;role=%s;serverUrl=%s;installMode=%s;planType=%s;serverEnabled=%s;serverActive=%s;agentEnabled=%s;agentActive=%s;systemAgentActive=%s;kubelet10250=%s;agentProcess=%s;serverProcess=%s\n' \
  "$hostname_value" "$role" "$server_url" "$install_mode" "$plan_type" \
  "$server_enabled" "$server_active" "$agent_enabled" "$agent_active" \
  "$system_agent_active" "$kubelet_open" "$agent_process" "$server_process"
if [ "$hostname_value" != sen2 ]; then exit 72; fi
if [ "$role" != agent ]; then exit 73; fi
if [ "$server_url" != '{{EXPECTED_SERVER_URL}}' ]; then exit 74; fi
if [ "$install_mode" != join ]; then exit 75; fi
if [ -n "$plan_type" ] && [ "$plan_type" != agent ]; then exit 76; fi
if ! sudo -n systemctl list-unit-files rke2-agent.service --no-legend 2>/dev/null | grep -q '^rke2-agent.service'; then exit 77; fi

already_correct=true
if [ "$server_enabled" = enabled ]; then already_correct=false; fi
if [ "$server_active" = active ] || [ "$server_active" = activating ]; then already_correct=false; fi
if [ "$agent_enabled" != enabled ]; then already_correct=false; fi
if [ "$agent_active" != active ]; then already_correct=false; fi
if [ "$system_agent_active" != active ]; then already_correct=false; fi
if [ "$kubelet_open" != true ]; then already_correct=false; fi
if [ "$agent_process" != true ]; then already_correct=false; fi
if [ "$server_process" != false ]; then already_correct=false; fi

if [ "$already_correct" = true ]; then
  echo 'LAYERSENTRY_SEN2_RECOVERY_DECISION:already-correct-no-reboot'
else
  echo 'LAYERSENTRY_SEN2_RECOVERY_DECISION:repair-required'
fi
'@
$preflightScript = $preflightTemplate.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64).Replace(
    '{{EXPECTED_SERVER_URL}}',
    [string]$request.expectedRancherdServerUrl
)
Write-Utf8NoBom -Path $scriptPath -Value (($preflightScript -replace "`r`n", "`n").TrimStart([char]0xFEFF))

$startedAt = (Get-Date).ToUniversalTime()
$decision = $null
$lastState = $null
$rebootPathSelected = $false
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
        'rancher@10.10.10.12',
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
    $stdout = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
    $stderr = [string](Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
    Write-Utf8NoBom -Path $evidencePath -Value (Protect-Text -Text ($stdout + "`n===ssh-stderr===`n" + $stderr))
    if ($process.ExitCode -ne 0) {
        throw "The idempotent sen2 recovery preflight failed with SSH exit code $($process.ExitCode)."
    }
    $stateMatch = [regex]::Match($stdout, '(?m)^LAYERSENTRY_IDEMPOTENT_DECISION_STATE:(.+)$')
    $lastState = if ($stateMatch.Success) { $stateMatch.Groups[1].Value.Trim() } else { $null }
    $decisionMatch = [regex]::Match($stdout, '(?m)^LAYERSENTRY_SEN2_RECOVERY_DECISION:(already-correct-no-reboot|repair-required)\s*$')
    if (-not $decisionMatch.Success) {
        throw 'The idempotent sen2 recovery preflight did not emit a valid decision.'
    }
    $decision = $decisionMatch.Groups[1].Value

    if ($decision -eq 'already-correct-no-reboot') {
        & $stabilityPath `
            -RequestPath $RequestPath `
            -CredentialPath $CredentialPath `
            -OutputDirectory $OutputDirectory `
            -StableSamples $StableSamples `
            -StableIntervalSeconds $StableIntervalSeconds
    }
    else {
        $rebootPathSelected = $true
        & $repairPath `
            -RequestPath $RequestPath `
            -CredentialPath $CredentialPath `
            -OutputDirectory $OutputDirectory `
            -InitialWaitMinutes $InitialWaitMinutes `
            -StableSamples $StableSamples `
            -StableIntervalSeconds $StableIntervalSeconds
    }

    $resultPath = Join-Path $OutputDirectory 'repair-result.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'The selected sen2 recovery path did not generate repair-result.json.'
    }
    $result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$result.passed) {
        throw "The selected sen2 recovery path did not pass: $($result.failure)"
    }
    $completed = $true
    Write-Host "LAYERSENTRY SEN2 IDEMPOTENT RECOVERY: PASS ($decision)"
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
        targetAddress = '10.10.10.12'
        observedState = $lastState
        decision = $decision
        repairOrRebootPathSelected = $rebootPathSelected
        noRebootValidationPathSelected = ($decision -eq 'already-correct-no-reboot')
        completed = $completed
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        failure = $failure
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $decisionPath -Encoding UTF8

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
