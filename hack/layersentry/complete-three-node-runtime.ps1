[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$PrimaryNode = '10.10.10.11',
    [string[]]$NodeAddresses = @('10.10.10.11', '10.10.10.12', '10.10.10.13'),
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [int]$MaxWaitMinutes = 55,
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-three-node-runtime')
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
    [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', $fullControl, $inheritance, $propagation, $allow
    )))
    [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', $read, $inheritance, $propagation, $allow
    )))
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
        return $client.Connected
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
        throw 'curl.exe is not installed.'
    }

    $id = [Guid]::NewGuid().ToString('N')
    $requestPath = Join-Path $WorkingDirectory "$id.request.json"
    $responsePath = Join-Path $WorkingDirectory "$id.response.json"
    $stdoutPath = Join-Path $WorkingDirectory "$id.stdout.txt"
    $stderrPath = Join-Path $WorkingDirectory "$id.stderr.txt"

    $arguments = @(
        '--silent', '--show-error', '--insecure', '--http1.1',
        '--connect-timeout', '10', '--max-time', '60',
        '--request', $Method,
        '--header', '"Accept: application/json"',
        '--header', '"User-Agent: LayerSentry-Runtime-Completion/1.0"',
        '--output', $responsePath,
        '--write-out', '%{http_code}'
    )
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $arguments += @('--header', "`"Authorization: Bearer $BearerToken`"")
    }
    if ($null -ne $Body) {
        Write-Utf8NoBom -Path $requestPath -Value ($Body | ConvertTo-Json -Depth 20 -Compress)
        $arguments += @(
            '--header', '"Content-Type: application/json"',
            '--data-binary', "@$requestPath"
        )
    }
    $arguments += $Uri

    $process = Start-Process `
        -FilePath $curl.Source `
        -ArgumentList $arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    if ($process.ExitCode -ne 0) {
        return [pscustomobject]@{
            StatusCode = $null
            Body = $null
            Error = "curl exit code $($process.ExitCode)"
        }
    }

    $statusText = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
    $statusCode = 0
    if (-not [int]::TryParse($statusText.Trim(), [ref]$statusCode)) {
        return [pscustomobject]@{
            StatusCode = $null
            Body = $null
            Error = 'invalid HTTP status output'
        }
    }

    $parsedBody = $null
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
        $responseText = [string](Get-Content -LiteralPath $responsePath -Raw -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($responseText)) {
            try { $parsedBody = $responseText | ConvertFrom-Json } catch { $parsedBody = $null }
        }
    }
    return [pscustomobject]@{
        StatusCode = $statusCode
        Body = $parsedBody
        Error = $null
    }
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$tempDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-runtime-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $tempDirectory

$resultPath = Join-Path $OutputDirectory 'runtime-completion.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$historyPath = Join-Path $OutputDirectory 'readiness-history.jsonl'
$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$networkReady = $false
$sshValidationSucceeded = $false
$adminResetSucceeded = $false
$apiAuthenticated = $false
$nodeEvidence = @()
$kubevirtEvidence = @()
$longhornEvidence = @()
$storageEvidence = @()
$apiNodeEvidence = @()
$credentials = $null
$nodePassword = $null
$adminPassword = $null
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

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    do {
        $nodePorts = @()
        foreach ($address in $NodeAddresses) {
            $nodePorts += [ordered]@{
                address = $address
                ssh = (Test-TcpPort -Address $address -Port 22)
                supervisor = (Test-TcpPort -Address $address -Port 9345)
                kubelet = (Test-TcpPort -Address $address -Port 10250)
            }
        }
        $vip443 = Test-TcpPort -Address '10.10.10.10' -Port 443 -TimeoutMilliseconds 2000
        $vip6443 = Test-TcpPort -Address '10.10.10.10' -Port 6443 -TimeoutMilliseconds 2000
        $networkReady = (
            @($nodePorts | Where-Object { -not $_.ssh }).Count -eq 0 -and
            $vip443
        )
        ([ordered]@{
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            nodePorts = $nodePorts
            vip443 = $vip443
            vip6443 = $vip6443
            ready = $networkReady
        } | ConvertTo-Json -Depth 8 -Compress) |
            Add-Content -LiteralPath $historyPath -Encoding UTF8
        if (-not $networkReady) {
            Start-Sleep -Seconds 15
        }
    } while (-not $networkReady -and (Get-Date) -lt $deadline)

    if (-not $networkReady) {
        throw "Three-node network readiness was not reached within $MaxWaitMinutes minutes."
    }

    $ssh = Get-Command -Name 'ssh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ssh) {
        throw 'Windows OpenSSH client ssh.exe is not installed.'
    }

    $nodePasswordPath = Join-Path $tempDirectory 'node-password.txt'
    $askPassPath = Join-Path $tempDirectory 'askpass.cmd'
    $remotePath = Join-Path $tempDirectory 'validate-and-reset.sh'
    $sshStdoutPath = Join-Path $tempDirectory 'ssh.stdout.txt'
    $sshStderrPath = Join-Path $tempDirectory 'ssh.stderr.txt'
    Write-Utf8NoBom -Path $nodePasswordPath -Value ($nodePassword + "`r`n")
    Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$nodePasswordPath`"`r`n")

    $adminBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($adminPassword))
    $nodeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))
    $remote = @"
set -eu
umask 077
admin_file=`$(mktemp /tmp/layersentry-admin.XXXXXX)
node_file=`$(mktemp /tmp/layersentry-node.XXXXXX)
cleanup() { rm -f "`$admin_file" "`$node_file"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '$adminBase64' | base64 -d > "`$admin_file"
printf '\n' >> "`$admin_file"
printf '%s' '$nodeBase64' | base64 -d > "`$node_file"
printf '\n' >> "`$node_file"
chmod 0600 "`$admin_file" "`$node_file"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "`$node_file"
fi
kubectl_path=`$(command -v kubectl 2>/dev/null || true)
if [ -z "`$kubectl_path" ] && [ -x /var/lib/rancher/rke2/bin/kubectl ]; then
  kubectl_path=/var/lib/rancher/rke2/bin/kubectl
fi
if [ -z "`$kubectl_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ERROR|kubectl-not-found'
  exit 31
fi
kubeconfig=/etc/rancher/rke2/rke2.yaml
attempt=1
while [ "`$attempt" -le 120 ]; do
  total=`$(sudo -n "`$kubectl_path" --kubeconfig "`$kubeconfig" get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
  ready=`$(sudo -n "`$kubectl_path" --kubeconfig "`$kubeconfig" get nodes --no-headers 2>/dev/null | awk '`$2 ~ /^Ready/ {c++} END {print c+0}' || true)
  if [ "`$total" = '3' ] && [ "`$ready" = '3' ]; then
    break
  fi
  attempt=`$((attempt + 1))
  sleep 15
done
sudo -n "`$kubectl_path" --kubeconfig "`$kubeconfig" get nodes --no-headers |
  awk '{print "LAYERSENTRY_NODE|" `$1 "|" `$2 "|" `$3 "|" `$4 "|" `$5}'
sudo -n "`$kubectl_path" --kubeconfig "`$kubeconfig" get kubevirt -n harvester-system --no-headers 2>/dev/null |
  awk '{print "LAYERSENTRY_KUBEVIRT|" `$1 "|" `$2 "|" `$3}' || true
sudo -n "`$kubectl_path" --kubeconfig "`$kubeconfig" get nodes.longhorn.io -n longhorn-system --no-headers 2>/dev/null |
  awk '{print "LAYERSENTRY_LONGHORN|" `$1 "|" `$2 "|" `$3}' || true
sudo -n "`$kubectl_path" --kubeconfig "`$kubeconfig" get storageclass --no-headers 2>/dev/null |
  awk '{print "LAYERSENTRY_STORAGECLASS|" `$1 "|" `$2 "|" `$3}' || true
rancherd_path=`$(command -v rancherd 2>/dev/null || true)
if [ -z "`$rancherd_path" ] && [ -x /usr/bin/rancherd ]; then
  rancherd_path=/usr/bin/rancherd
fi
if [ -z "`$rancherd_path" ]; then
  printf '%s\n' 'LAYERSENTRY_ERROR|rancherd-not-found'
  exit 32
fi
if sudo -n "`$rancherd_path" reset-admin --kubeconfig "`$kubeconfig" --password-file "`$admin_file" >/dev/null 2>&1; then
  printf '%s\n' 'LAYERSENTRY_ADMIN_RESET_OK'
else
  printf '%s\n' 'LAYERSENTRY_ERROR|admin-reset-failed'
  exit 33
fi
"@
    $remote = ($remote -replace "`r`n", "`n").TrimStart([char]0xFEFF)
    Write-Utf8NoBom -Path $remotePath -Value $remote

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
        "rancher@$PrimaryNode",
        'bash', '-s'
    )
    $sshProcess = Start-Process `
        -FilePath $ssh.Source `
        -ArgumentList $sshArguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardInput $remotePath `
        -RedirectStandardOutput $sshStdoutPath `
        -RedirectStandardError $sshStderrPath

    $sshOutput = [string](Get-Content -LiteralPath $sshStdoutPath -Raw -ErrorAction SilentlyContinue)
    $sshError = [string](Get-Content -LiteralPath $sshStderrPath -Raw -ErrorAction SilentlyContinue)
    $safeOutput = $sshOutput.Replace($nodePassword, '[REDACTED]').Replace($adminPassword, '[REDACTED]')
    $safeError = $sshError.Replace($nodePassword, '[REDACTED]').Replace($adminPassword, '[REDACTED]')
    if ($sshProcess.ExitCode -ne 0) {
        $diagnostic = (($safeOutput + "`n" + $safeError).Trim() -replace '[\r\n]+', ' | ')
        if ($diagnostic.Length -gt 600) { $diagnostic = $diagnostic.Substring(0, 600) }
        throw "Runtime validation over SSH failed with exit code $($sshProcess.ExitCode). $diagnostic"
    }

    foreach ($line in @($safeOutput -split "`r?`n")) {
        if ($line -like 'LAYERSENTRY_NODE|*') {
            $parts = $line.Split('|')
            if ($parts.Count -ge 3) {
                $nodeEvidence += [pscustomobject]@{
                    name = $parts[1]
                    status = $parts[2]
                    roles = if ($parts.Count -ge 4) { $parts[3] } else { $null }
                    age = if ($parts.Count -ge 5) { $parts[4] } else { $null }
                    version = if ($parts.Count -ge 6) { $parts[5] } else { $null }
                }
            }
        }
        elseif ($line -like 'LAYERSENTRY_KUBEVIRT|*') {
            $kubevirtEvidence += $line
        }
        elseif ($line -like 'LAYERSENTRY_LONGHORN|*') {
            $longhornEvidence += $line
        }
        elseif ($line -like 'LAYERSENTRY_STORAGECLASS|*') {
            $storageEvidence += $line
        }
    }
    $sshValidationSucceeded = (
        $nodeEvidence.Count -eq 3 -and
        @($nodeEvidence | Where-Object { [string]$_.status -notmatch '^Ready' }).Count -eq 0
    )
    if (-not $sshValidationSucceeded) {
        throw 'SSH validation did not prove exactly three Ready Kubernetes nodes.'
    }
    $adminResetSucceeded = ($safeOutput -match 'LAYERSENTRY_ADMIN_RESET_OK')
    if (-not $adminResetSucceeded) {
        throw 'The administrator reset success marker was not returned.'
    }

    $loginDeadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 8
        $loginResponse = Invoke-CurlJson `
            -Method POST `
            -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
            -Body ([ordered]@{
                username = 'admin'
                password = $adminPassword
                responseType = 'token'
            }) `
            -WorkingDirectory $tempDirectory
        if ($null -ne $loginResponse.StatusCode -and
            $loginResponse.StatusCode -ge 200 -and
            $loginResponse.StatusCode -lt 300 -and
            $null -ne $loginResponse.Body) {
            $token = Get-PropertyValue -Object $loginResponse.Body -Names @('token')
            $apiAuthenticated = -not [string]::IsNullOrWhiteSpace($token)
        }
    } while (-not $apiAuthenticated -and (Get-Date) -lt $loginDeadline)
    if (-not $apiAuthenticated) {
        throw 'Administrator reset succeeded, but Rancher API authentication did not succeed within five minutes.'
    }

    $nodesResponse = Invoke-CurlJson `
        -Method GET `
        -Uri "$ClusterUrl/k8s/clusters/local/api/v1/nodes" `
        -BearerToken $token `
        -WorkingDirectory $tempDirectory
    if ($nodesResponse.StatusCode -lt 200 -or $nodesResponse.StatusCode -ge 300 -or $null -eq $nodesResponse.Body) {
        throw "Authenticated Kubernetes node API returned HTTP $($nodesResponse.StatusCode)."
    }
    $apiItems = @($nodesResponse.Body.items)
    foreach ($node in $apiItems) {
        $ready = @(
            @($node.status.conditions) |
                Where-Object { [string]$_.type -eq 'Ready' } |
                Select-Object -Last 1
        )
        $apiNodeEvidence += [pscustomobject]@{
            name = [string]$node.metadata.name
            ready = if ($ready.Count -gt 0) { [string]$ready[0].status } else { $null }
            kubeletVersion = [string]$node.status.nodeInfo.kubeletVersion
            osImage = [string]$node.status.nodeInfo.osImage
        }
    }
    $expectedNames = @('sen1', 'sen2', 'sen3')
    $actualNames = @($apiNodeEvidence | ForEach-Object { $_.name } | Sort-Object)
    if ($apiNodeEvidence.Count -ne 3 -or @(Compare-Object $expectedNames $actualNames).Count -gt 0) {
        throw "Authenticated API node inventory is [$($actualNames -join ', ')]; expected [sen1, sen2, sen3]."
    }
    if (@($apiNodeEvidence | Where-Object { $_.ready -ne 'True' }).Count -gt 0) {
        throw 'Authenticated Kubernetes API reports one or more nodes as not Ready.'
    }

    $completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedAtUtc' -Value $completedAt
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordInitializedOnNode' -Value $PrimaryNode
    Set-ObjectProperty -Object $credentials -Name 'adminPasswordApiValidated' -Value $true
    $credentialTempPath = "$CredentialPath.tmp"
    Write-Utf8NoBom -Path $credentialTempPath -Value ($credentials | ConvertTo-Json -Depth 8)
    Move-Item -LiteralPath $credentialTempPath -Destination $CredentialPath -Force
    Protect-CredentialFile -Path $CredentialPath
    $passed = $true
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
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        clusterUrl = $ClusterUrl
        primaryNode = $PrimaryNode
        expectedNodeAddresses = $NodeAddresses
        networkReady = $networkReady
        sshKubernetesValidationSucceeded = $sshValidationSucceeded
        administratorResetSucceeded = $adminResetSucceeded
        administratorApiAuthenticated = $apiAuthenticated
        passed = $passed
        failure = $failure
        kubernetesNodesFromSsh = $nodeEvidence
        kubevirtEvidence = $kubevirtEvidence
        longhornEvidence = $longhornEvidence
        storageClassEvidence = $storageEvidence
        kubernetesNodesFromAuthenticatedApi = $apiNodeEvidence
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        installationApiQualified = $passed
        workloadQualified = $false
        trueAirgapQualified = $false
        haQualified = $false
        upgradeQualified = $false
        backupRestoreQualified = $false
        productionReleaseApproved = $false
    }
    $result | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry three-node runtime completion

- Cluster URL: $ClusterUrl
- Expected nodes: sen1, sen2, sen3
- Network readiness reached: $networkReady
- SSH Kubernetes validation succeeded: $sshValidationSucceeded
- Administrator reset succeeded: $adminResetSucceeded
- Administrator API authentication succeeded: $apiAuthenticated
- Installation/API qualification passed: $passed
- Workload qualification: **false**
- True air-gap qualification: **false**
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
