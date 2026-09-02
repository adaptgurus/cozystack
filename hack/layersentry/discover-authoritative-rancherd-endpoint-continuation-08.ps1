[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-rancherd-endpoint-discovery-08')
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
    throw "Endpoint-discovery request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -cne 'DISCOVER_AUTHORITATIVE_RANCHERD_ENDPOINT_READ_ONLY') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -cne 'USER_GRANTED_READ_ONLY_ENDPOINT_DISCOVERY') {
    throw 'The request is missing the read-only authorization marker.'
}
if ([string]$request.targetNode -cne 'sen2' -or [string]$request.targetAddress -cne '10.10.10.12') {
    throw 'Endpoint discovery is restricted to sen2 at 10.10.10.12.'
}
if ([string]$request.peerNode -cne 'sen3' -or [string]$request.peerAddress -cne '10.10.10.13') {
    throw 'Endpoint discovery requires sen3 at 10.10.10.13 as the comparison peer.'
}
if ([string]$request.primaryNode -cne '10.10.10.11') {
    throw 'The authoritative plan must be queried through sen1 at 10.10.10.11.'
}
if ([string]$request.managementApiUrl -cne 'https://10.10.10.10') {
    throw 'The management/API URL must be exactly https://10.10.10.10.'
}
if ([string]$request.expectedTargetMachineName -cne 'fleet-local/custom-81a2c5e94b13') {
    throw 'The request is not bound to the authoritative sen2 Rancher machine.'
}
if ([string]$request.expectedPlanSecretUid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
    throw 'The expected plan Secret UID is invalid.'
}
if ([string]$request.previouslyVerifiedPlanSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'The previously verified plan SHA-256 is invalid.'
}
[string[]]$candidateUrls = @($request.candidateRancherdServerUrls | ForEach-Object { [string]$_ })
[string[]]$requiredCandidates = @(
    'https://10.10.10.10:443',
    'https://10.10.10.11:443'
)
if ($candidateUrls.Count -ne 2 -or @(Compare-Object ($candidateUrls | Sort-Object) ($requiredCandidates | Sort-Object)).Count -ne 0) {
    throw 'The request must compare exactly the VIP and sen1 rancherd endpoint candidates.'
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
$resultPath = Join-Path $OutputDirectory 'endpoint-discovery-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-endpoint-discovery-secure-' + [Guid]::NewGuid().ToString('N'))
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
        EvidencePath = $evidencePath
    }
}

function ConvertFrom-RancherdConfigMarker {
    param(
        [Parameter(Mandatory = $true)][string]$RawStdout,
        [Parameter(Mandatory = $true)][string]$ExpectedHostname
    )

    $match = [regex]::Match(
        $RawStdout,
        '(?m)^LAYERSENTRY_RANCHERD_CONFIG\|([^|\r\n]*)\|([^|\r\n]*)\|([^|\r\n]*)\|([^|\r\n]*)\s*$'
    )
    if (-not $match.Success) {
        throw "The read-only rancherd marker for $ExpectedHostname is missing."
    }
    $observed = [ordered]@{
        hostname = $match.Groups[1].Value.Trim()
        role = $match.Groups[2].Value.Trim()
        server = $match.Groups[3].Value.Trim()
        installMode = $match.Groups[4].Value.Trim()
    }
    if ([string]$observed.hostname -cne $ExpectedHostname) {
        throw "SSH target identity mismatch: expected $ExpectedHostname, observed $($observed.hostname)."
    }
    return [pscustomobject]$observed
}

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$diagnosisEstablished = $false
$sen2Config = $null
$sen3Config = $null
$planEvidence = $null
$authoritativeRancherdServerUrl = $null
$classification = $null
$managementVipTcp443 = $false
$sen1Tcp443 = $false

try {
    foreach ($vmName in @('sen1', 'sen2', 'sen3')) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ([string]$vm.State -ne 'Running') {
            throw "$vmName must already be Running; current state is $($vm.State)."
        }
    }

    $configScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-rancherd-discovery.XXXXXX)
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
  echo 'LAYERSENTRY_ENDPOINT_DISCOVERY_ERROR:yq-not-found'
  exit 101
fi
hostname_value=$(hostname)
role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
printf 'LAYERSENTRY_RANCHERD_CONFIG|%s|%s|%s|%s\n' "$hostname_value" "$role" "$server_url" "$install_mode"
'@
    $configScript = $configScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)

    $sen2Call = Invoke-ReadOnlyNodeScript -Address '10.10.10.12' -Label 'sen2-rancherd-config-readonly' -Script $configScript
    if ($sen2Call.ExitCode -ne 0) {
        throw "Read-only sen2 rancherd configuration query failed with SSH exit code $($sen2Call.ExitCode)."
    }
    $sen2Config = ConvertFrom-RancherdConfigMarker -RawStdout $sen2Call.RawStdout -ExpectedHostname 'sen2'

    $sen3Call = Invoke-ReadOnlyNodeScript -Address '10.10.10.13' -Label 'sen3-rancherd-config-readonly' -Script $configScript
    if ($sen3Call.ExitCode -ne 0) {
        throw "Read-only sen3 rancherd configuration query failed with SSH exit code $($sen3Call.ExitCode)."
    }
    $sen3Config = ConvertFrom-RancherdConfigMarker -RawStdout $sen3Call.RawStdout -ExpectedHostname 'sen3'

    $candidateJsonB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($candidateUrls | ConvertTo-Json -Compress)))
    $managementUrlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$request.managementApiUrl))
    $planScript = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-authoritative-endpoint-discovery.XXXXXX)
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
  echo 'LAYERSENTRY_ENDPOINT_DISCOVERY_ERROR:kubectl-not-found'
  exit 102
fi
k() { sudo -n "$kubectl_path" --kubeconfig /etc/rancher/rke2/rke2.yaml "$@"; }
k -n fleet-local get secret custom-81a2c5e94b13-machine-plan -o json > "$work/plan-secret.json"
export CANDIDATE_JSON_B64='{{CANDIDATE_JSON_B64}}'
export MANAGEMENT_URL_B64='{{MANAGEMENT_URL_B64}}'
export PREVIOUSLY_VERIFIED_PLAN_SHA256='{{PREVIOUSLY_VERIFIED_PLAN_SHA256}}'
export EXPECTED_PLAN_SECRET_UID='{{EXPECTED_PLAN_SECRET_UID}}'
python3 - "$work/plan-secret.json" <<'PY'
import base64
import hashlib
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

secret = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
uid = (secret.get('metadata') or {}).get('uid')
expected_uid = os.environ['EXPECTED_PLAN_SECRET_UID']
if uid != expected_uid:
    raise SystemExit(f'plan Secret UID mismatch: expected {expected_uid!r}, observed {uid!r}')
encoded = (secret.get('data') or {}).get('plan') or ''
if not encoded:
    raise SystemExit('authoritative plan payload is empty')
raw_plan = base64.b64decode(encoded, validate=True)
plan_sha = hashlib.sha256(raw_plan).hexdigest()
previous_sha = os.environ['PREVIOUSLY_VERIFIED_PLAN_SHA256']
candidates = json.loads(base64.b64decode(os.environ['CANDIDATE_JSON_B64']).decode('utf-8'))
management_url = base64.b64decode(os.environ['MANAGEMENT_URL_B64']).decode('utf-8')
counts = {candidate: raw_plan.count(candidate.encode('utf-8')) for candidate in candidates}
text = raw_plan.decode('utf-8', errors='replace')
origins = set()
for match in re.finditer(r'https?://(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+)(?::[0-9]{1,5})?', text):
    origin = match.group(0)
    try:
        parsed = urlsplit(origin)
        host = parsed.hostname
        if host and ipaddress.ip_address(host) in ipaddress.ip_network('10.10.10.0/24'):
            origins.add(origin)
    except (ValueError, TypeError):
        pass
present = [candidate for candidate in candidates if counts[candidate] > 0]
authoritative = present[0] if len(present) == 1 else None
classification = (
    'single-candidate-in-authoritative-plan' if len(present) == 1 else
    'multiple-candidates-in-authoritative-plan' if len(present) > 1 else
    'no-requested-candidate-in-authoritative-plan'
)
summary = {
    'targetMachine': 'fleet-local/custom-81a2c5e94b13',
    'planSecretUid': uid,
    'currentPlanSha256': plan_sha,
    'previouslyVerifiedPlanSha256': previous_sha,
    'previouslyVerifiedPlanSha256Matched': plan_sha == previous_sha,
    'candidateOccurrences': counts,
    'authoritativeRancherdServerUrl': authoritative,
    'classification': classification,
    'managementApiUrl': management_url,
    'managementApiUrlOccurrences': raw_plan.count(management_url.encode('utf-8')),
    'labHttpOrigins': sorted(origins),
    'planPayloadPublished': False,
    'authoritativePlanReadOnly': True,
    'authoritativeSourceModified': False,
}
print('LAYERSENTRY_AUTHORITATIVE_ENDPOINT_DISCOVERY=' + json.dumps(summary, sort_keys=True))
PY
'@
    $planScript = $planScript.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
    $planScript = $planScript.Replace('{{CANDIDATE_JSON_B64}}', $candidateJsonB64)
    $planScript = $planScript.Replace('{{MANAGEMENT_URL_B64}}', $managementUrlB64)
    $planScript = $planScript.Replace('{{PREVIOUSLY_VERIFIED_PLAN_SHA256}}', [string]$request.previouslyVerifiedPlanSha256)
    $planScript = $planScript.Replace('{{EXPECTED_PLAN_SECRET_UID}}', [string]$request.expectedPlanSecretUid)

    $planCall = Invoke-ReadOnlyNodeScript -Address '10.10.10.11' -Label 'sen1-authoritative-plan-endpoint-discovery-readonly' -Script $planScript
    if ($planCall.ExitCode -ne 0) {
        $diagnostic = (Protect-Text -Text (($planCall.RawStdout + "`n" + $planCall.RawStderr).Trim() -replace '[\r\n]+', ' | '))
        if ($diagnostic.Length -gt 600) { $diagnostic = $diagnostic.Substring(0, 600) }
        throw "Read-only authoritative endpoint discovery through sen1 failed with SSH exit code $($planCall.ExitCode). $diagnostic"
    }
    $planMatch = [regex]::Match($planCall.RawStdout, '(?m)^LAYERSENTRY_AUTHORITATIVE_ENDPOINT_DISCOVERY=(\{.*\})\s*$')
    if (-not $planMatch.Success) {
        throw 'The sanitized authoritative endpoint-discovery marker is missing.'
    }
    $planEvidence = $planMatch.Groups[1].Value | ConvertFrom-Json
    $authoritativeRancherdServerUrl = [string]$planEvidence.authoritativeRancherdServerUrl
    if ([string]::IsNullOrWhiteSpace($authoritativeRancherdServerUrl)) {
        throw "The authoritative endpoint remained ambiguous: $($planEvidence.classification)."
    }

    $sen2Matches = [string]$sen2Config.server -ceq $authoritativeRancherdServerUrl
    $sen3Matches = [string]$sen3Config.server -ceq $authoritativeRancherdServerUrl
    if ($sen2Matches -and $sen3Matches) {
        $classification = 'both-worker-configs-match-authoritative-plan'
    }
    elseif (-not $sen2Matches -and $sen3Matches) {
        $classification = 'sen2-local-rancherd-endpoint-drift'
    }
    elseif ($sen2Matches -and -not $sen3Matches) {
        $classification = 'sen3-local-rancherd-endpoint-drift'
    }
    else {
        $classification = 'both-worker-configs-differ-from-authoritative-plan'
    }

    $managementVipTcp443 = Test-TcpPort -Address '10.10.10.10' -Port 443 -TimeoutMilliseconds 3000
    $sen1Tcp443 = Test-TcpPort -Address '10.10.10.11' -Port 443 -TimeoutMilliseconds 3000
    $diagnosisEstablished = $true
    Write-Host "LAYERSENTRY AUTHORITATIVE RANCHERD ENDPOINT DISCOVERY: $authoritativeRancherdServerUrl"
    Write-Host "LAYERSENTRY ENDPOINT CLASSIFICATION: $classification"
}
catch {
    $failure = [string]$_.Exception.Message
    throw
}
finally {
    $finishedAt = (Get-Date).ToUniversalTime()
    $sen2MatchesAuthoritative = (
        $null -ne $sen2Config -and
        -not [string]::IsNullOrWhiteSpace($authoritativeRancherdServerUrl) -and
        [string]$sen2Config.server -ceq $authoritativeRancherdServerUrl
    )
    $sen3MatchesAuthoritative = (
        $null -ne $sen3Config -and
        -not [string]::IsNullOrWhiteSpace($authoritativeRancherdServerUrl) -and
        [string]$sen3Config.server -ceq $authoritativeRancherdServerUrl
    )
    [ordered]@{
        schemaVersion = '1.0'
        requestId = [string]$request.requestId
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        verificationMode = 'read-only-authoritative-rancherd-endpoint-discovery'
        sen2 = $sen2Config
        sen3 = $sen3Config
        authoritativePlan = $planEvidence
        authoritativeRancherdServerUrl = $authoritativeRancherdServerUrl
        managementApiUrl = [string]$request.managementApiUrl
        sen2MatchesAuthoritativePlan = $sen2MatchesAuthoritative
        sen3MatchesAuthoritativePlan = $sen3MatchesAuthoritative
        endpointClassification = $classification
        managementVipTcp443Reachable = $managementVipTcp443
        sen1Tcp443Reachable = $sen1Tcp443
        diagnosisEstablished = $diagnosisEstablished
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
# LayerSentry authoritative rancherd endpoint discovery

- Verification mode: **read-only**
- sen2 observed rancherd endpoint: **$(if ($null -ne $sen2Config) { $sen2Config.server } else { 'not-observed' })**
- sen3 observed rancherd endpoint: **$(if ($null -ne $sen3Config) { $sen3Config.server } else { 'not-observed' })**
- Authoritative plan endpoint: **$(if ([string]::IsNullOrWhiteSpace($authoritativeRancherdServerUrl)) { 'not-established' } else { $authoritativeRancherdServerUrl })**
- Endpoint classification: **$(if ([string]::IsNullOrWhiteSpace($classification)) { 'not-established' } else { $classification })**
- Previously verified plan SHA-256 retained: **$(if ($null -ne $planEvidence) { [bool]$planEvidence.previouslyVerifiedPlanSha256Matched } else { $false })**
- Management/API VIP TCP/443 reachable: **$managementVipTcp443**
- sen1 TCP/443 reachable: **$sen1Tcp443**
- Authoritative source modified: **false**
- Node configuration modified: **false**
- Services modified: **false**
- Node rebooted: **false**
- Plan payload published: **false**
- Diagnosis established: **$diagnosisEstablished**
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
