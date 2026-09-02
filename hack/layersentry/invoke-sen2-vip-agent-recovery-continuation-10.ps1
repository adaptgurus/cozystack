[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-vip-agent-recovery-10'),
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

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Recovery request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -cne 'REPAIR_SEN2_AGENT_SERVICE_CONFLICT') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -cne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.targetNode -cne 'sen2' -or [string]$request.targetAddress -cne '10.10.10.12') {
    throw 'This recovery is restricted to sen2 at 10.10.10.12.'
}
if ([string]$request.expectedRancherdRole -cne 'agent') {
    throw 'The expected rancherd role must be agent.'
}
$expectedServer = [string]$request.expectedRancherdServerUrl
$knownDriftedServer = [string]$request.knownDriftedRancherdServerUrl
if ($expectedServer -cne 'https://10.10.10.10:443') {
    throw 'The expected rancherd JOIN endpoint must be exactly https://10.10.10.10:443.'
}
if ($knownDriftedServer -cne 'https://10.10.10.11:443') {
    throw 'The only correctable historical drift is https://10.10.10.11:443.'
}
if (-not [bool]$request.allowKnownRancherdServerDriftCorrection) {
    throw 'The request does not authorize correction of the exact known rancherd endpoint drift.'
}
if ([string]$request.expectedKnownDriftedRancherdConfigSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'The expected known-drifted rancherd configuration SHA-256 is invalid.'
}
if ([string]$request.expectedSen2HarvesterConfigSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'The expected sen2 Harvester configuration SHA-256 is invalid.'
}
if (-not [bool]$request.backupConfigurationBeforeRepair) {
    throw 'The request must require configuration backup before any change.'
}
if (-not [bool]$request.disableConflictingRke2Server) {
    throw 'The request must authorize disabling only the conflicting rke2-server service.'
}
if (-not [bool]$request.enableRke2Agent) {
    throw 'The request must authorize enabling rke2-agent.'
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
    'mutateAuthoritativeSource',
    'reinstallOrWipeDisks',
    'deleteRke2Data',
    'acceptEula',
    'writeCredentialValuesToEvidence',
    'publishKubeconfig',
    'productionReleaseApprovalImplied'
)) {
    if ([bool]$request.$forbidden) {
        throw "Forbidden request flag is true: $forbidden"
    }
}

$decisionModulePath = Join-Path $PSScriptRoot 'Sen2RancherdEndpointDecision.psm1'
if (-not (Test-Path -LiteralPath $decisionModulePath -PathType Leaf)) {
    throw "Endpoint decision module is missing: $decisionModulePath"
}
Import-Module $decisionModulePath -Force -ErrorAction Stop

# Execute the same decision logic against all regression cases before touching the node.
$expectedCase = Resolve-Sen2RancherdEndpointDecision `
    -ObservedRancherdServerUrl $expectedServer `
    -ExpectedRancherdServerUrl $expectedServer `
    -KnownDriftedRancherdServerUrl $knownDriftedServer `
    -AllowKnownDriftCorrection $true
$knownDriftCase = Resolve-Sen2RancherdEndpointDecision `
    -ObservedRancherdServerUrl $knownDriftedServer `
    -ExpectedRancherdServerUrl $expectedServer `
    -KnownDriftedRancherdServerUrl $knownDriftedServer `
    -AllowKnownDriftCorrection $true
$unexpectedCase = Resolve-Sen2RancherdEndpointDecision `
    -ObservedRancherdServerUrl 'https://10.10.10.99:443' `
    -ExpectedRancherdServerUrl $expectedServer `
    -KnownDriftedRancherdServerUrl $knownDriftedServer `
    -AllowKnownDriftCorrection $true
if (
    -not [bool]$expectedCase.accepted -or
    [bool]$expectedCase.correctionRequired -or
    [int]$expectedCase.rejectionExitCode -ne 0
) {
    throw 'Exit-code-64 regression test failed for an already-correct endpoint.'
}
if (
    -not [bool]$knownDriftCase.accepted -or
    -not [bool]$knownDriftCase.correctionRequired -or
    [int]$knownDriftCase.rejectionExitCode -ne 0
) {
    throw 'Exit-code-64 regression test failed for the authorized known drift.'
}
if (
    [bool]$unexpectedCase.accepted -or
    [int]$unexpectedCase.rejectionExitCode -ne 64
) {
    throw 'Unexpected endpoint regression test must reject with code 64.'
}
$exit64RegressionTestsPassed = $true

# Bind the already-proven service-only repair to the VIP endpoint before any mutation.
$baseRepairPath = Join-Path $PSScriptRoot 'repair-sen2-agent-service-conflict.ps1'
if (-not (Test-Path -LiteralPath $baseRepairPath -PathType Leaf)) {
    throw "Base service-repair source is missing: $baseRepairPath"
}
$baseRepairSource = Get-Content -LiteralPath $baseRepairPath -Raw -Encoding UTF8
$legacyVerifiedLiteral = 'https://10.10.10.11:443'
$literalReplacementCount = [regex]::Matches(
    $baseRepairSource,
    [regex]::Escape($legacyVerifiedLiteral)
).Count
if ($literalReplacementCount -ne 2) {
    throw "Expected exactly two legacy endpoint guard literals in the base repair source; found $literalReplacementCount."
}
$boundRepairSource = $baseRepairSource.Replace($legacyVerifiedLiteral, $expectedServer)
if ($boundRepairSource.Contains($legacyVerifiedLiteral)) {
    throw 'The deterministic VIP endpoint binding left a legacy endpoint literal behind.'
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
$expectedServerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expectedServer))
$knownDriftedServerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($knownDriftedServer))
$knownConfigShaB64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes([string]$request.expectedKnownDriftedRancherdConfigSha256)
)
$harvesterConfigShaB64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes([string]$request.expectedSen2HarvesterConfigSha256)
)
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
$resultPath = Join-Path $OutputDirectory 'vip-agent-recovery-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$serviceOutputDirectory = Join-Path $OutputDirectory 'service-repair'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-sen2-vip-agent-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $temporaryDirectory
$boundRepairPath = Join-Path $temporaryDirectory 'repair-sen2-agent-service-conflict.vip-bound.ps1'
Write-Utf8NoBom -Path $boundRepairPath -Value $boundRepairSource
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $boundRepairPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $message = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "The VIP-bound base repair source does not parse: $message"
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
        [int]$ConnectTimeoutSeconds = 20
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
        RawStderr = $stderr
    }
}

function ConvertFrom-EndpointPreflightMarker {
    param([Parameter(Mandatory = $true)][string]$RawStdout)
    $line = @(
        $RawStdout -split "`r?`n" |
            Where-Object { $_ -like 'LAYERSENTRY_ENDPOINT_PREFLIGHT|*' } |
            Select-Object -Last 1
    )
    if ($line.Count -ne 1) {
        return $null
    }
    $parts = [string]$line[0] -split '\|', 12
    if ($parts.Count -ne 12) {
        return $null
    }
    return [pscustomobject][ordered]@{
        hostname = $parts[1].Trim()
        role = $parts[2].Trim()
        server = $parts[3].Trim()
        installMode = $parts[4].Trim()
        planType = $parts[5].Trim()
        rancherdConfigSha256 = $parts[6].Trim()
        harvesterConfigSha256 = $parts[7].Trim()
        rke2ServerEnabled = $parts[8].Trim()
        rke2ServerActive = $parts[9].Trim()
        rke2AgentEnabled = $parts[10].Trim()
        rke2AgentActive = $parts[11].Trim()
    }
}

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$preflight = $null
$endpointDecision = $null
$endpointBackupLocation = $null
$endpointBackupCreated = $false
$rancherdConfigurationChanged = $false
$rancherdConfigSha256Before = $null
$rancherdConfigSha256After = $null
$rancherdSemanticSha256Before = $null
$rancherdSemanticSha256After = $null
$harvesterConfigSha256Before = $null
$harvesterConfigSha256After = $null
$serviceRepair = $null

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
work=$(mktemp -d /tmp/layersentry-sen2-vip-preflight.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then exit 61; fi
hostname_value=$(hostname)
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
plan_type=$(sudo -n awk -F= '$1 == "INSTALL_RKE2_TYPE" { print $2 }' /var/lib/rancher/rke2/system-agent-installer/rke2-sa.env 2>/dev/null | tail -n 1 | tr -d '\r' || true)
rancherd_sha=$(sudo -n sha256sum /etc/rancher/rancherd/config.yaml | awk '{print $1}')
harvester_sha=$(sudo -n sha256sum /oem/harvester.config | awk '{print $1}')
server_enabled=$(sudo -n systemctl is-enabled rke2-server.service 2>&1 || true)
server_active=$(sudo -n systemctl is-active rke2-server.service 2>&1 || true)
agent_enabled=$(sudo -n systemctl is-enabled rke2-agent.service 2>&1 || true)
agent_active=$(sudo -n systemctl is-active rke2-agent.service 2>&1 || true)
printf 'LAYERSENTRY_ENDPOINT_PREFLIGHT|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$hostname_value" "$role" "$server_url" "$install_mode" "$plan_type" "$rancherd_sha" "$harvester_sha" "$server_enabled" "$server_active" "$agent_enabled" "$agent_active"
if [ "$hostname_value" != 'sen2' ]; then exit 62; fi
if [ "$role" != 'agent' ]; then exit 63; fi
if [ "$install_mode" != 'join' ]; then exit 65; fi
if [ -n "$plan_type" ] && [ "$plan_type" != 'agent' ]; then exit 66; fi
if ! sudo -n systemctl list-unit-files rke2-agent.service --no-legend 2>/dev/null | grep -q '^rke2-agent.service'; then exit 67; fi
echo 'LAYERSENTRY_ENDPOINT_PREFLIGHT_READONLY:PASS'
'@
    $preflightScript = $preflightScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $preflightCall = Invoke-Sen2Script -Label 'sen2-vip-endpoint-preflight-readonly' -Script $preflightScript
    $preflight = ConvertFrom-EndpointPreflightMarker -RawStdout $preflightCall.RawStdout
    if ($preflightCall.ExitCode -ne 0) {
        throw "Read-only sen2 endpoint preflight failed before mutation with SSH exit code $($preflightCall.ExitCode)."
    }
    if ($null -eq $preflight) {
        throw 'Read-only sen2 endpoint preflight did not emit its sanitized marker.'
    }
    if ($preflightCall.RawStdout -notmatch '(?m)^LAYERSENTRY_ENDPOINT_PREFLIGHT_READONLY:PASS\s*$') {
        throw 'Read-only sen2 endpoint preflight did not reach PASS.'
    }
    if ([string]$preflight.harvesterConfigSha256 -cne [string]$request.expectedSen2HarvesterConfigSha256) {
        throw 'sen2 /oem/harvester.config changed after the verified read-only endpoint run.'
    }

    $endpointDecision = Resolve-Sen2RancherdEndpointDecision `
        -ObservedRancherdServerUrl ([string]$preflight.server) `
        -ExpectedRancherdServerUrl $expectedServer `
        -KnownDriftedRancherdServerUrl $knownDriftedServer `
        -AllowKnownDriftCorrection ([bool]$request.allowKnownRancherdServerDriftCorrection)
    if (-not [bool]$endpointDecision.accepted) {
        throw "Exact rancherd URL gate rejected before mutation with exit code $($endpointDecision.rejectionExitCode): expected=$expectedServer; observed=$($preflight.server)."
    }
    if (
        [bool]$endpointDecision.correctionRequired -and
        [string]$preflight.rancherdConfigSha256 -cne [string]$request.expectedKnownDriftedRancherdConfigSha256
    ) {
        throw 'The known-drifted sen2 rancherd configuration SHA-256 no longer matches the verified pre-mutation value.'
    }

    if ([bool]$endpointDecision.correctionRequired) {
        $mutationScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-vip-correction.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
expected_server=$(printf '%s' '{{EXPECTED_SERVER_B64}}' | base64 -d)
known_server=$(printf '%s' '{{KNOWN_SERVER_B64}}' | base64 -d)
expected_config_sha=$(printf '%s' '{{KNOWN_CONFIG_SHA_B64}}' | base64 -d)
expected_harvester_sha=$(printf '%s' '{{HARVESTER_CONFIG_SHA_B64}}' | base64 -d)
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then exit 61; fi
hostname_value=$(hostname)
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config)
rancherd_sha_before=$(sudo -n sha256sum /etc/rancher/rancherd/config.yaml | awk '{print $1}')
harvester_sha_before=$(sudo -n sha256sum /oem/harvester.config | awk '{print $1}')
if [ "$hostname_value" != 'sen2' ]; then exit 62; fi
if [ "$role" != 'agent' ]; then exit 63; fi
if [ "$server_url" != "$known_server" ]; then exit 64; fi
if [ "$install_mode" != 'join' ]; then exit 65; fi
if [ "$rancherd_sha_before" != "$expected_config_sha" ]; then exit 70; fi
if [ "$harvester_sha_before" != "$expected_harvester_sha" ]; then exit 71; fi
backup_root="/oem/layersentry-sen2-vip-agent-repair-backups/$(date -u +%Y%m%dT%H%M%SZ)"
sudo -n mkdir -p "$backup_root"
sudo -n cp -a /etc/rancher/rancherd/config.yaml "$backup_root/rancherd-config.yaml.before-vip-correction"
sudo -n cp -a /oem/harvester.config "$backup_root/harvester.config.unchanged"
sudo -n sh -c "systemctl is-enabled rke2-server.service > '$backup_root/rke2-server-enabled.before.txt' 2>&1 || true"
sudo -n sh -c "systemctl is-active rke2-server.service > '$backup_root/rke2-server-active.before.txt' 2>&1 || true"
sudo -n sh -c "systemctl is-enabled rke2-agent.service > '$backup_root/rke2-agent-enabled.before.txt' 2>&1 || true"
sudo -n sh -c "systemctl is-active rke2-agent.service > '$backup_root/rke2-agent-active.before.txt' 2>&1 || true"
echo "LAYERSENTRY_ENDPOINT_BACKUP_CREATED:${backup_root}"
sudo -n env EXPECTED_SERVER="$expected_server" KNOWN_SERVER="$known_server" python3 - <<'PY'
import hashlib
import json
import os
import re
from pathlib import Path

path = Path('/etc/rancher/rancherd/config.yaml')
raw = path.read_bytes()
pattern = re.compile(rb'(?m)^server:[^\r\n]*$')
matches = list(pattern.finditer(raw))
if len(matches) != 1:
    raise SystemExit(72)
line = matches[0].group(0)
value = line.split(b':', 1)[1].strip()
if len(value) >= 2 and value[:1] == value[-1:] and value[:1] in (b'"', b"'"):
    value = value[1:-1]
current = value.decode('utf-8')
known = os.environ['KNOWN_SERVER']
expected = os.environ['EXPECTED_SERVER']
if current != known:
    raise SystemExit(64)
sentinel = b'server: __LAYERSENTRY_RANCHERD_SERVER__'
semantic_before = hashlib.sha256(pattern.sub(sentinel, raw, count=1)).hexdigest()
replacement = ('server: "' + expected + '"').encode('utf-8')
updated = pattern.sub(replacement, raw, count=1)
if updated == raw:
    raise SystemExit(73)
st = path.stat()
tmp = path.with_name(path.name + '.layersentry-vip-correction.tmp')
try:
    with open(tmp, 'wb') as handle:
        handle.write(updated)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, st.st_mode & 0o7777)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.replace(tmp, path)
    directory_fd = os.open(str(path.parent), os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
finally:
    if tmp.exists():
        tmp.unlink()
after = path.read_bytes()
semantic_after = hashlib.sha256(pattern.sub(sentinel, after, count=1)).hexdigest()
full_before = hashlib.sha256(raw).hexdigest()
full_after = hashlib.sha256(after).hexdigest()
if semantic_before != semantic_after:
    raise SystemExit(74)
print('LAYERSENTRY_ENDPOINT_CORRECTION=' + json.dumps({
    'oldServer': known,
    'newServer': expected,
    'rancherdConfigSha256Before': full_before,
    'rancherdConfigSha256After': full_after,
    'semanticSha256Before': semantic_before,
    'semanticSha256After': semantic_after,
    'onlyServerLineChanged': True,
}, sort_keys=True))
PY
server_after=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml)
rancherd_sha_after=$(sudo -n sha256sum /etc/rancher/rancherd/config.yaml | awk '{print $1}')
harvester_sha_after=$(sudo -n sha256sum /oem/harvester.config | awk '{print $1}')
if [ "$server_after" != "$expected_server" ]; then exit 75; fi
if [ "$harvester_sha_after" != "$harvester_sha_before" ]; then exit 76; fi
sudo -n cp -a /etc/rancher/rancherd/config.yaml "$backup_root/rancherd-config.yaml.after-vip-correction"
printf 'LAYERSENTRY_ENDPOINT_CORRECTION_VERIFIED|%s|%s|%s|%s\n' "$rancherd_sha_before" "$rancherd_sha_after" "$harvester_sha_before" "$harvester_sha_after"
echo 'LAYERSENTRY_ENDPOINT_CORRECTION:PASS'
'@
        $mutationScript = $mutationScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
        $mutationScript = $mutationScript.Replace('{{EXPECTED_SERVER_B64}}', $expectedServerB64)
        $mutationScript = $mutationScript.Replace('{{KNOWN_SERVER_B64}}', $knownDriftedServerB64)
        $mutationScript = $mutationScript.Replace('{{KNOWN_CONFIG_SHA_B64}}', $knownConfigShaB64)
        $mutationScript = $mutationScript.Replace('{{HARVESTER_CONFIG_SHA_B64}}', $harvesterConfigShaB64)
        $mutationCall = Invoke-Sen2Script -Label 'sen2-authorized-vip-endpoint-correction' -Script $mutationScript
        if ($mutationCall.ExitCode -eq 64) {
            throw 'Exit-code-64 regression detected during the authorized known-drift correction; no service change or reboot was attempted.'
        }
        if ($mutationCall.ExitCode -ne 0) {
            throw "Authorized sen2 VIP endpoint correction failed with SSH exit code $($mutationCall.ExitCode); no service change or reboot was attempted."
        }
        $backupMatch = [regex]::Match($mutationCall.RawStdout, '(?m)^LAYERSENTRY_ENDPOINT_BACKUP_CREATED:(.+)$')
        if (-not $backupMatch.Success) {
            throw 'The required pre-correction backup marker is missing.'
        }
        $endpointBackupLocation = $backupMatch.Groups[1].Value.Trim()
        $endpointBackupCreated = $true
        $correctionMatch = [regex]::Match($mutationCall.RawStdout, '(?m)^LAYERSENTRY_ENDPOINT_CORRECTION=(\{.*\})\s*$')
        if (-not $correctionMatch.Success) {
            throw 'The sanitized endpoint-correction marker is missing.'
        }
        $correction = $correctionMatch.Groups[1].Value | ConvertFrom-Json
        if (-not [bool]$correction.onlyServerLineChanged) {
            throw 'The endpoint correction did not prove a server-line-only semantic change.'
        }
        if ([string]$correction.semanticSha256Before -cne [string]$correction.semanticSha256After) {
            throw 'The rancherd configuration changed outside the server line.'
        }
        if ([string]$correction.oldServer -cne $knownDriftedServer -or [string]$correction.newServer -cne $expectedServer) {
            throw 'The endpoint correction marker does not match the exact expected transition.'
        }
        if ($mutationCall.RawStdout -notmatch '(?m)^LAYERSENTRY_ENDPOINT_CORRECTION:PASS\s*$') {
            throw 'The endpoint correction did not reach PASS.'
        }
        $rancherdConfigurationChanged = $true
        $rancherdConfigSha256Before = [string]$correction.rancherdConfigSha256Before
        $rancherdConfigSha256After = [string]$correction.rancherdConfigSha256After
        $rancherdSemanticSha256Before = [string]$correction.semanticSha256Before
        $rancherdSemanticSha256After = [string]$correction.semanticSha256After
        $harvesterConfigSha256Before = [string]$preflight.harvesterConfigSha256
        $harvesterConfigSha256After = [string]$preflight.harvesterConfigSha256
    }
    else {
        $rancherdConfigurationChanged = $false
        $rancherdConfigSha256Before = [string]$preflight.rancherdConfigSha256
        $rancherdConfigSha256After = [string]$preflight.rancherdConfigSha256
        $harvesterConfigSha256Before = [string]$preflight.harvesterConfigSha256
        $harvesterConfigSha256After = [string]$preflight.harvesterConfigSha256
    }

    & $boundRepairPath `
        -RequestPath $RequestPath `
        -ExpectedRancherdServerUrl $expectedServer `
        -CredentialPath $CredentialPath `
        -OutputDirectory $serviceOutputDirectory `
        -InitialWaitMinutes $InitialWaitMinutes `
        -StableSamples $StableSamples `
        -StableIntervalSeconds $StableIntervalSeconds

    $serviceResultPath = Join-Path $serviceOutputDirectory 'repair-result.json'
    if (-not (Test-Path -LiteralPath $serviceResultPath -PathType Leaf)) {
        throw 'The VIP-bound service-repair result is missing.'
    }
    $serviceRepair = Get-Content -LiteralPath $serviceResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$serviceRepair.passed) {
        throw "The VIP-bound sen2 service repair did not pass: $($serviceRepair.failure)"
    }
    if ([string]$serviceRepair.expectedRancherdServerUrl -cne $expectedServer) {
        throw 'The inner service repair used an unexpected rancherd endpoint.'
    }
    if (-not [bool]$serviceRepair.backupCreated) {
        throw 'The inner service repair did not create its pre-service configuration backup.'
    }
    if (-not [bool]$serviceRepair.rke2ServerDisabled -or -not [bool]$serviceRepair.rke2AgentEnabled) {
        throw 'The inner service repair did not reach the required server-disabled/agent-enabled state.'
    }
    if ([string]$serviceRepair.rebootedNode -cne 'sen2') {
        throw 'The inner service repair did not prove that only sen2 was rebooted.'
    }
    if ([int]$serviceRepair.consecutiveStableSamples -ne 24 -or [int]$serviceRepair.stabilityIntervalSeconds -ne 30) {
        throw 'The inner service repair did not complete 24 consecutive 30-second stability samples.'
    }
    if (-not [bool]$serviceRepair.exit64RegressionGuardPassed) {
        throw 'The inner exact-URL exit-code-64 guard did not pass.'
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
        schemaVersion = '3.0'
        requestId = [string]$request.requestId
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        targetNode = 'sen2'
        targetAddress = '10.10.10.12'
        expectedRancherdServerUrl = $expectedServer
        knownDriftedRancherdServerUrl = $knownDriftedServer
        observedRancherdServerUrl = if ($null -ne $preflight) { [string]$preflight.server } else { $null }
        endpointDecision = if ($null -ne $endpointDecision) { [string]$endpointDecision.decision } else { $null }
        endpointRejectionExitCode = if ($null -ne $endpointDecision) { [int]$endpointDecision.rejectionExitCode } else { $null }
        exit64RegressionTestsPassed = $exit64RegressionTestsPassed
        baseRepairEndpointLiteralReplacementCount = $literalReplacementCount
        endpointBackupCreated = $endpointBackupCreated
        endpointBackupLocation = $endpointBackupLocation
        rancherdConfigurationChanged = $rancherdConfigurationChanged
        rancherdConfigSha256Before = $rancherdConfigSha256Before
        rancherdConfigSha256After = $rancherdConfigSha256After
        rancherdSemanticSha256Before = $rancherdSemanticSha256Before
        rancherdSemanticSha256After = $rancherdSemanticSha256After
        harvesterConfigurationChanged = $false
        harvesterConfigSha256Before = $harvesterConfigSha256Before
        harvesterConfigSha256After = $harvesterConfigSha256After
        serviceRepairPassed = if ($null -ne $serviceRepair) { [bool]$serviceRepair.passed } else { $false }
        rke2ServerDisabled = if ($null -ne $serviceRepair) { [bool]$serviceRepair.rke2ServerDisabled } else { $false }
        rke2AgentEnabled = if ($null -ne $serviceRepair) { [bool]$serviceRepair.rke2AgentEnabled } else { $false }
        rebootedNode = if ($null -ne $serviceRepair) { [string]$serviceRepair.rebootedNode } else { $null }
        consecutiveStableSamples = if ($null -ne $serviceRepair) { [int]$serviceRepair.consecutiveStableSamples } else { 0 }
        stabilityIntervalSeconds = $StableIntervalSeconds
        authoritativeSourceModified = $false
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        kubeconfigWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        passed = $passed
        failure = $failure
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry sen2 VIP endpoint and agent-service recovery

- Target: **sen2 / 10.10.10.12**
- Expected Harvester JOIN endpoint: **$expectedServer**
- Known correctable drift: **$knownDriftedServer**
- Observed preflight endpoint: **$(if ($null -ne $preflight) { $preflight.server } else { 'not-observed' })**
- Endpoint decision: **$(if ($null -ne $endpointDecision) { $endpointDecision.decision } else { 'not-established' })**
- Exit-code-64 regression tests passed: **$exit64RegressionTestsPassed**
- Endpoint backup created: **$endpointBackupCreated**
- Rancherd server configuration changed: **$rancherdConfigurationChanged**
- Harvester configuration changed: **false**
- rke2-server disabled: **$(if ($null -ne $serviceRepair) { [bool]$serviceRepair.rke2ServerDisabled } else { $false })**
- rke2-agent enabled: **$(if ($null -ne $serviceRepair) { [bool]$serviceRepair.rke2AgentEnabled } else { $false })**
- Rebooted node: **$(if ($null -ne $serviceRepair) { $serviceRepair.rebootedNode } else { 'none' })**
- Consecutive stability samples: **$(if ($null -ne $serviceRepair) { $serviceRepair.consecutiveStableSamples } else { 0 }) / $StableSamples**
- RKE2 data deleted: **false**
- VM disk wiped or VM reinstalled: **false**
- EULA automatically accepted: **false**
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
