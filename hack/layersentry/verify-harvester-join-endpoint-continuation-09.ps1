[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-harvester-join-endpoint-verification-09')
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
        [int]$TimeoutMilliseconds = 3000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        $waitHandle = $async.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return [bool]$client.Connected
    }
    catch { return $false }
    finally {
        if ($null -ne $waitHandle) { $waitHandle.Close() }
        $client.Close()
        $client.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Join-endpoint verification request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -cne 'VERIFY_HARVESTER_JOIN_ENDPOINT_FROM_CLUSTER_VIP_READ_ONLY') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -cne 'USER_GRANTED_READ_ONLY_ENDPOINT_VERIFICATION') {
    throw 'The request is missing the read-only authorization marker.'
}
if ([string]$request.joinEndpointPolicy -cne 'HARVESTER_JOIN_SERVER_URL_MUST_USE_CLUSTER_VIP_443') {
    throw 'The request is missing the Harvester join-endpoint policy binding.'
}
if ([string]$request.expectedClusterVip -cne '10.10.10.10') {
    throw 'The expected Harvester cluster VIP must be exactly 10.10.10.10.'
}
if ([string]$request.expectedJoinServerUrl -cne 'https://10.10.10.10:443') {
    throw 'The expected Harvester JOIN server URL must be exactly https://10.10.10.10:443.'
}
if ([string]$request.managementApiUrl -cne 'https://10.10.10.10') {
    throw 'The management/API URL must be exactly https://10.10.10.10.'
}
if ([string]$request.targetNode -cne 'sen2' -or [string]$request.targetAddress -cne '10.10.10.12') {
    throw 'The target must be sen2 at 10.10.10.12.'
}
if ([string]$request.peerNode -cne 'sen3' -or [string]$request.peerAddress -cne '10.10.10.13') {
    throw 'The peer must be sen3 at 10.10.10.13.'
}
if ([string]$request.primaryNode -cne 'sen1' -or [string]$request.primaryAddress -cne '10.10.10.11') {
    throw 'The primary source must be sen1 at 10.10.10.11.'
}
if ([string]$request.expectedTargetMachineName -cne 'fleet-local/custom-81a2c5e94b13') {
    throw 'The request is not bound to the authoritative sen2 Rancher machine.'
}
if ([string]$request.expectedPlanSecretUid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    throw 'The expected plan Secret UID is invalid.'
}
if ([string]$request.expectedPlanSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'The expected worker plan SHA-256 is invalid.'
}
foreach ($forbidden in @(
    'mutateAuthoritativeSource',
    'changeNodeConfiguration',
    'changeServices',
    'rebootNode',
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
    $safe = [regex]::Replace($safe, '(?i)K10[a-z0-9]{20,}::server:[a-z0-9]{20,}', '[REDACTED-RKE2-TOKEN]')
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
$resultPath = Join-Path $OutputDirectory 'join-endpoint-verification-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-join-endpoint-secure-' + [Guid]::NewGuid().ToString('N'))
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

function Invoke-ReadOnlyNodeScript {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Script
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
        '-o', 'ConnectTimeout=20',
        "rancher@$Address",
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

function ConvertFrom-NodeMarker {
    param(
        [Parameter(Mandatory = $true)][string]$RawStdout,
        [Parameter(Mandatory = $true)][string]$ExpectedHostname
    )
    $match = [regex]::Match($RawStdout, '(?m)^LAYERSENTRY_HARVESTER_NODE_STATE=(\{.*\})\s*$')
    if (-not $match.Success) {
        throw "The sanitized node-state marker for $ExpectedHostname is missing."
    }
    $state = $match.Groups[1].Value | ConvertFrom-Json
    if ([string]$state.hostname -cne $ExpectedHostname) {
        throw "SSH target identity mismatch: expected $ExpectedHostname, observed $($state.hostname)."
    }
    return $state
}

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$sen1State = $null
$sen2State = $null
$sen3State = $null
$planState = $null
$authoritativeJoinUrl = $null
$classification = $null
$managementVipTcp443 = $false

try {
    foreach ($vmName in @('sen1', 'sen2', 'sen3')) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ([string]$vm.State -ne 'Running') {
            throw "$vmName must already be Running; current state is $($vm.State)."
        }
    }

    $nodeScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-harvester-join-endpoint.XXXXXX)
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
  echo 'LAYERSENTRY_JOIN_ENDPOINT_ERROR:yq-not-found'
  exit 111
fi
hostname_value=$(hostname)
rancherd_role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
rancherd_server=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
harvester_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
harvester_server_url=$(sudo -n "$yq_path" e -r '.server_url // ""' /oem/harvester.config 2>/dev/null || true)
harvester_vip=$(sudo -n "$yq_path" e -r '.install.vip // ""' /oem/harvester.config 2>/dev/null || true)
rancherd_config_sha256=$(sudo -n sha256sum /etc/rancher/rancherd/config.yaml 2>/dev/null | awk '{print $1}' || true)
harvester_config_sha256=$(sudo -n sha256sum /oem/harvester.config 2>/dev/null | awk '{print $1}' || true)
rke2_server_enabled=$(sudo -n systemctl is-enabled rke2-server.service 2>/dev/null || true)
rke2_server_active=$(sudo -n systemctl is-active rke2-server.service 2>/dev/null || true)
rke2_agent_enabled=$(sudo -n systemctl is-enabled rke2-agent.service 2>/dev/null || true)
rke2_agent_active=$(sudo -n systemctl is-active rke2-agent.service 2>/dev/null || true)
export HOSTNAME_VALUE="$hostname_value"
export RANCHERD_ROLE="$rancherd_role"
export RANCHERD_SERVER="$rancherd_server"
export HARVESTER_MODE="$harvester_mode"
export HARVESTER_SERVER_URL="$harvester_server_url"
export HARVESTER_VIP="$harvester_vip"
export RANCHERD_CONFIG_SHA256="$rancherd_config_sha256"
export HARVESTER_CONFIG_SHA256="$harvester_config_sha256"
export RKE2_SERVER_ENABLED="$rke2_server_enabled"
export RKE2_SERVER_ACTIVE="$rke2_server_active"
export RKE2_AGENT_ENABLED="$rke2_agent_enabled"
export RKE2_AGENT_ACTIVE="$rke2_agent_active"
python3 - <<'PY'
import json
import os
state = {
    'hostname': os.environ.get('HOSTNAME_VALUE', ''),
    'rancherdRole': os.environ.get('RANCHERD_ROLE', ''),
    'rancherdServer': os.environ.get('RANCHERD_SERVER', ''),
    'harvesterInstallMode': os.environ.get('HARVESTER_MODE', ''),
    'harvesterServerUrl': os.environ.get('HARVESTER_SERVER_URL', ''),
    'harvesterInstallVip': os.environ.get('HARVESTER_VIP', ''),
    'rancherdConfigSha256': os.environ.get('RANCHERD_CONFIG_SHA256', ''),
    'harvesterConfigSha256': os.environ.get('HARVESTER_CONFIG_SHA256', ''),
    'rke2ServerEnabled': os.environ.get('RKE2_SERVER_ENABLED', ''),
    'rke2ServerActive': os.environ.get('RKE2_SERVER_ACTIVE', ''),
    'rke2AgentEnabled': os.environ.get('RKE2_AGENT_ENABLED', ''),
    'rke2AgentActive': os.environ.get('RKE2_AGENT_ACTIVE', ''),
    'readOnly': True,
}
print('LAYERSENTRY_HARVESTER_NODE_STATE=' + json.dumps(state, sort_keys=True))
PY
'@
    $nodeScript = $nodeScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)

    foreach ($node in @(
        [pscustomobject]@{ Name = 'sen1'; Address = '10.10.10.11'; Label = 'sen1-harvester-config-readonly' },
        [pscustomobject]@{ Name = 'sen2'; Address = '10.10.10.12'; Label = 'sen2-harvester-config-readonly' },
        [pscustomobject]@{ Name = 'sen3'; Address = '10.10.10.13'; Label = 'sen3-harvester-config-readonly' }
    )) {
        $call = Invoke-ReadOnlyNodeScript -Address $node.Address -Label $node.Label -Script $nodeScript
        if ($call.ExitCode -ne 0) {
            throw "Read-only $($node.Name) Harvester configuration query failed with SSH exit code $($call.ExitCode)."
        }
        $state = ConvertFrom-NodeMarker -RawStdout $call.RawStdout -ExpectedHostname $node.Name
        switch ($node.Name) {
            'sen1' { $sen1State = $state }
            'sen2' { $sen2State = $state }
            'sen3' { $sen3State = $state }
        }
    }

    $planScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-worker-plan-verify.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
kubectl_path=''
for candidate in /var/lib/rancher/rke2/bin/kubectl /opt/rke2/bin/kubectl /usr/local/bin/kubectl /usr/bin/kubectl; do
  if [ -x "$candidate" ]; then kubectl_path=$candidate; break; fi
done
if [ -z "$kubectl_path" ]; then
  echo 'LAYERSENTRY_JOIN_ENDPOINT_ERROR:kubectl-not-found'
  exit 112
fi
k() { sudo -n "$kubectl_path" --kubeconfig /etc/rancher/rke2/rke2.yaml "$@"; }
k -n fleet-local get secret custom-81a2c5e94b13-machine-plan -o json > "$work/plan-secret.json"
export EXPECTED_UID='{{EXPECTED_UID}}'
export EXPECTED_SHA256='{{EXPECTED_SHA256}}'
python3 - "$work/plan-secret.json" <<'PY'
import base64
import hashlib
import json
import os
import sys
from pathlib import Path
secret = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
metadata = secret.get('metadata') or {}
uid = metadata.get('uid') or ''
annotations = metadata.get('annotations') or {}
labels = metadata.get('labels') or {}
encoded = (secret.get('data') or {}).get('plan') or ''
if not encoded:
    raise SystemExit('authoritative worker plan payload is empty')
raw = base64.b64decode(encoded, validate=True)
sha = hashlib.sha256(raw).hexdigest()
expected_uid = os.environ['EXPECTED_UID']
expected_sha = os.environ['EXPECTED_SHA256']
summary = {
    'targetMachine': 'fleet-local/custom-81a2c5e94b13',
    'planSecretUid': uid,
    'expectedPlanSecretUid': expected_uid,
    'planSecretUidMatched': uid == expected_uid,
    'currentPlanSha256': sha,
    'expectedPlanSha256': expected_sha,
    'planSha256Matched': sha == expected_sha,
    'workerRoleAnnotation': annotations.get('rke.cattle.io/worker-role', ''),
    'workerRoleLabel': labels.get('rke.cattle.io/worker-role', ''),
    'planPayloadPublished': False,
    'readOnly': True,
}
print('LAYERSENTRY_WORKER_PLAN_STATE=' + json.dumps(summary, sort_keys=True))
PY
'@
    $planScript = $planScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $planScript = $planScript.Replace('{{EXPECTED_UID}}', [string]$request.expectedPlanSecretUid)
    $planScript = $planScript.Replace('{{EXPECTED_SHA256}}', [string]$request.expectedPlanSha256)
    $planCall = Invoke-ReadOnlyNodeScript -Address '10.10.10.11' -Label 'sen1-authoritative-worker-plan-readonly' -Script $planScript
    if ($planCall.ExitCode -ne 0) {
        throw "Read-only authoritative worker-plan verification through sen1 failed with SSH exit code $($planCall.ExitCode)."
    }
    $planMatch = [regex]::Match($planCall.RawStdout, '(?m)^LAYERSENTRY_WORKER_PLAN_STATE=(\{.*\})\s*$')
    if (-not $planMatch.Success) {
        throw 'The sanitized worker-plan marker is missing.'
    }
    $planState = $planMatch.Groups[1].Value | ConvertFrom-Json
    if (-not [bool]$planState.planSecretUidMatched -or -not [bool]$planState.planSha256Matched) {
        throw 'The exact authoritative worker-plan UID or SHA-256 no longer matches the verified source.'
    }

    if ([string]$sen1State.harvesterInstallMode -cne 'create') {
        throw "sen1 must retain Harvester create mode; observed $($sen1State.harvesterInstallMode)."
    }
    if ([string]$sen1State.harvesterInstallVip -cne [string]$request.expectedClusterVip) {
        throw "sen1 persisted cluster VIP mismatch: expected $($request.expectedClusterVip), observed $($sen1State.harvesterInstallVip)."
    }
    $authoritativeJoinUrl = 'https://' + [string]$sen1State.harvesterInstallVip + ':443'
    if ($authoritativeJoinUrl -cne [string]$request.expectedJoinServerUrl) {
        throw "Derived Harvester join URL mismatch: expected $($request.expectedJoinServerUrl), derived $authoritativeJoinUrl."
    }
    foreach ($workerState in @($sen2State, $sen3State)) {
        if ([string]$workerState.harvesterInstallMode -cne 'join') {
            throw "$($workerState.hostname) must retain Harvester join mode; observed $($workerState.harvesterInstallMode)."
        }
        if ([string]$workerState.rancherdRole -cne 'agent') {
            throw "$($workerState.hostname) must retain rancherd agent role; observed $($workerState.rancherdRole)."
        }
    }

    $sen2RancherdMatches = [string]$sen2State.rancherdServer -ceq $authoritativeJoinUrl
    $sen2HarvesterMatches = [string]$sen2State.harvesterServerUrl -ceq $authoritativeJoinUrl
    $sen3RancherdMatches = [string]$sen3State.rancherdServer -ceq $authoritativeJoinUrl
    $sen3HarvesterMatches = [string]$sen3State.harvesterServerUrl -ceq $authoritativeJoinUrl
    if ($sen2RancherdMatches -and $sen2HarvesterMatches -and $sen3RancherdMatches -and $sen3HarvesterMatches) {
        $classification = 'both-workers-match-cluster-vip-join-endpoint'
    }
    elseif (-not ($sen2RancherdMatches -and $sen2HarvesterMatches) -and $sen3RancherdMatches -and $sen3HarvesterMatches) {
        $classification = 'sen2-persisted-join-endpoint-drift'
    }
    elseif ($sen2RancherdMatches -and $sen2HarvesterMatches -and -not ($sen3RancherdMatches -and $sen3HarvesterMatches)) {
        $classification = 'sen3-persisted-join-endpoint-drift'
    }
    else {
        $classification = 'mixed-or-multiple-persisted-join-endpoint-drift'
    }

    $managementVipTcp443 = Test-TcpPort -Address ([string]$request.expectedClusterVip) -Port 443 -TimeoutMilliseconds 3000
    $passed = $true
    Write-Host "LAYERSENTRY HARVESTER AUTHORITATIVE JOIN ENDPOINT: $authoritativeJoinUrl"
    Write-Host "LAYERSENTRY HARVESTER JOIN ENDPOINT CLASSIFICATION: $classification"
}
catch {
    $failure = [string]$_.Exception.Message
    throw
}
finally {
    $finishedAt = (Get-Date).ToUniversalTime()
    $sen2MatchesAuthoritative = (
        $null -ne $sen2State -and
        -not [string]::IsNullOrWhiteSpace($authoritativeJoinUrl) -and
        [string]$sen2State.rancherdServer -ceq $authoritativeJoinUrl -and
        [string]$sen2State.harvesterServerUrl -ceq $authoritativeJoinUrl
    )
    $sen3MatchesAuthoritative = (
        $null -ne $sen3State -and
        -not [string]::IsNullOrWhiteSpace($authoritativeJoinUrl) -and
        [string]$sen3State.rancherdServer -ceq $authoritativeJoinUrl -and
        [string]$sen3State.harvesterServerUrl -ceq $authoritativeJoinUrl
    )
    [ordered]@{
        schemaVersion = '1.0'
        requestId = [string]$request.requestId
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        verificationMode = 'read-only-harvester-join-endpoint-from-sen1-cluster-vip'
        joinEndpointPolicy = [string]$request.joinEndpointPolicy
        expectedClusterVip = [string]$request.expectedClusterVip
        managementApiUrl = [string]$request.managementApiUrl
        authoritativeJoinServerUrl = $authoritativeJoinUrl
        sen1 = $sen1State
        sen2 = $sen2State
        sen3 = $sen3State
        authoritativeWorkerPlan = $planState
        sen2MatchesAuthoritativeJoinEndpoint = $sen2MatchesAuthoritative
        sen3MatchesAuthoritativeJoinEndpoint = $sen3MatchesAuthoritative
        endpointClassification = $classification
        managementVipTcp443Reachable = $managementVipTcp443
        verificationPassed = $passed
        authoritativeSourceModified = $false
        nodeConfigurationModified = $false
        servicesModified = $false
        nodeRebooted = $false
        planPayloadPublished = $false
        credentialValuesWrittenToEvidence = $false
        kubeconfigWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        failure = $failure
    } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry Harvester join-endpoint verification

- Verification mode: **read-only**
- sen1 persisted cluster VIP: **$(if ($null -ne $sen1State) { $sen1State.harvesterInstallVip } else { 'not-observed' })**
- Authoritative JOIN endpoint derived from cluster VIP: **$(if ([string]::IsNullOrWhiteSpace($authoritativeJoinUrl)) { 'not-established' } else { $authoritativeJoinUrl })**
- sen2 rancherd server: **$(if ($null -ne $sen2State) { $sen2State.rancherdServer } else { 'not-observed' })**
- sen2 Harvester server_url: **$(if ($null -ne $sen2State) { $sen2State.harvesterServerUrl } else { 'not-observed' })**
- sen3 rancherd server: **$(if ($null -ne $sen3State) { $sen3State.rancherdServer } else { 'not-observed' })**
- sen3 Harvester server_url: **$(if ($null -ne $sen3State) { $sen3State.harvesterServerUrl } else { 'not-observed' })**
- Endpoint classification: **$(if ([string]::IsNullOrWhiteSpace($classification)) { 'not-established' } else { $classification })**
- Exact authoritative worker-plan UID/SHA retained: **$(if ($null -ne $planState) { [bool]$planState.planSecretUidMatched -and [bool]$planState.planSha256Matched } else { $false })**
- Management/API VIP TCP/443 reachable: **$managementVipTcp443**
- Authoritative source modified: **false**
- Node configuration modified: **false**
- Services modified: **false**
- Node rebooted: **false**
- Verification passed: **$passed**
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
