[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$PrimaryNodeAddress = '10.10.10.11',
    [hashtable]$JoinNodes = @{ sen2 = '10.10.10.12'; sen3 = '10.10.10.13' },
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [int]$MaxWaitMinutes = 15,
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-join-repair')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module Hyper-V -ErrorAction Stop

$script:SensitiveValues = New-Object System.Collections.Generic.List[string]

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

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties |
            Where-Object { $_.Name -ieq $name } |
            Select-Object -First 1
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return $null
}

function Add-SensitiveValue {
    param([AllowNull()][string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $script:SensitiveValues.Contains($Value)) {
        $script:SensitiveValues.Add($Value)
    }
}

function Protect-Text {
    param([AllowNull()][string]$Text)

    $safe = [string]$Text
    foreach ($secret in $script:SensitiveValues) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $safe = $safe.Replace($secret, '[REDACTED]')
        }
    }
    $safe = [regex]::Replace(
        $safe,
        '(?im)^(LAYERSENTRY_AUTHORITATIVE_TOKEN_B64=).+$',
        '$1[REDACTED]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?im)^(\s*(?:token|password|authorization|credential)\s*[:=]).+$',
        '$1 [REDACTED]'
    )
    return $safe
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 1500
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

function Invoke-SshScript {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$TemporaryDirectory,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [int]$TimeoutSeconds = 600
    )

    $ssh = Get-Command -Name 'ssh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ssh) {
        throw 'Windows OpenSSH client ssh.exe is not installed.'
    }

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $scriptPath = Join-Path $TemporaryDirectory "$safeLabel.remote.sh"
    $stdoutPath = Join-Path $TemporaryDirectory "$safeLabel.stdout.raw"
    $stderrPath = Join-Path $TemporaryDirectory "$safeLabel.stderr.raw"
    $safeStdoutPath = Join-Path $EvidenceDirectory "$safeLabel.stdout.txt"
    $safeStderrPath = Join-Path $EvidenceDirectory "$safeLabel.stderr.txt"

    $normalizedScript = ($Script -replace "`r`n", "`n").TrimStart([char]0xFEFF)
    Write-Utf8NoBom -Path $scriptPath -Value $normalizedScript

    $arguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'ConnectTimeout=20',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=4',
        '-o', 'LogLevel=ERROR',
        "rancher@$Address",
        'bash', '-s'
    )

    $process = Start-Process `
        -FilePath $ssh.Source `
        -ArgumentList $arguments `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardInput $scriptPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw "SSH operation $Label timed out after $TimeoutSeconds seconds."
    }
    $process.Refresh()
    $exitCode = [int]$process.ExitCode

    $rawStdout = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
    $rawStderr = [string](Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
    $safeStdout = Protect-Text -Text $rawStdout
    $safeStderr = Protect-Text -Text $rawStderr
    Write-Utf8NoBom -Path $safeStdoutPath -Value $safeStdout
    Write-Utf8NoBom -Path $safeStderrPath -Value $safeStderr

    Remove-Item -LiteralPath $scriptPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Address = $Address
        Label = $Label
        ExitCode = $exitCode
        RawStdout = $rawStdout
        SafeStdout = $safeStdout
        SafeStderr = $safeStderr
        Succeeded = ($exitCode -eq 0)
    }
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$tempDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-targeted-join-repair-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $tempDirectory

$resultPath = Join-Path $OutputDirectory 'join-repair-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$historyPath = Join-Path $OutputDirectory 'readiness-history.jsonl'
$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$authoritativeTokenSource = $null
$localTokenMatchedPrimary = $null
$repairResults = @()
$readiness = @()
$kubernetesNodes = @()
$threeNodeReady = $false
$credentials = $null
$nodePassword = $null
$localClusterToken = $null
$authoritativeClusterToken = $null
$adminPassword = $null
$oldAskPass = $env:SSH_ASKPASS
$oldAskPassRequire = $env:SSH_ASKPASS_REQUIRE
$oldDisplay = $env:DISPLAY

try {
    if ($ClusterUrl -ne 'https://10.10.10.10') {
        throw "Unexpected cluster URL: $ClusterUrl"
    }
    if ($PrimaryNodeAddress -ne '10.10.10.11') {
        throw "Unexpected primary node address: $PrimaryNodeAddress"
    }
    $expectedJoinNodes = @{ sen2 = '10.10.10.12'; sen3 = '10.10.10.13' }
    if ($JoinNodes.Count -ne 2) {
        throw 'Exactly sen2 and sen3 must be supplied as join nodes.'
    }
    foreach ($name in $expectedJoinNodes.Keys) {
        if (-not $JoinNodes.ContainsKey($name) -or [string]$JoinNodes[$name] -ne $expectedJoinNodes[$name]) {
            throw "Join-node mapping for $name is invalid."
        }
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw "Credential file is missing: $CredentialPath"
    }
    $credentialAcl = Get-Acl -LiteralPath $CredentialPath
    $unexpectedAccess = @(
        $credentialAcl.Access |
            Where-Object {
                $_.AccessControlType -eq 'Allow' -and
                $_.IdentityReference.Value -notmatch 'SYSTEM$|Administrators$' -and
                ($_.FileSystemRights.ToString() -match 'Read|FullControl|Modify')
            }
    )
    if ($unexpectedAccess.Count -gt 0) {
        throw 'The protected credential file grants read access outside SYSTEM/Administrators.'
    }

    $credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $nodePassword = Get-PropertyValue -Object $credentials -Names @('nodePassword', 'NodePassword')
    $localClusterToken = Get-PropertyValue -Object $credentials -Names @('clusterToken', 'ClusterToken')
    $adminPassword = Get-PropertyValue -Object $credentials -Names @('adminPassword', 'AdminPassword')
    if ([string]::IsNullOrWhiteSpace($nodePassword) -or $nodePassword.Length -lt 16) {
        throw 'The protected credential file has no valid node password.'
    }
    if ([string]::IsNullOrWhiteSpace($localClusterToken) -or $localClusterToken.Length -lt 12) {
        throw 'The protected credential file has no valid cluster token.'
    }
    Add-SensitiveValue -Value $nodePassword
    Add-SensitiveValue -Value $localClusterToken
    Add-SensitiveValue -Value $adminPassword
    Add-SensitiveValue -Value ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($localClusterToken)))

    $nodePasswordPath = Join-Path $tempDirectory 'node-password.txt'
    $askPassPath = Join-Path $tempDirectory 'askpass.cmd'
    Write-Utf8NoBom -Path $nodePasswordPath -Value ($nodePassword + "`r`n")
    Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$nodePasswordPath`"`r`n")
    $env:SSH_ASKPASS = $askPassPath
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:DISPLAY = 'LayerSentry'

    foreach ($vmName in @('sen1', 'sen2', 'sen3')) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ([string]$vm.State -eq 'Off') {
            Start-VM -Name $vmName -ErrorAction Stop | Out-Null
        }
    }

    $nodePasswordB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))
    $primaryTokenScript = @'
set -eu
umask 077
work=$(mktemp -d /tmp/layersentry-primary-token.XXXXXX)
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
  echo 'LAYERSENTRY_PRIMARY_TOKEN_ERROR:yq-not-found'
  exit 41
fi
token=''
source_file=''
for candidate in /etc/rancher/rancherd/config.yaml /oem/harvester.config; do
  if sudo -n test -f "$candidate"; then
    value=$(sudo -n "$yq_path" e -r '.token // ""' "$candidate" 2>/dev/null || true)
    if [ -n "$value" ] && [ "$value" != 'null' ]; then
      token="$value"
      source_file="$candidate"
      break
    fi
  fi
done
if [ -z "$token" ]; then
  echo 'LAYERSENTRY_PRIMARY_TOKEN_ERROR:token-not-found'
  exit 42
fi
printf 'LAYERSENTRY_AUTHORITATIVE_TOKEN_SOURCE=%s\n' "$source_file"
printf 'LAYERSENTRY_AUTHORITATIVE_TOKEN_B64=%s\n' "$(printf '%s' "$token" | base64 | tr -d '\r\n')"
echo 'LAYERSENTRY_PRIMARY_TOKEN_OK'
'@
    $primaryTokenScript = $primaryTokenScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $primaryResult = Invoke-SshScript `
        -Address $PrimaryNodeAddress `
        -Label 'sen1-authoritative-token' `
        -Script $primaryTokenScript `
        -TemporaryDirectory $tempDirectory `
        -EvidenceDirectory $OutputDirectory `
        -TimeoutSeconds 120
    if (-not $primaryResult.Succeeded) {
        throw "Could not read the authoritative cluster token from sen1. Exit code: $($primaryResult.ExitCode)"
    }
    $tokenMatch = [regex]::Match(
        $primaryResult.RawStdout,
        '(?m)^LAYERSENTRY_AUTHORITATIVE_TOKEN_B64=([A-Za-z0-9+/=]+)\s*$'
    )
    if (-not $tokenMatch.Success) {
        throw 'sen1 did not return an authoritative cluster token marker.'
    }
    $authoritativeClusterToken = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($tokenMatch.Groups[1].Value)
    )
    if ([string]::IsNullOrWhiteSpace($authoritativeClusterToken)) {
        throw 'The authoritative cluster token decoded to an empty value.'
    }
    Add-SensitiveValue -Value $authoritativeClusterToken
    Add-SensitiveValue -Value $tokenMatch.Groups[1].Value
    $sourceMatch = [regex]::Match(
        $primaryResult.RawStdout,
        '(?m)^LAYERSENTRY_AUTHORITATIVE_TOKEN_SOURCE=(.+)\s*$'
    )
    $authoritativeTokenSource = if ($sourceMatch.Success) {
        $sourceMatch.Groups[1].Value.Trim()
    }
    else {
        'sen1-protected-config'
    }
    $localTokenMatchedPrimary = ($localClusterToken -ceq $authoritativeClusterToken)
    $primaryResult.RawStdout = $null

    $authoritativeTokenB64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($authoritativeClusterToken)
    )
    foreach ($vmName in @('sen2', 'sen3')) {
        $address = [string]$JoinNodes[$vmName]
        $repairScript = @'
set -u
umask 077
node_name='{{NODE_NAME}}'
node_address='{{NODE_ADDRESS}}'
server_url='https://10.10.10.10:443'
rke2_server_url='https://10.10.10.10:9345'
work=$(mktemp -d /tmp/layersentry-join-repair.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
printf '%s' '{{CLUSTER_TOKEN_B64}}' | base64 -d > "$work/cluster-token"
chmod 0600 "$work/node-password" "$work/cluster-token"
if ! sudo -n true >/dev/null 2>&1; then
  if ! sudo -S -p '' -v < "$work/node-password"; then
    echo "LAYERSENTRY_JOIN_REPAIR_ERROR:${node_name}:sudo-authentication-failed"
    exit 51
  fi
fi

yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then
  echo "LAYERSENTRY_JOIN_REPAIR_ERROR:${node_name}:yq-not-found"
  exit 52
fi

echo "LAYERSENTRY_JOIN_REPAIR_BEGIN:${node_name}"
echo "LAYERSENTRY_HOSTNAME_BEFORE:$(hostname)"
echo 'LAYERSENTRY_NETWORK_BEFORE_BEGIN'
ip -4 -br address 2>/dev/null || true
ip route 2>/dev/null || true
for target in 10.10.10.10 10.10.10.11; do
  for port in 443 6443 9345; do
    if timeout 3 bash -c "</dev/tcp/${target}/${port}" >/dev/null 2>&1; then
      echo "LAYERSENTRY_REMOTE_PORT:${target}:${port}:open"
    else
      echo "LAYERSENTRY_REMOTE_PORT:${target}:${port}:closed"
    fi
  done
done
echo 'LAYERSENTRY_NETWORK_BEFORE_END'

for service in rancherd rancher-system-agent rke2-agent rke2-server; do
  if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null | grep -q "${service}.service"; then
    enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
    active=$(systemctl is-active "$service" 2>/dev/null || true)
    echo "LAYERSENTRY_SERVICE_BEFORE:${service}:${enabled}:${active}"
  else
    echo "LAYERSENTRY_SERVICE_BEFORE:${service}:missing:missing"
  fi
done

summarize_config() {
  file="$1"
  kind="$2"
  if ! sudo -n test -f "$file"; then
    echo "LAYERSENTRY_CONFIG:${kind}:missing:${file}"
    return 0
  fi
  if [ "$kind" = 'harvester' ]; then
    server=$(sudo -n "$yq_path" e -r '.serverurl // .server_url // .serverUrl // ""' "$file" 2>/dev/null || true)
    hostname_value=$(sudo -n "$yq_path" e -r '.os.hostname // ""' "$file" 2>/dev/null || true)
    mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' "$file" 2>/dev/null || true)
    token_present=false
    token_value=$(sudo -n "$yq_path" e -r '.token // ""' "$file" 2>/dev/null || true)
    if [ -n "$token_value" ] && [ "$token_value" != 'null' ]; then token_present=true; fi
    echo "LAYERSENTRY_CONFIG:${kind}:server=${server}:hostname=${hostname_value}:mode=${mode}:tokenPresent=${token_present}:file=${file}"
  else
    server=$(sudo -n "$yq_path" e -r '.server // ""' "$file" 2>/dev/null || true)
    role=$(sudo -n "$yq_path" e -r '.role // ""' "$file" 2>/dev/null || true)
    node=$(sudo -n "$yq_path" e -r '.nodeName // ""' "$file" 2>/dev/null || true)
    token_present=false
    token_value=$(sudo -n "$yq_path" e -r '.token // ""' "$file" 2>/dev/null || true)
    if [ -n "$token_value" ] && [ "$token_value" != 'null' ]; then token_present=true; fi
    echo "LAYERSENTRY_CONFIG:${kind}:server=${server}:role=${role}:nodeName=${node}:tokenPresent=${token_present}:file=${file}"
  fi
  unset token_value
}

summarize_config /oem/harvester.config harvester
summarize_config /etc/rancher/rancherd/config.yaml rancherd
summarize_config /etc/rancher/rke2/config.yaml.d/90-harvester-vip.yaml rke2-vip

if ! sudo -n test -f /oem/harvester.config; then
  echo "LAYERSENTRY_JOIN_REPAIR_ERROR:${node_name}:oem-config-missing"
  exit 53
fi
if ! sudo -n test -f /etc/rancher/rancherd/config.yaml; then
  echo "LAYERSENTRY_JOIN_REPAIR_ERROR:${node_name}:rancherd-config-missing"
  exit 54
fi

backup_root="/oem/layersentry-join-repair-backups/$(date -u +%Y%m%dT%H%M%SZ)-${node_name}"
sudo -n mkdir -p "$backup_root"
for file in /oem/harvester.config /etc/rancher/rancherd/config.yaml /etc/rancher/rke2/config.yaml.d/90-harvester-vip.yaml; do
  if sudo -n test -f "$file"; then
    destination="$backup_root$(dirname "$file")"
    sudo -n mkdir -p "$destination"
    sudo -n cp -a "$file" "$destination/"
  fi
done

token=$(cat "$work/cluster-token")
sudo -n env \
  SERVER_URL="$server_url" \
  CLUSTER_TOKEN="$token" \
  NODE_NAME="$node_name" \
  "$yq_path" e -i '
    .serverurl = strenv(SERVER_URL) |
    del(.server_url) |
    del(.serverUrl) |
    .token = strenv(CLUSTER_TOKEN) |
    .os.hostname = strenv(NODE_NAME) |
    .install.mode = "join"
  ' /oem/harvester.config
sudo -n chmod 0600 /oem/harvester.config
sudo -n chown root:root /oem/harvester.config

sudo -n env \
  SERVER_URL="$server_url" \
  CLUSTER_TOKEN="$token" \
  NODE_NAME="$node_name" \
  "$yq_path" e -i '
    .server = strenv(SERVER_URL) |
    .role = "agent" |
    .nodeName = strenv(NODE_NAME) |
    .token = strenv(CLUSTER_TOKEN)
  ' /etc/rancher/rancherd/config.yaml
sudo -n chmod 0600 /etc/rancher/rancherd/config.yaml
sudo -n chown root:root /etc/rancher/rancherd/config.yaml
unset token

sudo -n mkdir -p /etc/rancher/rke2/config.yaml.d
if sudo -n test -x /usr/sbin/harv-update-rke2-server-url; then
  if ! sudo -n /usr/sbin/harv-update-rke2-server-url agent >/dev/null 2>&1; then
    sudo -n env RKE2_SERVER_URL="$rke2_server_url" "$yq_path" -n e '.server = strenv(RKE2_SERVER_URL)' > "$work/90-harvester-vip.yaml"
    sudo -n install -o root -g root -m 0600 "$work/90-harvester-vip.yaml" /etc/rancher/rke2/config.yaml.d/90-harvester-vip.yaml
  fi
else
  sudo -n env RKE2_SERVER_URL="$rke2_server_url" "$yq_path" -n e '.server = strenv(RKE2_SERVER_URL)' > "$work/90-harvester-vip.yaml"
  sudo -n install -o root -g root -m 0600 "$work/90-harvester-vip.yaml" /etc/rancher/rke2/config.yaml.d/90-harvester-vip.yaml
fi

if command -v timedatectl >/dev/null 2>&1; then
  sudo -n timedatectl set-ntp true >/dev/null 2>&1 || true
fi
sudo -n systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
sudo -n systemctl daemon-reload
sudo -n systemctl reset-failed rancherd rke2-agent rke2-server rancher-system-agent >/dev/null 2>&1 || true
sudo -n systemctl enable rancherd >/dev/null 2>&1 || true
sudo -n systemctl restart rancherd
sleep 12
if systemctl list-unit-files rancher-system-agent.service --no-legend 2>/dev/null | grep -q rancher-system-agent.service; then
  sudo -n systemctl restart rancher-system-agent >/dev/null 2>&1 || true
fi
if systemctl list-unit-files rke2-agent.service --no-legend 2>/dev/null | grep -q rke2-agent.service; then
  sudo -n systemctl restart rke2-agent >/dev/null 2>&1 || true
fi

summarize_config /oem/harvester.config harvester
summarize_config /etc/rancher/rancherd/config.yaml rancherd
summarize_config /etc/rancher/rke2/config.yaml.d/90-harvester-vip.yaml rke2-vip

for attempt in $(seq 1 40); do
  agent_active=$(systemctl is-active rke2-agent 2>/dev/null || true)
  server_active=$(systemctl is-active rke2-server 2>/dev/null || true)
  kubelet_open=false
  if timeout 2 bash -c '</dev/tcp/127.0.0.1/10250' >/dev/null 2>&1; then kubelet_open=true; fi
  echo "LAYERSENTRY_LOCAL_READINESS:${node_name}:attempt=${attempt}:rke2Agent=${agent_active}:rke2Server=${server_active}:kubelet10250=${kubelet_open}"
  if [ "$kubelet_open" = true ]; then
    break
  fi
  sleep 15
done

for service in rancherd rancher-system-agent rke2-agent rke2-server; do
  if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null | grep -q "${service}.service"; then
    enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
    active=$(systemctl is-active "$service" 2>/dev/null || true)
    echo "LAYERSENTRY_SERVICE_AFTER:${service}:${enabled}:${active}"
  fi
done

echo 'LAYERSENTRY_SANITIZED_JOURNAL_BEGIN'
sudo -n journalctl -u rancherd -u rancher-system-agent -u rke2-agent -u rke2-server -n 180 --no-pager 2>/dev/null |
  grep -viE 'token|password|authorization|credential|secret' |
  tail -n 120 || true
echo 'LAYERSENTRY_SANITIZED_JOURNAL_END'
echo "LAYERSENTRY_JOIN_REPAIR_APPLIED:${node_name}"
'@
        $repairScript = $repairScript.Replace('{{NODE_NAME}}', $vmName)
        $repairScript = $repairScript.Replace('{{NODE_ADDRESS}}', $address)
        $repairScript = $repairScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
        $repairScript = $repairScript.Replace('{{CLUSTER_TOKEN_B64}}', $authoritativeTokenB64)

        $repairResult = Invoke-SshScript `
            -Address $address `
            -Label "$vmName-repair" `
            -Script $repairScript `
            -TemporaryDirectory $tempDirectory `
            -EvidenceDirectory $OutputDirectory `
            -TimeoutSeconds 900
        $repairMarker = $repairResult.SafeStdout -match "LAYERSENTRY_JOIN_REPAIR_APPLIED:$vmName"
        $repairResults += [ordered]@{
            name = $vmName
            address = $address
            sshExitCode = $repairResult.ExitCode
            repairMarker = $repairMarker
            succeeded = ($repairResult.Succeeded -and $repairMarker)
            stdoutEvidence = "$vmName-repair.stdout.txt"
            stderrEvidence = "$vmName-repair.stderr.txt"
        }
        $repairResult.RawStdout = $null
    }

    if (@($repairResults | Where-Object { -not $_.succeeded }).Count -gt 0) {
        throw 'One or more join-node configuration repairs did not complete successfully.'
    }

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    do {
        $snapshot = @()
        foreach ($vmName in @('sen1', 'sen2', 'sen3')) {
            $address = switch ($vmName) {
                'sen1' { $PrimaryNodeAddress }
                default { [string]$JoinNodes[$vmName] }
            }
            $snapshot += [ordered]@{
                name = $vmName
                address = $address
                ping = [bool](Test-Connection -ComputerName $address -Count 1 -Quiet -ErrorAction SilentlyContinue)
                tcp22 = (Test-TcpPort -Address $address -Port 22)
                tcp9345 = (Test-TcpPort -Address $address -Port 9345)
                tcp10250 = (Test-TcpPort -Address $address -Port 10250)
            }
        }
        $vip443 = Test-TcpPort -Address '10.10.10.10' -Port 443 -TimeoutMilliseconds 2000
        $vip6443 = Test-TcpPort -Address '10.10.10.10' -Port 6443 -TimeoutMilliseconds 2000
        $joinKubelets = @(
            $snapshot |
                Where-Object { $_.name -in @('sen2', 'sen3') -and $_.tcp10250 }
        ).Count
        $readiness = $snapshot
        ([ordered]@{
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            nodes = $snapshot
            vip443 = $vip443
            vip6443 = $vip6443
            joinKubeletCount = $joinKubelets
        } | ConvertTo-Json -Depth 8 -Compress) |
            Add-Content -LiteralPath $historyPath -Encoding UTF8
        if ($joinKubelets -lt 2) {
            Start-Sleep -Seconds 15
        }
    } while ($joinKubelets -lt 2 -and (Get-Date) -lt $deadline)

    $validationScript = @'
set -eu
umask 077
work=$(mktemp -d /tmp/layersentry-kubernetes-proof.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
kubectl_path=$(command -v kubectl 2>/dev/null || true)
if [ -z "$kubectl_path" ] && [ -x /var/lib/rancher/rke2/bin/kubectl ]; then
  kubectl_path=/var/lib/rancher/rke2/bin/kubectl
fi
if [ -z "$kubectl_path" ]; then
  echo 'LAYERSENTRY_KUBERNETES_PROOF_ERROR:kubectl-not-found'
  exit 61
fi
kubeconfig=/etc/rancher/rke2/rke2.yaml
for attempt in $(seq 1 80); do
  node_lines=$(sudo -n "$kubectl_path" --kubeconfig "$kubeconfig" get nodes --no-headers 2>/dev/null || true)
  total=$(printf '%s\n' "$node_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  ready=$(printf '%s\n' "$node_lines" | awk '$2 ~ /^Ready/ {c++} END {print c+0}')
  names=$(printf '%s\n' "$node_lines" | awk '{print $1}' | sort | tr '\n' ',' | sed 's/,$//')
  echo "LAYERSENTRY_KUBERNETES_POLL:attempt=${attempt}:total=${total}:ready=${ready}:names=${names}"
  if [ "$total" = '3' ] && [ "$ready" = '3' ] && [ "$names" = 'sen1,sen2,sen3' ]; then
    printf '%s\n' "$node_lines" | awk '{print "LAYERSENTRY_NODE|" $1 "|" $2 "|" $3 "|" $4 "|" $5}'
    echo 'LAYERSENTRY_THREE_NODE_READY'
    exit 0
  fi
  sleep 15
done
sudo -n "$kubectl_path" --kubeconfig "$kubeconfig" get nodes -o wide 2>/dev/null || true
sudo -n "$kubectl_path" --kubeconfig "$kubeconfig" get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null |
  grep -viE 'token|password|authorization|credential|secret' |
  head -n 100 || true
echo 'LAYERSENTRY_KUBERNETES_PROOF_ERROR:three-ready-nodes-not-reached'
exit 62
'@
    $validationScript = $validationScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $validationResult = Invoke-SshScript `
        -Address $PrimaryNodeAddress `
        -Label 'sen1-three-node-proof' `
        -Script $validationScript `
        -TemporaryDirectory $tempDirectory `
        -EvidenceDirectory $OutputDirectory `
        -TimeoutSeconds (($MaxWaitMinutes * 60) + 180)
    $threeNodeReady = ($validationResult.Succeeded -and $validationResult.SafeStdout -match 'LAYERSENTRY_THREE_NODE_READY')
    foreach ($line in ($validationResult.SafeStdout -split "`r?`n")) {
        if ($line -match '^LAYERSENTRY_NODE\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|(.+)$') {
            $kubernetesNodes += [ordered]@{
                name = $matches[1]
                status = $matches[2]
                roles = $matches[3]
                age = $matches[4]
                version = $matches[5]
            }
        }
    }
    $validationResult.RawStdout = $null

    if (-not $threeNodeReady) {
        throw 'Kubernetes did not report exactly sen1, sen2 and sen3 as Ready after the targeted repair.'
    }

    $passed = $true
}
catch {
    $failure = Protect-Text -Text $_.Exception.Message
    throw
}
finally {
    $env:SSH_ASKPASS = $oldAskPass
    $env:SSH_ASKPASS_REQUIRE = $oldAskPassRequire
    $env:DISPLAY = $oldDisplay

    $finishedAt = (Get-Date).ToUniversalTime()
    $evidence = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        clusterUrl = $ClusterUrl
        primaryNodeAddress = $PrimaryNodeAddress
        joinNodes = [ordered]@{
            sen2 = '10.10.10.12'
            sen3 = '10.10.10.13'
        }
        authoritativeTokenSource = $authoritativeTokenSource
        localProtectedTokenMatchedPrimary = $localTokenMatchedPrimary
        credentialValuesWrittenToEvidence = $false
        repairResults = $repairResults
        finalNetworkReadiness = $readiness
        kubernetesNodes = $kubernetesNodes
        threeNodeReady = $threeNodeReady
        passed = $passed
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        failure = $failure
    }
    $evidence | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry targeted join-node repair

- Cluster URL: $ClusterUrl
- Primary node: $PrimaryNodeAddress
- Repaired nodes: sen2, sen3
- Authoritative token source: $authoritativeTokenSource
- Local protected token matched primary: $localTokenMatchedPrimary
- Join-node repair operations passed: $(@($repairResults | Where-Object { $_.succeeded }).Count)/2
- Kubernetes nodes observed: $($kubernetesNodes.Count)
- Exactly sen1, sen2 and sen3 Ready: $threeNodeReady
- Targeted repair passed: $passed
- EULA automatically accepted: **false**
- Credential values written to evidence: **false**
- Production release approved: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $authoritativeClusterToken = $null
    $localClusterToken = $null
    $nodePassword = $null
    $adminPassword = $null
    $credentials = $null
    $script:SensitiveValues.Clear()
}
