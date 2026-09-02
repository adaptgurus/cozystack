[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-agent-service-repair'),
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

if ($StableSamples -lt 1 -or $StableSamples -gt 120) {
    throw 'StableSamples must be between 1 and 120.'
}
if ($StableIntervalSeconds -lt 1 -or $StableIntervalSeconds -gt 300) {
    throw 'StableIntervalSeconds must be between 1 and 300.'
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
    throw 'This stability gate is restricted to sen2 at 10.10.10.12.'
}
if ([string]$request.expectedRancherdRole -ne 'agent') {
    throw 'The expected rancherd role must be agent.'
}
if ([string]$request.expectedRancherdServerUrl -ne 'https://10.10.10.11:443') {
    throw 'The expected rancherd server URL must be the verified sen1 endpoint.'
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
$historyPath = Join-Path $OutputDirectory 'service-stability-history.jsonl'
$resultPath = Join-Path $OutputDirectory 'repair-result.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-sen2-stability-secure-' + [Guid]::NewGuid().ToString('N'))
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

$checkTemplate = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-sen2-idempotent-stability.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
yq_path=$(command -v yq 2>/dev/null || true)
if [ -z "$yq_path" ]; then exit 81; fi
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
printf 'LAYERSENTRY_IDEMPOTENT_STABILITY_STATE:hostname=%s;role=%s;serverUrl=%s;installMode=%s;planType=%s;serverEnabled=%s;serverActive=%s;agentEnabled=%s;agentActive=%s;systemAgentActive=%s;kubelet10250=%s;agentProcess=%s;serverProcess=%s\n' \
  "$hostname_value" "$role" "$server_url" "$install_mode" "$plan_type" \
  "$server_enabled" "$server_active" "$agent_enabled" "$agent_active" \
  "$system_agent_active" "$kubelet_open" "$agent_process" "$server_process"
if [ "$hostname_value" != sen2 ]; then exit 82; fi
if [ "$role" != agent ]; then exit 83; fi
if [ "$server_url" != '{{EXPECTED_SERVER_URL}}' ]; then exit 84; fi
if [ "$install_mode" != join ]; then exit 85; fi
if [ -n "$plan_type" ] && [ "$plan_type" != agent ]; then exit 86; fi
if [ "$server_enabled" = enabled ]; then exit 87; fi
if [ "$server_active" = active ] || [ "$server_active" = activating ]; then exit 88; fi
if [ "$agent_enabled" != enabled ]; then exit 89; fi
if [ "$agent_active" != active ]; then exit 90; fi
if [ "$system_agent_active" != active ]; then exit 91; fi
if [ "$kubelet_open" != true ]; then exit 92; fi
if [ "$agent_process" != true ]; then exit 93; fi
if [ "$server_process" != false ]; then exit 94; fi
echo 'LAYERSENTRY_SEN2_IDEMPOTENT_STABILITY:PASS'
'@
$checkScript = $checkTemplate.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64).Replace(
    '{{EXPECTED_SERVER_URL}}',
    [string]$request.expectedRancherdServerUrl
)

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$stableCount = 0
$lastState = $null

try {
    foreach ($vmName in @('sen1', 'sen2', 'sen3')) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ([string]$vm.State -ne 'Running') {
            throw "$vmName must already be Running; current state is $($vm.State)."
        }
    }

    for ($sample = 1; $sample -le $StableSamples; $sample++) {
        $sshOpen = Test-TcpPort -Address '10.10.10.12' -Port 22 -TimeoutMilliseconds 2000
        $kubeletOpen = Test-TcpPort -Address '10.10.10.12' -Port 10250 -TimeoutMilliseconds 2000
        $remotePassed = $false
        $exitCode = $null
        if ($sshOpen) {
            $check = Invoke-Sen2Script `
                -Label ('sen2-idempotent-stability-{0:D2}' -f $sample) `
                -Script $checkScript `
                -ConnectTimeoutSeconds 10
            $exitCode = $check.ExitCode
            $stateMatch = [regex]::Match($check.RawStdout, '(?m)^LAYERSENTRY_IDEMPOTENT_STABILITY_STATE:(.+)$')
            $lastState = if ($stateMatch.Success) { $stateMatch.Groups[1].Value.Trim() } else { $null }
            $remotePassed = (
                $check.ExitCode -eq 0 -and
                $check.RawStdout -match '(?m)^LAYERSENTRY_SEN2_IDEMPOTENT_STABILITY:PASS\s*$'
            )
        }
        [ordered]@{
            phase = 'idempotent-stability'
            sample = $sample
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            ssh22 = $sshOpen
            kubelet10250 = $kubeletOpen
            sshExitCode = $exitCode
            state = $lastState
            remoteServiceCheck = $remotePassed
            passed = ($sshOpen -and $kubeletOpen -and $remotePassed)
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $historyPath -Encoding UTF8

        if (-not ($sshOpen -and $kubeletOpen -and $remotePassed)) {
            throw "sen2 failed idempotent stability sample $sample/$StableSamples. Last state: $lastState"
        }
        $stableCount = $sample
        Write-Host "sen2 idempotent agent stability sample $sample/$StableSamples passed."
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
        schemaVersion = '1.1'
        requestId = [string]$request.requestId
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        targetNode = 'sen2'
        targetAddress = '10.10.10.12'
        expectedRole = 'agent'
        expectedRancherdServerUrl = [string]$request.expectedRancherdServerUrl
        repairMode = 'already-correct-no-reboot'
        rebootIssued = $false
        rke2ServerDisabled = $passed
        rke2AgentStable = $passed
        consecutiveStableSamples = $stableCount
        stabilityIntervalSeconds = $StableIntervalSeconds
        lastState = $lastState
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        passed = $passed
        failure = $failure
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry sen2 idempotent agent stability

- Target: **sen2 / 10.10.10.12**
- Repair mode: **already-correct-no-reboot**
- Reboot issued by this gate: **false**
- rke2-server disabled and inactive: **$passed**
- rke2-agent sustained local stability: **$passed**
- Consecutive stability samples: **$stableCount / $StableSamples**
- RKE2 data deleted: **false**
- VM disk wiped or VM reinstalled: **false**
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
