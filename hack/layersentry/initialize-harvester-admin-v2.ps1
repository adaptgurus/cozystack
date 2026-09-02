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
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $read = [System.Security.AccessControl.FileSystemRights]::Read
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', $fullControl, $inheritance, $propagation, $allow
    )
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', $read, $inheritance, $propagation, $allow
    )
    [void]$acl.AddAccessRule($systemRule)
    [void]$acl.AddAccessRule($adminRule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Invoke-CurlJson {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $curl) {
        throw 'curl.exe is not installed on the Windows runner.'
    }

    $id = [Guid]::NewGuid().ToString('N')
    $bodyPath = Join-Path $WorkingDirectory "$id.request.json"
    $responsePath = Join-Path $WorkingDirectory "$id.response.json"
    $statusPath = Join-Path $WorkingDirectory "$id.status.txt"
    $stderrPath = Join-Path $WorkingDirectory "$id.stderr.txt"

    $arguments = @(
        '--silent',
        '--show-error',
        '--insecure',
        '--http1.1',
        '--connect-timeout', '10',
        '--max-time', '45',
        '--request', $Method,
        '--header', '"Accept: application/json"',
        '--header', '"User-Agent: LayerSentry-Admin-Initialization/2.0"',
        '--output', $responsePath,
        '--write-out', '%{http_code}'
    )
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $arguments += @('--header', "`"Authorization: Bearer $BearerToken`"")
    }
    if ($null -ne $Body) {
        Write-Utf8NoBom -Path $bodyPath -Value ($Body | ConvertTo-Json -Depth 20 -Compress)
        $arguments += @(
            '--header', '"Content-Type: application/json"',
            '--data-binary', "@$bodyPath"
        )
    }
    $arguments += $Uri

    $process = Start-Process `
        -FilePath $curl.Source `
        -ArgumentList $arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $statusPath `
        -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        throw "curl.exe failed with exit code $($process.ExitCode) for $Method $Uri"
    }

    $statusText = [string](Get-Content -LiteralPath $statusPath -Raw -ErrorAction SilentlyContinue)
    $statusCode = 0
    if (-not [int]::TryParse($statusText.Trim(), [ref]$statusCode)) {
        throw "curl.exe returned an invalid HTTP status for $Method $Uri"
    }

    $parsedBody = $null
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
        $responseText = [string](Get-Content -LiteralPath $responsePath -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($responseText)) {
            try {
                $parsedBody = $responseText | ConvertFrom-Json
            }
            catch {
                $parsedBody = $null
            }
        }
    }
    return [pscustomobject]@{
        StatusCode = $statusCode
        Body = $parsedBody
    }
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$resultPath = Join-Path $OutputDirectory 'admin-initialization.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$tempDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-admin-reset-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $tempDirectory

$startedAt = (Get-Date).ToUniversalTime()
$sshResetSucceeded = $false
$apiAuthenticated = $false
$rootStatusCode = $null
$failure = $null
$nodePassword = $null
$adminPassword = $null
$credentials = $null
$token = $null
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
cleanup() {
  rm -f "`$admin_file" "`$node_file" "`$reset_log"
}
trap cleanup EXIT HUP INT TERM
printf '%s' '$adminBase64' | base64 -d > "`$admin_file"
printf '\n' >> "`$admin_file"
printf '%s' '$nodeBase64' | base64 -d > "`$node_file"
printf '\n' >> "`$node_file"
chmod 0600 "`$admin_file" "`$node_file"
rancherd_path=`$(command -v rancherd 2>/dev/null || true)
if [ -z "`$rancherd_path" ] && [ -x /usr/bin/rancherd ]; then
  rancherd_path=/usr/bin/rancherd
fi
if [ -z "`$rancherd_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:rancherd-not-found'
  exit 21
fi
attempt=1
while [ "`$attempt" -le 12 ]; do
  if sudo -n true >/dev/null 2>&1; then
    if sudo -n "`$rancherd_path" reset-admin --kubeconfig /etc/rancher/rke2/rke2.yaml --password-file "`$admin_file" >"`$reset_log" 2>&1; then
      printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_OK'
      exit 0
    fi
  else
    if sudo -S -p '' "`$rancherd_path" reset-admin --kubeconfig /etc/rancher/rke2/rke2.yaml --password-file "`$admin_file" <"`$node_file" >"`$reset_log" 2>&1; then
      printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_OK'
      exit 0
    fi
  fi
  attempt=`$((attempt + 1))
  sleep 10
done
printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_ERROR:cluster-not-ready-or-sudo-failed'
exit 22
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
    if ($sshProcess.ExitCode -ne 0 -or $safeOutput -notmatch 'LAYERSENTRY_ADMIN_RESET_OK') {
        $diagnostic = (($safeOutput + "`n" + $safeError).Trim() -replace '[\r\n]+', ' | ')
        if ($diagnostic.Length -gt 500) {
            $diagnostic = $diagnostic.Substring(0, 500)
        }
        throw "Administrator reset failed over SSH with exit code $($sshProcess.ExitCode). $diagnostic"
    }
    $sshResetSucceeded = $true

    Start-Sleep -Seconds 8
    $rootResponse = Invoke-CurlJson -Method GET -Uri "$ClusterUrl/" -WorkingDirectory $tempDirectory
    $rootStatusCode = $rootResponse.StatusCode
    $loginResponse = Invoke-CurlJson `
        -Method POST `
        -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
        -Body ([ordered]@{
            username = 'admin'
            password = $adminPassword
            responseType = 'token'
        }) `
        -WorkingDirectory $tempDirectory
    if ($loginResponse.StatusCode -lt 200 -or $loginResponse.StatusCode -ge 300 -or $null -eq $loginResponse.Body) {
        throw "Administrator reset completed, but API login returned HTTP $($loginResponse.StatusCode)."
    }
    $token = Get-PropertyValue -Object $loginResponse.Body -Names @('token')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Administrator reset completed, but the API login response did not contain a token.'
    }
    $apiAuthenticated = $true

    $completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedAtUtc' -Value $completedAt
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedOnNode' -Value $NodeAddress
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordApiValidated' -Value $true
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
        schemaVersion = '2.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        clusterUrl = $ClusterUrl
        nodeAddress = $NodeAddress
        secureSshResetSucceeded = $sshResetSucceeded
        administratorApiAuthenticated = $apiAuthenticated
        authenticatedUser = if ($apiAuthenticated) { 'admin' } else { $null }
        rootStatusCode = $rootStatusCode
        credentialPath = $CredentialPath
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
- Secure SSH reset succeeded: $sshResetSucceeded
- Administrator API authentication succeeded: $apiAuthenticated
- Authenticated user: $(if ($apiAuthenticated) { 'admin' } else { '' })
- Root HTTP status: $rootStatusCode
- EULA automatically accepted: **false**
- Credential values written to evidence: **false**
- Production release approved: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $token = $null
    $nodePassword = $null
    $adminPassword = $null
    $credentials = $null
}
