[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [Parameter(Mandatory = $true)][string]$ExpectedRancherdServerUrl,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-agent-service-repair'),
    [int]$InitialWaitMinutes = 15,
    [int]$StableSamples = 24,
    [int]$StableIntervalSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module Hyper-V -ErrorAction Stop

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

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 2000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        $waitHandle = $async.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return [bool]$client.Connected
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $waitHandle) {
            $waitHandle.Close()
        }
        $client.Close()
        $client.Dispose()
    }
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
    throw 'This repair is restricted to sen2 at 10.10.10.12.'
}
if ([string]$request.expectedRancherdRole -ne 'agent') {
    throw 'The expected rancherd role must be agent.'
}
if ([string]$request.expectedRancherdServerUrl -cne $ExpectedRancherdServerUrl) {
    throw 'The workflow expectedRancherdServerUrl does not exactly match the continuation request.'
}
if ($ExpectedRancherdServerUrl -cne 'https://10.10.10.11:443') {
    throw 'This continuation only permits the verified sen1 bootstrap/join endpoint https://10.10.10.11:443.'
}
if (-not [bool]$request.disableConflictingRke2Server) {
    throw 'The request does not authorize disabling the conflicting rke2-server unit.'
}
if (-not [bool]$request.backupConfigurationBeforeRepair) {
    throw 'The request must require configuration backup before service changes.'
}
if (-not [bool]$request.rebootOnlySen2) {
    throw 'The request must restrict reboot to sen2.'
}
if ([int]$request.requiredStableSamples -ne 24 -or $StableSamples -ne 24) {
    throw 'Exactly 24 consecutive stability samples are required.'
}
if ([int]$request.stableIntervalSeconds -ne 30 -or $StableIntervalSeconds -ne 30) {
    throw 'The stability interval must be exactly 30 seconds.'
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

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Protected credential file is missing: $CredentialPath"
}
$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nodePassword = [string]$credentials.nodePassword
if ([string]::IsNullOrWhiteSpace($nodePassword) -or $nodePassword.Length -lt 16) {
    throw 'The protected node password is missing or invalid.'
}
$nodePasswordB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))
$expectedServerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ExpectedRancherdServerUrl))
[string[]]$sensitiveValues = @(
    [string]$credentials.nodePassword,
    [string]$credentials.clusterToken,
    [string]$credentials.adminPassword,
    $nodePasswordB64
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$historyPath = Join-Path $OutputDirectory 'service-stability-history.jsonl'
$resultPath = Join-Path $OutputDirectory 'repair-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-sen2-service-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $temporaryDirectory

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

function Invoke-Sen2Script {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Script,
        [int]$ConnectTimeoutSeconds = 15
    )

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $scriptPath = Join-Path $temporaryDirectory ($safeLabel + '.sh')
    $stdoutPath = Join-Path $temporaryDirectory ($safeLabel + '.stdout.raw')
    $stderrPath = Join-Path $temporaryDirectory ($safeLabel + '.stderr.raw')
    $evidencePath = Join-Path $OutputDirectory ($safeLabel + '.txt')
    Write-Utf8NoBom -Path $scriptPath -Value (($Script -replace "`r`n", "`n").TrimStart([char]0xFEFF))

    $arguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
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
    Remove-Item -LiteralPath $scriptPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        RawStdout = $stdout
        EvidencePath = $evidencePath
    }
}

function ConvertFrom-PreflightMarker {
    param([Parameter(Mandatory = $true)][string]$RawStdout)

    $match = [regex]::Match(
        $RawStdout,
        '(?m)^LAYERSENTRY_PREFLIGHT\|([^|\r\n]*)\|([^|\r\n]*)\|([^|\r\n]*)\|([^|\r\n]*)\|([^|\r\n]*)\s*$'
    )
    if (-not $match.Success) {
        return $null
    }
    return [pscustomobject][ordered]@{
        hostname = $match.Groups[1].Value.Trim()
        role = $match.Groups[2].Value.Trim()
        server = $match.Groups[3].Value.Trim()
        installMode = $match.Groups[4].Value.Trim()
        planType = $match.Groups[5].Value.Trim()
    }
}

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$preflight = $null
$preflightExitCode = $null
$exit64RegressionGuardPassed = $false
$stableCount = 0
$backupLocation = $null
$backupCreated = $false
$rke2ServerDisabled = $false
$rke2AgentEnabled = $false
$rebootIssued = $false

try {
    foreach ($vmName in @('sen1', 'sen2', 'sen3')) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ([string]$vm.State -ne 'Running') {
            throw "$vmName must already be Running; current state is $($vm.State)."
        }
    }

    $preflightScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-preflight.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
expected_server=$(printf '%s' '{{EXPECTED_SERVER_B64}}' | base64 -d)
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then
  echo 'LAYERSENTRY_SEN2_REPAIR_ERROR:yq-not-found'
  exit 61
fi
hostname_value=$(hostname)
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r' || true)
printf 'LAYERSENTRY_PREFLIGHT|%s|%s|%s|%s|%s\n' "$hostname_value" "$role" "$server_url" "$install_mode" "$plan_type"
if [ "$hostname_value" != 'sen2' ]; then exit 62; fi
if [ "$role" != 'agent' ]; then exit 63; fi
if [ "$server_url" != "$expected_server" ]; then exit 64; fi
if [ "$install_mode" != 'join' ]; then exit 65; fi
if [ -n "$plan_type" ] && [ "$plan_type" != 'agent' ]; then exit 66; fi
if ! sudo -n systemctl list-unit-files rke2-agent.service --no-legend 2>/dev/null | grep -q '^rke2-agent.service'; then exit 67; fi
echo 'LAYERSENTRY_PREFLIGHT_READONLY:PASS'
'@
    $preflightScript = $preflightScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $preflightScript = $preflightScript.Replace('{{EXPECTED_SERVER_B64}}', $expectedServerB64)
    $preflightResult = Invoke-Sen2Script -Label 'sen2-exact-url-preflight-readonly' -Script $preflightScript -ConnectTimeoutSeconds 20
    $preflightExitCode = [int]$preflightResult.ExitCode
    $preflight = ConvertFrom-PreflightMarker -RawStdout $preflightResult.RawStdout

    if ($preflightExitCode -eq 64) {
        $observed = if ($null -ne $preflight) { [string]$preflight.server } else { 'not-observed' }
        if ($observed -ceq $ExpectedRancherdServerUrl) {
            throw "Exit-code-64 regression detected before mutation: observed rancherd server URL exactly matched $ExpectedRancherdServerUrl."
        }
        throw "Exact rancherd server URL validation failed before mutation with exit code 64: expected=$ExpectedRancherdServerUrl; observed=$observed."
    }
    if ($preflightExitCode -ne 0) {
        throw "Read-only sen2 repair preflight failed before mutation with SSH exit code $preflightExitCode."
    }
    if ($null -eq $preflight) {
        throw 'Read-only sen2 repair preflight did not emit its sanitized marker.'
    }
    if ([string]$preflight.server -cne $ExpectedRancherdServerUrl) {
        throw "Preflight parser mismatch before mutation: expected=$ExpectedRancherdServerUrl; observed=$($preflight.server)."
    }
    if ($preflightResult.RawStdout -notmatch '(?m)^LAYERSENTRY_PREFLIGHT_READONLY:PASS\s*$') {
        throw 'Read-only sen2 repair preflight did not reach PASS.'
    }
    $exit64RegressionGuardPassed = $true

    $repairScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-agent-role.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
expected_server=$(printf '%s' '{{EXPECTED_SERVER_B64}}' | base64 -d)
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then exit 61; fi
hostname_value=$(hostname)
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r' || true)
printf 'LAYERSENTRY_MUTATION_GUARD|%s|%s|%s|%s|%s\n' "$hostname_value" "$role" "$server_url" "$install_mode" "$plan_type"
if [ "$hostname_value" != 'sen2' ]; then exit 62; fi
if [ "$role" != 'agent' ]; then exit 63; fi
if [ "$server_url" != "$expected_server" ]; then exit 64; fi
if [ "$install_mode" != 'join' ]; then exit 65; fi
if [ -n "$plan_type" ] && [ "$plan_type" != 'agent' ]; then exit 66; fi
for service in rke2-server rke2-agent rancher-system-agent; do
  enabled=$(sudo -n systemctl is-enabled "$service" 2>&1 || true)
  active=$(sudo -n systemctl is-active "$service" 2>&1 || true)
  restarts=$(sudo -n systemctl show "$service" -p NRestarts --value 2>/dev/null || true)
  echo "LAYERSENTRY_SERVICE_BEFORE:${service}:enabled=${enabled}:active=${active}:restarts=${restarts}"
done
backup_root="/oem/layersentry-sen2-service-repair-backups/$(date -u +%Y%m%dT%H%M%SZ)"
sudo -n mkdir -p "$backup_root"
sudo -n cp -a /etc/rancher/rancherd/config.yaml "$backup_root/rancherd-config.yaml"
sudo -n cp -a /oem/harvester.config "$backup_root/harvester.config"
sudo -n sh -c "systemctl is-enabled rke2-server > '$backup_root/rke2-server-enabled.txt' 2>&1 || true"
sudo -n sh -c "systemctl is-active rke2-server > '$backup_root/rke2-server-active.txt' 2>&1 || true"
sudo -n sh -c "systemctl is-enabled rke2-agent > '$backup_root/rke2-agent-enabled.txt' 2>&1 || true"
sudo -n sh -c "systemctl is-active rke2-agent > '$backup_root/rke2-agent-active.txt' 2>&1 || true"
echo "LAYERSENTRY_BACKUP_CREATED:${backup_root}"
sudo -n systemctl disable --now rke2-server.service
sudo -n systemctl reset-failed rke2-server.service || true
sudo -n systemctl enable rke2-agent.service
server_enabled_after=$(sudo -n systemctl is-enabled rke2-server.service 2>&1 || true)
agent_enabled_after=$(sudo -n systemctl is-enabled rke2-agent.service 2>&1 || true)
echo "LAYERSENTRY_SERVICE_CONFIGURED:rke2-server=${server_enabled_after}:rke2-agent=${agent_enabled_after}:backup=${backup_root}"
if [ "$server_enabled_after" = 'enabled' ]; then exit 68; fi
if [ "$agent_enabled_after" != 'enabled' ]; then exit 69; fi
echo 'LAYERSENTRY_SEN2_REBOOT_ISSUED'
sudo -n systemctl reboot
'@
    $repairScript = $repairScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $repairScript = $repairScript.Replace('{{EXPECTED_SERVER_B64}}', $expectedServerB64)
    $repairResult = Invoke-Sen2Script -Label 'sen2-authorized-service-repair' -Script $repairScript -ConnectTimeoutSeconds 20

    $backupMatch = [regex]::Match($repairResult.RawStdout, '(?m)^LAYERSENTRY_BACKUP_CREATED:(.+)$')
    if ($backupMatch.Success) {
        $backupLocation = $backupMatch.Groups[1].Value.Trim()
        $backupCreated = $true
    }
    $configuredMatch = [regex]::Match(
        $repairResult.RawStdout,
        '(?m)^LAYERSENTRY_SERVICE_CONFIGURED:rke2-server=([^:]+):rke2-agent=([^:]+):backup=(.+)$'
    )
    if ($configuredMatch.Success) {
        $rke2ServerDisabled = ($configuredMatch.Groups[1].Value.Trim() -ne 'enabled')
        $rke2AgentEnabled = ($configuredMatch.Groups[2].Value.Trim() -eq 'enabled')
    }
    $rebootIssued = ($repairResult.RawStdout -match '(?m)^LAYERSENTRY_SEN2_REBOOT_ISSUED\s*$')
    if (-not $backupCreated) {
        throw "sen2 did not create the required configuration backup before service changes. SSH exit code: $($repairResult.ExitCode)"
    }
    if (-not ($rke2ServerDisabled -and $rke2AgentEnabled)) {
        throw "sen2 did not reach the restricted service configuration gate. SSH exit code: $($repairResult.ExitCode)"
    }
    if (-not $rebootIssued) {
        throw "sen2 did not reach the authorized reboot point. SSH exit code: $($repairResult.ExitCode)"
    }

    Start-Sleep -Seconds 15
    $postCheckScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-postcheck.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
expected_server=$(printf '%s' '{{EXPECTED_SERVER_B64}}' | base64 -d)
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then exit 81; fi
hostname_value=$(hostname)
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
server_enabled=$(sudo -n systemctl is-enabled rke2-server.service 2>&1 || true)
server_active=$(sudo -n systemctl is-active rke2-server.service 2>&1 || true)
agent_enabled=$(sudo -n systemctl is-enabled rke2-agent.service 2>&1 || true)
agent_active=$(sudo -n systemctl is-active rke2-agent.service 2>&1 || true)
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r' || true)
kubelet_open=false
if timeout 3 bash -c '</dev/tcp/127.0.0.1/10250' >/dev/null 2>&1; then kubelet_open=true; fi
agent_process=false
if ps -ef | grep -E '[r]ke2[[:space:]]+agent' >/dev/null 2>&1; then agent_process=true; fi
server_process=false
if ps -ef | grep -E '[r]ke2[[:space:]]+server' >/dev/null 2>&1; then server_process=true; fi
printf 'LAYERSENTRY_POSTCHECK|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$hostname_value" "$role" "$server_url" "$install_mode" "$server_enabled" "$server_active" "$agent_enabled" "$agent_active" "$plan_type" "$kubelet_open" "$agent_process" "$server_process"
if [ "$hostname_value" != 'sen2' ]; then exit 82; fi
if [ "$role" != 'agent' ]; then exit 83; fi
if [ "$server_url" != "$expected_server" ]; then exit 84; fi
if [ "$install_mode" != 'join' ]; then exit 85; fi
if [ "$server_enabled" = 'enabled' ]; then exit 86; fi
if [ "$server_active" = 'active' ] || [ "$server_active" = 'activating' ]; then exit 87; fi
if [ "$agent_enabled" != 'enabled' ]; then exit 88; fi
if [ "$agent_active" != 'active' ]; then exit 89; fi
if [ -n "$plan_type" ] && [ "$plan_type" != 'agent' ]; then exit 90; fi
if [ "$kubelet_open" != 'true' ]; then exit 91; fi
if [ "$agent_process" != 'true' ]; then exit 92; fi
if [ "$server_process" != 'false' ]; then exit 93; fi
echo 'LAYERSENTRY_SEN2_AGENT_LOCAL_CHECK:PASS'
'@
    $postCheckScript = $postCheckScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $postCheckScript = $postCheckScript.Replace('{{EXPECTED_SERVER_B64}}', $expectedServerB64)

    $initialDeadline = (Get-Date).ToUniversalTime().AddMinutes($InitialWaitMinutes)
    $initialAttempt = 0
    $initialReady = $false
    $lastInitialFailure = $null
    while ((Get-Date).ToUniversalTime() -lt $initialDeadline) {
        $initialAttempt++
        $sshOpen = Test-TcpPort -Address '10.10.10.12' -Port 22 -TimeoutMilliseconds 2000
        $kubeletOpen = Test-TcpPort -Address '10.10.10.12' -Port 10250 -TimeoutMilliseconds 2000
        if ($sshOpen) {
            try {
                $check = Invoke-Sen2Script `
                    -Label ('sen2-initial-postcheck-{0:D3}' -f $initialAttempt) `
                    -Script $postCheckScript `
                    -ConnectTimeoutSeconds 10
                $initialReady = ($check.ExitCode -eq 0 -and $check.RawStdout -match 'LAYERSENTRY_SEN2_AGENT_LOCAL_CHECK:PASS')
                if (-not $initialReady) {
                    $lastInitialFailure = "Remote postcheck exit code $($check.ExitCode)."
                }
            }
            catch {
                $lastInitialFailure = [string]$_.Exception.Message
            }
        }
        else {
            $lastInitialFailure = 'SSH endpoint is not open.'
        }
        [ordered]@{
            phase = 'initial-convergence'
            attempt = $initialAttempt
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            expectedRancherdServerUrl = $ExpectedRancherdServerUrl
            ssh22 = $sshOpen
            kubelet10250 = $kubeletOpen
            passed = $initialReady
            failure = $lastInitialFailure
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $historyPath -Encoding UTF8
        if ($initialReady) {
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $initialReady) {
        throw "sen2 did not return as a stable RKE2 agent: $lastInitialFailure"
    }

    for ($sample = 1; $sample -le $StableSamples; $sample++) {
        $check = Invoke-Sen2Script `
            -Label ('sen2-stability-{0:D2}' -f $sample) `
            -Script $postCheckScript `
            -ConnectTimeoutSeconds 10
        $samplePassed = ($check.ExitCode -eq 0 -and $check.RawStdout -match 'LAYERSENTRY_SEN2_AGENT_LOCAL_CHECK:PASS')
        $sshOpen = Test-TcpPort -Address '10.10.10.12' -Port 22 -TimeoutMilliseconds 2000
        $kubeletOpen = Test-TcpPort -Address '10.10.10.12' -Port 10250 -TimeoutMilliseconds 2000
        [ordered]@{
            phase = 'stability'
            sample = $sample
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            expectedRancherdServerUrl = $ExpectedRancherdServerUrl
            ssh22 = $sshOpen
            kubelet10250 = $kubeletOpen
            remoteServiceCheck = $samplePassed
            passed = ($samplePassed -and $sshOpen -and $kubeletOpen)
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $historyPath -Encoding UTF8
        if (-not ($samplePassed -and $sshOpen -and $kubeletOpen)) {
            throw "sen2 failed stability sample $sample/$StableSamples."
        }
        $stableCount = $sample
        Write-Host "sen2 agent stability sample $sample/$StableSamples passed."
        if ($sample -lt $StableSamples) {
            Start-Sleep -Seconds $StableIntervalSeconds
        }
    }

    $passed = $true
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
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        targetNode = 'sen2'
        targetAddress = '10.10.10.12'
        expectedRole = 'agent'
        expectedRancherdServerUrl = $ExpectedRancherdServerUrl
        observedRancherdServerUrl = if ($null -ne $preflight) { [string]$preflight.server } else { $null }
        preflight = $preflight
        preflightSshExitCode = $preflightExitCode
        exit64RegressionGuardPassed = $exit64RegressionGuardPassed
        backupLocation = $backupLocation
        backupCreated = $backupCreated
        rke2ServerDisabled = $rke2ServerDisabled
        rke2AgentEnabled = $rke2AgentEnabled
        rebootIssued = $rebootIssued
        rebootedNode = if ($rebootIssued) { 'sen2' } else { $null }
        rke2AgentStable = $passed
        consecutiveStableSamples = $stableCount
        stabilityIntervalSeconds = $StableIntervalSeconds
        rancherdConfigurationChanged = $false
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        passed = $passed
        failure = $failure
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry sen2 agent service-conflict repair

- Target: **sen2 / 10.10.10.12**
- Expected role: **agent**
- Expected rancherd bootstrap/join endpoint: **$ExpectedRancherdServerUrl**
- Observed preflight endpoint: **$(if ($null -ne $preflight) { $preflight.server } else { 'not-observed' })**
- Exit-code-64 regression guard passed: **$exit64RegressionGuardPassed**
- Configuration backup created: **$backupCreated**
- Conflicting rke2-server disabled: **$rke2ServerDisabled**
- rke2-agent enabled: **$rke2AgentEnabled**
- Rebooted node: **$(if ($rebootIssued) { 'sen2' } else { 'none' })**
- Consecutive stability samples: **$stableCount / $StableSamples**
- Rancherd configuration changed: **false**
- RKE2 data deleted: **false**
- VM disk wiped or VM reinstalled: **false**
- Production release approved: **false**
- Passed: **$passed**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

    [Environment]::SetEnvironmentVariable('SSH_ASKPASS', $oldAskPass)
    [Environment]::SetEnvironmentVariable('SSH_ASKPASS_REQUIRE', $oldAskPassRequire)
    [Environment]::SetEnvironmentVariable('DISPLAY', $oldDisplay)
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $nodePassword = $null
    $credentials = $null
}