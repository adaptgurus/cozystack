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
$tempDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-admin-reset-v4-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $tempDirectory

$startedAt = (Get-Date).ToUniversalTime()
$resetSucceeded = $false
$passwordSecretSynchronized = $false
$remoteLoginSucceeded = $false
$remoteUsername = $null
$mustChangePassword = $null
$bootstrapConfigMapPresent = $false
$passwordSecretExisted = $false
$passwordAlgorithmBefore = $null
$passwordAlgorithmAfterPatch = $null
$passwordAlgorithmAfterLogin = $null
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
    $remoteTemplate = @'
set -eu
umask 077
admin_file=$(mktemp /tmp/layersentry-admin.XXXXXX)
node_file=$(mktemp /tmp/layersentry-node.XXXXXX)
reset_log=$(mktemp /tmp/layersentry-reset.XXXXXX)
login_body=$(mktemp /tmp/layersentry-login-body.XXXXXX)
login_response=$(mktemp /tmp/layersentry-login-response.XXXXXX)
secret_patch=$(mktemp /tmp/layersentry-secret-patch.XXXXXX)
secret_manifest=$(mktemp /tmp/layersentry-secret-manifest.XXXXXX)
cleanup() {
  rm -f "$admin_file" "$node_file" "$reset_log" "$login_body" \
    "$login_response" "$secret_patch" "$secret_manifest"
}
trap cleanup EXIT HUP INT TERM
printf '%s' '__ADMIN_BASE64__' | base64 -d > "$admin_file"
printf '\n' >> "$admin_file"
printf '%s' '__NODE_BASE64__' | base64 -d > "$node_file"
printf '\n' >> "$node_file"
chmod 0600 "$admin_file" "$node_file"

run_root() {
  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    sudo -S -p '' "$@" < "$node_file"
  fi
}

rancherd_path=$(command -v rancherd 2>/dev/null || true)
if [ -z "$rancherd_path" ] && [ -x /usr/bin/rancherd ]; then
  rancherd_path=/usr/bin/rancherd
fi
kubectl_path=$(command -v kubectl 2>/dev/null || true)
if [ -z "$kubectl_path" ] && [ -x /var/lib/rancher/rke2/bin/kubectl ]; then
  kubectl_path=/var/lib/rancher/rke2/bin/kubectl
fi
if [ -z "$rancherd_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:rancherd-not-found'
  exit 21
fi
if [ -z "$kubectl_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:kubectl-not-found'
  exit 22
fi

attempt=1
reset_ok=false
while [ "$attempt" -le 12 ]; do
  if run_root "$rancherd_path" reset-admin \
      --kubeconfig /etc/rancher/rke2/rke2.yaml \
      --password-file "$admin_file" >"$reset_log" 2>&1; then
    reset_ok=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 10
done
if [ "$reset_ok" != true ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:reset-command-failed'
  exit 23
fi
printf '%s\n' 'LAYERSENTRY_RESET_COMMAND=true'

admin_records=$(run_root "$kubectl_path" \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get users.management.cattle.io \
  -l authz.management.cattle.io/bootstrapping=admin-user \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.uid}{"|"}{.username}{"|"}{.mustChangePassword}{"\n"}{end}')
admin_count=$(printf '%s\n' "$admin_records" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "$admin_count" != 1 ]; then
  printf 'LAYERSENTRY_ADMIN_OBJECT_COUNT=%s\n' "$admin_count"
  printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:unexpected-admin-object-count'
  exit 24
fi
admin_record=$(printf '%s\n' "$admin_records" | head -n 1)
admin_object=$(printf '%s' "$admin_record" | cut -d '|' -f 1)
admin_uid=$(printf '%s' "$admin_record" | cut -d '|' -f 2)
admin_username=$(printf '%s' "$admin_record" | cut -d '|' -f 3)
must_change=$(printf '%s' "$admin_record" | cut -d '|' -f 4)
case "$admin_object" in
  ''|*[!A-Za-z0-9_.-]*)
    printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:unsafe-admin-object-name'
    exit 25
    ;;
esac
case "$admin_username" in
  ''|*[!A-Za-z0-9_.@-]*)
    printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:unsafe-admin-username'
    exit 26
    ;;
esac
case "$admin_uid" in
  ''|*[!A-Za-z0-9-]*)
    printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:unsafe-admin-uid'
    exit 27
    ;;
esac

user_hash=$(run_root "$kubectl_path" \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get users.management.cattle.io "$admin_object" \
  -o jsonpath='{.password}')
case "$user_hash" in
  '$2a$'*|'$2b$'*|'$2y$'*) ;;
  *)
    printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:user-password-is-not-bcrypt'
    exit 28
    ;;
esac
password_b64=$(printf '%s' "$user_hash" | base64 | tr -d '\r\n')

password_namespace=cattle-local-user-passwords
secret_exists=false
algorithm_before=missing
if run_root "$kubectl_path" \
    --kubeconfig /etc/rancher/rke2/rke2.yaml \
    -n "$password_namespace" get secret "$admin_object" >/dev/null 2>&1; then
  secret_exists=true
  algorithm_before=$(run_root "$kubectl_path" \
    --kubeconfig /etc/rancher/rke2/rke2.yaml \
    -n "$password_namespace" get secret "$admin_object" \
    -o jsonpath='{.metadata.annotations.cattle\.io/password-hash}')
  [ -n "$algorithm_before" ] || algorithm_before=unannotated

  cat > "$secret_patch" <<EOF_PATCH
{"metadata":{"annotations":{"cattle.io/password-hash":"bcrypt"}},"data":{"password":"$password_b64","salt":null}}
EOF_PATCH
  chmod 0600 "$secret_patch"
  run_root "$kubectl_path" \
    --kubeconfig /etc/rancher/rke2/rke2.yaml \
    -n "$password_namespace" patch secret "$admin_object" \
    --type=merge --patch-file "$secret_patch" >/dev/null
else
  cat > "$secret_manifest" <<EOF_SECRET
apiVersion: v1
kind: Secret
metadata:
  name: $admin_object
  namespace: $password_namespace
  annotations:
    cattle.io/password-hash: bcrypt
  ownerReferences:
    - apiVersion: management.cattle.io/v3
      kind: User
      name: $admin_object
      uid: $admin_uid
type: Opaque
data:
  password: $password_b64
EOF_SECRET
  chmod 0600 "$secret_manifest"
  run_root "$kubectl_path" \
    --kubeconfig /etc/rancher/rke2/rke2.yaml \
    apply -f "$secret_manifest" >/dev/null
fi

algorithm_after_patch=$(run_root "$kubectl_path" \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  -n "$password_namespace" get secret "$admin_object" \
  -o jsonpath='{.metadata.annotations.cattle\.io/password-hash}')
if [ "$algorithm_after_patch" != bcrypt ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:password-secret-sync-failed'
  exit 29
fi
printf '%s\n' 'LAYERSENTRY_PASSWORD_SECRET_SYNC=true'

if run_root "$kubectl_path" --kubeconfig /etc/rancher/rke2/rke2.yaml \
    -n cattle-system get configmap admincreated >/dev/null 2>&1; then
  bootstrap_present=true
else
  bootstrap_present=false
fi

admin_password=$(cat "$admin_file")
printf '{"username":"%s","password":"%s","responseType":"token"}' \
  "$admin_username" "$admin_password" > "$login_body"
unset admin_password
login_attempt=1
login_status=000
token_present=false
while [ "$login_attempt" -le 30 ]; do
  login_status=$(curl -ksS --http1.1 \
    --connect-timeout 10 --max-time 30 \
    --request POST \
    --header 'Accept: application/json' \
    --header 'Content-Type: application/json' \
    --data-binary "@$login_body" \
    --output "$login_response" \
    --write-out '%{http_code}' \
    '__CLUSTER_URL__/v3-public/localProviders/local?action=login' 2>/dev/null || printf '000')
  if { [ "$login_status" = 200 ] || [ "$login_status" = 201 ]; } \
      && grep -q '"token"' "$login_response"; then
    token_present=true
    break
  fi
  login_attempt=$((login_attempt + 1))
  sleep 5
done

algorithm_after_login=$(run_root "$kubectl_path" \
  --kubeconfig /etc/rancher/rke2/rke2.yaml \
  -n "$password_namespace" get secret "$admin_object" \
  -o jsonpath='{.metadata.annotations.cattle\.io/password-hash}')

printf 'LAYERSENTRY_ADMIN_OBJECT_COUNT=%s\n' "$admin_count"
printf 'LAYERSENTRY_ADMIN_OBJECT=%s\n' "$admin_object"
printf 'LAYERSENTRY_ADMIN_USERNAME=%s\n' "$admin_username"
printf 'LAYERSENTRY_ADMIN_MUST_CHANGE=%s\n' "$must_change"
printf 'LAYERSENTRY_BOOTSTRAP_CONFIGMAP=%s\n' "$bootstrap_present"
printf 'LAYERSENTRY_PASSWORD_SECRET_EXISTED=%s\n' "$secret_exists"
printf 'LAYERSENTRY_PASSWORD_ALGORITHM_BEFORE=%s\n' "$algorithm_before"
printf 'LAYERSENTRY_PASSWORD_ALGORITHM_AFTER_PATCH=%s\n' "$algorithm_after_patch"
printf 'LAYERSENTRY_PASSWORD_ALGORITHM_AFTER_LOGIN=%s\n' "$algorithm_after_login"
printf 'LAYERSENTRY_REMOTE_LOGIN_HTTP=%s\n' "$login_status"
printf 'LAYERSENTRY_REMOTE_LOGIN_TOKEN=%s\n' "$token_present"
if [ "$token_present" != true ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_ERROR:remote-login-failed-after-secret-sync'
  exit 30
fi
printf '%s\n' 'LAYERSENTRY_ADMIN_INITIALIZATION_OK'
'@

    $remoteScript = $remoteTemplate.Replace('__ADMIN_BASE64__', $adminBase64)
    $remoteScript = $remoteScript.Replace('__NODE_BASE64__', $nodeBase64)
    $remoteScript = $remoteScript.Replace('__CLUSTER_URL__', $ClusterUrl)
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

    $resetSucceeded = ($safeOutput -match '(?m)^LAYERSENTRY_RESET_COMMAND=true$')
    $passwordSecretSynchronized = ($safeOutput -match '(?m)^LAYERSENTRY_PASSWORD_SECRET_SYNC=true$')
    $remoteLoginSucceeded = ($safeOutput -match '(?m)^LAYERSENTRY_REMOTE_LOGIN_TOKEN=true$')

    $fieldPatterns = @{
        Username = '(?m)^LAYERSENTRY_ADMIN_USERNAME=([^\r\n]+)'
        MustChange = '(?m)^LAYERSENTRY_ADMIN_MUST_CHANGE=([^\r\n]+)'
        Bootstrap = '(?m)^LAYERSENTRY_BOOTSTRAP_CONFIGMAP=([^\r\n]+)'
        SecretExisted = '(?m)^LAYERSENTRY_PASSWORD_SECRET_EXISTED=([^\r\n]+)'
        AlgorithmBefore = '(?m)^LAYERSENTRY_PASSWORD_ALGORITHM_BEFORE=([^\r\n]+)'
        AlgorithmAfterPatch = '(?m)^LAYERSENTRY_PASSWORD_ALGORITHM_AFTER_PATCH=([^\r\n]+)'
        AlgorithmAfterLogin = '(?m)^LAYERSENTRY_PASSWORD_ALGORITHM_AFTER_LOGIN=([^\r\n]+)'
        LoginStatus = '(?m)^LAYERSENTRY_REMOTE_LOGIN_HTTP=([0-9]{3})'
    }
    $matches = @{}
    foreach ($name in $fieldPatterns.Keys) {
        $match = [regex]::Match($safeOutput, $fieldPatterns[$name])
        if ($match.Success) {
            $matches[$name] = $match.Groups[1].Value.Trim()
        }
    }
    $remoteUsername = $matches['Username']
    $mustChangePassword = $matches['MustChange']
    $bootstrapConfigMapPresent = ($matches['Bootstrap'] -eq 'true')
    $passwordSecretExisted = ($matches['SecretExisted'] -eq 'true')
    $passwordAlgorithmBefore = $matches['AlgorithmBefore']
    $passwordAlgorithmAfterPatch = $matches['AlgorithmAfterPatch']
    $passwordAlgorithmAfterLogin = $matches['AlgorithmAfterLogin']
    if ($matches.ContainsKey('LoginStatus')) {
        $remoteLoginStatus = [int]$matches['LoginStatus']
    }

    if ($sshProcess.ExitCode -ne 0 -or
        -not $resetSucceeded -or
        -not $passwordSecretSynchronized -or
        -not $remoteLoginSucceeded) {
        $diagnosticLines = @(
            $safeOutput -split '[\r\n]+' |
                Where-Object { $_ -like 'LAYERSENTRY_*' }
        )
        $diagnostic = ($diagnosticLines -join ' | ')
        if ([string]::IsNullOrWhiteSpace($diagnostic)) {
            $diagnostic = ($safeError.Trim() -replace '[\r\n]+', ' | ')
        }
        if ($diagnostic.Length -gt 900) {
            $diagnostic = $diagnostic.Substring(0, 900)
        }
        throw "Administrator initialization failed over SSH with exit code $($sshProcess.ExitCode). $diagnostic"
    }

    $completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-ObjectProperty -Object $credentials -Name 'adminUsername' -Value $remoteUsername
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedAtUtc' -Value $completedAt
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedOnNode' -Value $NodeAddress
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordRemoteApiValidated' -Value $true
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordStorageAlgorithm' -Value $passwordAlgorithmAfterLogin
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
    if ($null -eq $oldAskPass) {
        Remove-Item Env:SSH_ASKPASS -ErrorAction SilentlyContinue
    }
    else {
        $env:SSH_ASKPASS = $oldAskPass
    }
    if ($null -eq $oldAskPassRequire) {
        Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    }
    else {
        $env:SSH_ASKPASS_REQUIRE = $oldAskPassRequire
    }
    if ($null -eq $oldDisplay) {
        Remove-Item Env:DISPLAY -ErrorAction SilentlyContinue
    }
    else {
        $env:DISPLAY = $oldDisplay
    }

    $finishedAt = (Get-Date).ToUniversalTime()
    $evidence = [ordered]@{
        schemaVersion = '4.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        clusterUrl = $ClusterUrl
        nodeAddress = $NodeAddress
        administratorResetCommandSucceeded = $resetSucceeded
        passwordSecretSynchronized = $passwordSecretSynchronized
        remoteAdministratorLoginSucceeded = $remoteLoginSucceeded
        administratorUsername = $remoteUsername
        mustChangePassword = $mustChangePassword
        bootstrapAdminConfigMapPresent = $bootstrapConfigMapPresent
        passwordSecretExistedBeforeSync = $passwordSecretExisted
        passwordAlgorithmBeforeSync = $passwordAlgorithmBefore
        passwordAlgorithmAfterPatch = $passwordAlgorithmAfterPatch
        passwordAlgorithmAfterLogin = $passwordAlgorithmAfterLogin
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
- Administrator reset command succeeded: $resetSucceeded
- Rancher password secret synchronized: $passwordSecretSynchronized
- Remote administrator login succeeded: $remoteLoginSucceeded
- Administrator username: $remoteUsername
- Must change password: $mustChangePassword
- Bootstrap admin ConfigMap present: $bootstrapConfigMapPresent
- Password algorithm before sync: $passwordAlgorithmBefore
- Password algorithm after patch: $passwordAlgorithmAfterPatch
- Password algorithm after login: $passwordAlgorithmAfterLogin
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
