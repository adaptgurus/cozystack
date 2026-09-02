[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$NodeAddress = '10.10.10.11',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-admin-initialization')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

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
            $identity, $fullControl, $inheritance, $propagation, $allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Protect-CredentialFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM',
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        $allow
    )
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators',
        [System.Security.AccessControl.FileSystemRights]::Read,
        $inheritance,
        $propagation,
        $allow
    )
    [void]$acl.AddAccessRule($systemRule)
    [void]$acl.AddAccessRule($adminRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$resultPath = Join-Path $OutputDirectory 'admin-initialization.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$tempDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-admin-reset-v3-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $tempDirectory

$startedAt = (Get-Date).ToUniversalTime()
$resetSucceeded = $false
$remoteLoginSucceeded = $false
$remoteUsername = $null
$mustChangePassword = $null
$bootstrapConfigMapPresent = $false
$remoteLoginStatus = $null
$failure = $null
$nodePassword = $null
$adminPassword = $null
$credentials = $null
$oldAskPass = $env:SSH_ASKPASS
$oldAskPassRequire = $env:SSH_ASKPASS_REQUIRE
$oldDisplay = $env:DISPLAY

try {
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
    $adminPassword = Get-PropertyValue -Object $credentials -Names @('adminPassword', 'AdminPassword')
    if ([string]::IsNullOrWhiteSpace($nodePassword) -or $nodePassword.Length -lt 16) {
        throw 'The protected credential file has no valid node password.'
    }
    if ([string]::IsNullOrWhiteSpace($adminPassword) -or $adminPassword.Length -lt 16) {
        throw 'The protected credential file has no valid administrator password.'
    }

    $ssh = Get-Command -Name 'ssh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ssh) {
        throw 'Windows OpenSSH client ssh.exe is not installed.'
    }

    $nodePasswordPath = Join-Path $tempDirectory 'node-password.txt'
    $askPassPath = Join-Path $tempDirectory 'askpass.cmd'
    $remoteScriptPath = Join-Path $tempDirectory 'remote-reset.sh'
    $sshStdoutPath = Join-Path $tempDirectory 'ssh.stdout.txt'
    $sshStderrPath = Join-Path $tempDirectory 'ssh.stderr.txt'
    Write-Utf8NoBom -Path $nodePasswordPath -Value ($nodePassword + "`r`n")
    Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$nodePasswordPath`"`r`n")

    $adminBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($adminPassword))
    $nodeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))
    $remoteScript = @"
set -eu
umask 077
admin_file=`$(mktemp /tmp/layersentry-admin.XXXXXX)
node_file=`$(mktemp /tmp/layersentry-node.XXXXXX)
reset_log=`$(mktemp /tmp/layersentry-reset.XXXXXX)
login_body=`$(mktemp /tmp/layersentry-login-body.XXXXXX)
login_response=`$(mktemp /tmp/layersentry-login-response.XXXXXX)
cleanup() {
  rm -f "`$admin_file" "`$node_file" "`$reset_log" "`$login_body" "`$login_response"
}
trap cleanup EXIT HUP INT TERM
printf '%s' '$adminBase64' | base64 -d > "`$admin_file"
printf '\n' >> "`$admin_file"
printf '%s' '$nodeBase64' | base64 -d > "`$node_file"
printf '\n' >> "`$node_file"
chmod 0600 "`$admin_file" "`$node_file"

run_root() {
  if sudo -n true >/dev/null 2>&1; then
    sudo -n "`$@"
  else
    sudo -S -p '' "`$@" < "`$node_file"
  fi
}

rancherd_path=`$(command -v rancherd 2>/dev/null || true)
if [ -z "`$rancherd_path" ] && [ -x /usr/bin/rancherd ]; then
  rancherd_path=/usr/bin/rancherd
fi
kubectl_path=`$(command -v kubectl 2>/dev/null || true)
if [ -z "`$kubectl_path" ] && [ -x /var/lib/rancher/rke2/bin/kubectl ]; then
  kubectl_path=/var/lib/rancher/rke2/bin/kubectl
fi
if [ -z "`$rancherd_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:rancherd-not-found'
  exit 21
fi
if [ -z "`$kubectl_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:kubectl-not-found'
  exit 22
fi

attempt=1
reset_ok=false
while [ "`$attempt" -le 12 ]; do
  if run_root "`$rancherd_path" reset-admin \
      --kubeconfig /etc/rancher/rke2/rke2.yaml \
      --password-file "`$admin_file" >"`$reset_log" 2>&1; then
    reset_ok=true
    break
  fi
  attempt=`$((attempt + 1))
  sleep 10
done
if [ "`$reset_ok" != true ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:cluster-not-ready-or-sudo-failed'
  exit 23
fi

admin_records=`$(run_root "`$kubectl_path" \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get users.management.cattle.io \
  -l authz.management.cattle.io/bootstrapping=admin-user \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.username}{"|"}{.mustChangePassword}{"\n"}{end}')
admin_count=`$(printf '%s\n' "`$admin_records" | sed '/^[[:space:]]*`$/d' | wc -l | tr -d ' ')
if [ "`$admin_count" != 1 ]; then
  printf 'LAYERSENTRY_ADMIN_OBJECT_COUNT=%s\n' "`$admin_count"
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:unexpected-admin-object-count'
  exit 24
fi
admin_record=`$(printf '%s\n' "`$admin_records" | head -n 1)
admin_object=`$(printf '%s' "`$admin_record" | cut -d '|' -f 1)
admin_username=`$(printf '%s' "`$admin_record" | cut -d '|' -f 2)
must_change=`$(printf '%s' "`$admin_record" | cut -d '|' -f 3)
case "`$admin_username" in
  ''|*[!A-Za-z0-9_.@-]*)
    printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:unsafe-or-empty-admin-username'
    exit 25
    ;;
esac
if run_root "`$kubectl_path" --kubeconfig /etc/rancher/rke2/rke2.yaml \
    -n cattle-system get configmap admincreated >/dev/null 2>&1; then
  bootstrap_present=true
else
  bootstrap_present=false
fi

admin_password=`$(cat "`$admin_file")
printf '{"username":"%s","password":"%s","responseType":"token"}' \
  "`$admin_username" "`$admin_password" > "`$login_body"
unset admin_password
login_attempt=1
login_status=000
token_present=false
while [ "`$login_attempt" -le 24 ]; do
  login_status=`$(curl -ksS --http1.1 \
    --connect-timeout 10 --max-time 30 \
    --request POST \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@`$login_body" \
    --output "`$login_response" \
    --write-out '%{http_code}' \
    '${ClusterUrl}/v3-public/localProviders/local?action=login' 2>/dev/null || printf '000')
  if { [ "`$login_status" = 200 ] || [ "`$login_status" = 201 ]; } \
      && grep -q '"token"' "`$login_response"; then
    token_present=true
    break
  fi
  login_attempt=`$((login_attempt + 1))
  sleep 5
done

printf 'LAYERSENTRY_ADMIN_OBJECT_COUNT=%s\n' "`$admin_count"
printf 'LAYERSENTRY_ADMIN_OBJECT=%s\n' "`$admin_object"
printf 'LAYERSENTRY_ADMIN_USERNAME=%s\n' "`$admin_username"
printf 'LAYERSENTRY_ADMIN_MUST_CHANGE=%s\n' "`$must_change"
printf 'LAYERSENTRY_BOOTSTRAP_CONFIGMAP=%s\n' "`$bootstrap_present"
printf 'LAYERSENTRY_REMOTE_LOGIN_HTTP=%s\n' "`$login_status"
printf 'LAYERSENTRY_REMOTE_LOGIN_TOKEN=%s\n' "`$token_present"
if [ "`$token_present" != true ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:remote-login-failed-after-reset'
  exit 26
fi
printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_OK'
"@
    $remoteScript = ($remoteScript -replace "`r`n", "`n").TrimStart([char]0xFEFF)
    Write-Utf8NoBom -Path $remoteScriptPath -Value $remoteScript

    $env:SSH_ASKPASS = $askPassPath
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:DISPLAY = 'LayerSentry'
    $sshArguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'ConnectTimeout=20',
        "rancher@$NodeAddress",
        'bash', '-s'
    )
    $sshProcess = Start-Process `
        -FilePath $ssh.Source `
        -ArgumentList $sshArguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardInput $remoteScriptPath `
        -RedirectStandardOutput $sshStdoutPath `
        -RedirectStandardError $sshStderrPath

    $sshOutput = [string](Get-Content -LiteralPath $sshStdoutPath -Raw -ErrorAction SilentlyContinue)
    $sshError = [string](Get-Content -LiteralPath $sshStderrPath -Raw -ErrorAction SilentlyContinue)
    $safeOutput = $sshOutput.Replace($nodePassword, '[REDACTED]').Replace($adminPassword, '[REDACTED]')
    $safeError = $sshError.Replace($nodePassword, '[REDACTED]').Replace($adminPassword, '[REDACTED]')

    $usernameMatch = [regex]::Match($safeOutput, '(?m)^LAYERSENTRY_ADMIN_USERNAME=([^\r\n]+)')
    if ($usernameMatch.Success) {
        $remoteUsername = $usernameMatch.Groups[1].Value.Trim()
    }
    $mustChangeMatch = [regex]::Match($safeOutput, '(?m)^LAYERSENTRY_ADMIN_MUST_CHANGE=([^\r\n]+)')
    if ($mustChangeMatch.Success) {
        $mustChangePassword = $mustChangeMatch.Groups[1].Value.Trim()
    }
    $bootstrapMatch = [regex]::Match($safeOutput, '(?m)^LAYERSENTRY_BOOTSTRAP_CONFIGMAP=([^\r\n]+)')
    if ($bootstrapMatch.Success) {
        $bootstrapConfigMapPresent = ($bootstrapMatch.Groups[1].Value.Trim() -eq 'true')
    }
    $loginStatusMatch = [regex]::Match($safeOutput, '(?m)^LAYERSENTRY_REMOTE_LOGIN_HTTP=([0-9]{3})')
    if ($loginStatusMatch.Success) {
        $remoteLoginStatus = [int]$loginStatusMatch.Groups[1].Value
    }

    $resetSucceeded = ($safeOutput -match 'LAYERSENTRY_ADMIN_RESET_OK')
    $remoteLoginSucceeded = ($safeOutput -match 'LAYERSENTRY_REMOTE_LOGIN_TOKEN=true')
    if ($sshProcess.ExitCode -ne 0 -or -not $resetSucceeded -or -not $remoteLoginSucceeded) {
        $diagnosticLines = @(
            $safeOutput -split '[\r\n]+' |
                Where-Object { $_ -like 'LAYERSENTRY_*' }
        )
        $diagnostic = ($diagnosticLines -join ' | ')
        if ([string]::IsNullOrWhiteSpace($diagnostic)) {
            $diagnostic = ($safeError.Trim() -replace '[\r\n]+', ' | ')
        }
        if ($diagnostic.Length -gt 700) {
            $diagnostic = $diagnostic.Substring(0, 700)
        }
        throw "Administrator reset/verification failed over SSH with exit code $($sshProcess.ExitCode). $diagnostic"
    }

    $completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-ObjectProperty -Object $credentials -Name 'adminUsername' -Value $remoteUsername
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedAtUtc' -Value $completedAt
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedOnNode' -Value $NodeAddress
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordRemoteApiValidated' -Value $true
    $temporaryCredentialPath = "$CredentialPath.tmp"
    Write-Utf8NoBom -Path $temporaryCredentialPath -Value ($credentials | ConvertTo-Json -Depth 8)
    Move-Item -LiteralPath $temporaryCredentialPath -Destination $CredentialPath -Force
    Protect-CredentialFile -Path $CredentialPath
}
catch {
    $failure = $_.Exception.Message
    throw
}
finally {
    $env:SSH_ASKPASS = $oldAskPass
    $env:SSH_ASKPASS_REQUIRE = $oldAskPassRequire
    $env:DISPLAY = $oldDisplay

    $finishedAt = (Get-Date).ToUniversalTime()
    $evidence = [ordered]@{
        schemaVersion = '3.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        clusterUrl = $ClusterUrl
        nodeAddress = $NodeAddress
        administratorResetSucceeded = $resetSucceeded
        remoteAdministratorLoginSucceeded = $remoteLoginSucceeded
        administratorUsername = $remoteUsername
        mustChangePassword = $mustChangePassword
        bootstrapAdminConfigMapPresent = $bootstrapConfigMapPresent
        remoteLoginHttpStatus = $remoteLoginStatus
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
        failure = $failure
    }
    $evidence | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry administrator initialization

- Cluster URL: $ClusterUrl
- Reset node: $NodeAddress
- Administrator reset succeeded: $resetSucceeded
- Remote administrator login succeeded: $remoteLoginSucceeded
- Administrator username: $remoteUsername
- Must change password: $mustChangePassword
- Bootstrap admin ConfigMap present: $bootstrapConfigMapPresent
- Remote login HTTP status: $remoteLoginStatus
- EULA automatically accepted: **false**
- Credential values written to evidence: **false**
- Production release approved: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $nodePassword = $null
    $adminPassword = $null
    $credentials = $null
}
