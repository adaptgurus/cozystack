[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-join-node-controller-diagnostic')
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
        [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            $fullControl,
            $inheritance,
            $propagation,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Diagnostic request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'READ_ONLY_JOIN_NODE_CONTROLLER_DIAGNOSTIC') {
    throw "Unsupported diagnostic operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([bool]$request.writeCredentialValuesToEvidence) {
    throw 'Credential values must not be written to evidence.'
}
if ([bool]$request.modifyNodeState) {
    throw 'This diagnostic request must be read-only.'
}
[string[]]$addresses = @($request.addresses | ForEach-Object { [string]$_ })
if ($addresses.Count -ne 2 -or $addresses -notcontains '10.10.10.12' -or $addresses -notcontains '10.10.10.13') {
    throw 'Diagnostic addresses must be exactly 10.10.10.12 and 10.10.10.13.'
}

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Protected credential file is missing: $CredentialPath"
}
$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nodePassword = [string]$credentials.nodePassword
if ([string]::IsNullOrWhiteSpace($nodePassword)) {
    throw 'Protected node password is missing.'
}
[string[]]$sensitiveValues = @(
    [string]$credentials.nodePassword,
    [string]$credentials.clusterToken,
    [string]$credentials.adminPassword
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-controller-diagnostic-secure-' + [Guid]::NewGuid().ToString('N'))
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
$nodePasswordB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))

$remoteTemplate = @'
set +e
umask 077
work=$(mktemp -d /tmp/layersentry-controller-diagnostic.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
redact() {
  sed -E \
    -e 's/(K10[a-zA-Z0-9]{20,}::server:[a-zA-Z0-9]{20,})/[REDACTED-RKE2-TOKEN]/g' \
    -e 's/((token|password|credential|rke2_token)[[:space:]]*[:=])[[:space:]]*[^[:space:]]+/\1 [REDACTED]/Ig'
}
echo '===identity==='
hostname
date -u
uname -a
echo '===configuration-summary==='
yq_path=$(command -v yq 2>/dev/null || true)
if [ -n "$yq_path" ]; then
  role=$(sudo -n "$yq_path" e -r '.role // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
  server_url=$(sudo -n "$yq_path" e -r '.server // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
  node_name=$(sudo -n "$yq_path" e -r '.nodeName // ""' /etc/rancher/rancherd/config.yaml 2>/dev/null || true)
  install_mode=$(sudo -n "$yq_path" e -r '.install.mode // ""' /oem/harvester.config 2>/dev/null || true)
  echo "rancherdRole=${role}"
  echo "rancherdServer=${server_url}"
  echo "rancherdNodeName=${node_name}"
  echo "harvesterInstallMode=${install_mode}"
fi
echo '===unit-states==='
for svc in rancherd rancher-system-agent rke2-server rke2-agent; do
  echo "---${svc}---"
  sudo -n systemctl is-enabled "$svc" 2>&1 || true
  sudo -n systemctl is-active "$svc" 2>&1 || true
  sudo -n systemctl show "$svc" \
    --property=LoadState,UnitFileState,ActiveState,SubState,Result,ExecMainStatus,NRestarts,FragmentPath,DropInPaths \
    --no-pager 2>&1 || true
done
echo '===unit-links-and-metadata==='
sudo -n find /etc/systemd/system /usr/lib/systemd/system \
  -maxdepth 3 \
  \( -name 'rke2-server.service' -o -name 'rke2-agent.service' -o -name 'rancher-system-agent.service' -o -name 'rancherd.service' \) \
  -printf '%M %u:%g %s %TY-%Tm-%TdT%TH:%TM:%TS %p -> %l\n' 2>/dev/null | sort || true
sudo -n ls -la --full-time /etc/systemd/system/multi-user.target.wants 2>/dev/null | grep -E 'rke2|rancher' || true
echo '===unit-definitions==='
for svc in rancher-system-agent rke2-server rke2-agent; do
  echo "---${svc}---"
  sudo -n systemctl cat "$svc" 2>&1 | redact || true
done
echo '===controller-files==='
for root in /var/lib/rancher/agent /var/lib/rancher/rke2/system-agent-installer /etc/rancher; do
  echo "---root:${root}---"
  sudo -n find "$root" -maxdepth 6 -type f \
    -printf '%M %u:%g %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' 2>/dev/null | sort || true
done
echo '===controller-plan-selectors==='
sudo -n grep -R -n -I -E \
  'INSTALL_RKE2_TYPE|rke2-server|rke2-agent|systemctl[[:space:]]+(enable|disable|start|stop|restart)|role[[:space:]]*[:=]' \
  /var/lib/rancher/agent /var/lib/rancher/rke2/system-agent-installer /etc/rancher \
  2>/dev/null | head -n 1000 | redact || true
echo '===recent-controller-journal==='
sudo -n journalctl \
  -u rancherd \
  -u rancher-system-agent \
  -u rke2-server \
  -u rke2-agent \
  --since '-25 minutes' \
  -n 1400 \
  --no-pager 2>&1 | redact || true
echo '===timers-and-path-units==='
sudo -n systemctl list-timers --all --no-pager 2>&1 || true
sudo -n systemctl list-units --type=path --all --no-pager 2>&1 || true
echo '===processes-and-listeners==='
ps -ef | grep -E '[r]ancherd|[r]ancher-system-agent|[r]ke2|[k]ubelet|[c]ontainerd' || true
ss -lntp 2>/dev/null | grep -E ':(22|6443|9345|10250)[[:space:]]' || true
echo '===diagnostic-complete==='
'@
$remoteScript = $remoteTemplate.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
$summary = @()

try {
    foreach ($address in $addresses) {
        $safeName = $address.Replace('.', '-')
        $scriptPath = Join-Path $temporaryDirectory ($safeName + '.sh')
        $stdoutPath = Join-Path $temporaryDirectory ($safeName + '.stdout.raw')
        $stderrPath = Join-Path $temporaryDirectory ($safeName + '.stderr.raw')
        Write-Utf8NoBom -Path $scriptPath -Value ($remoteScript -replace "`r`n", "`n")
        $arguments = @(
            '-T',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=NUL',
            '-o', 'LogLevel=ERROR',
            '-o', 'PreferredAuthentications=password,keyboard-interactive',
            '-o', 'PubkeyAuthentication=no',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'ConnectTimeout=15',
            "rancher@$address",
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
        $combined = Protect-Text -Text ($stdout + "`n===ssh-stderr===`n" + $stderr)
        Write-Utf8NoBom -Path (Join-Path $OutputDirectory ($safeName + '.txt')) -Value $combined
        $serverEnabled = [regex]::Match($stdout, '(?ms)---rke2-server---\s*\r?\n([^\r\n]+)').Groups[1].Value.Trim()
        $agentEnabled = [regex]::Match($stdout, '(?ms)---rke2-agent---\s*\r?\n([^\r\n]+)').Groups[1].Value.Trim()
        $summary += [ordered]@{
            address = $address
            sshExitCode = [int]$process.ExitCode
            rke2ServerUnitFileState = $serverEnabled
            rke2AgentUnitFileState = $agentEnabled
            kubelet10250 = ($stdout -match ':10250')
            diagnosticCompleted = ($stdout -match '===diagnostic-complete===')
        }
    }
    $summary | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
    $summary | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}
finally {
    [Environment]::SetEnvironmentVariable('SSH_ASKPASS', $oldAskPass)
    [Environment]::SetEnvironmentVariable('SSH_ASKPASS_REQUIRE', $oldAskPassRequire)
    [Environment]::SetEnvironmentVariable('DISPLAY', $oldDisplay)
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $nodePassword = $null
    $credentials = $null
}
