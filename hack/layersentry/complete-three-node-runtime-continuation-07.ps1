[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$PrimaryNode = '10.10.10.11',
    [string[]]$NodeAddresses = @('10.10.10.11', '10.10.10.12', '10.10.10.13'),
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [int]$BaseRuntimeMaxWaitMinutes = 20,
    [int]$AuthenticatedResourceMaxWaitMinutes = 10,
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-three-node-runtime-continuation-07')
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

function Invoke-CurlJson {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $curl = Get-Command -Name 'curl.exe' -ErrorAction Stop | Select-Object -First 1
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
        '--header', '"User-Agent: LayerSentry-Authenticated-Runtime-Gate/1.0"',
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

    $statusText = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
    $statusCode = 0
    $parsedBody = $null
    $errorMessage = $null
    if ($process.ExitCode -ne 0) {
        $errorMessage = "curl exit code $($process.ExitCode)"
    }
    elseif (-not [int]::TryParse($statusText.Trim(), [ref]$statusCode)) {
        $errorMessage = 'invalid HTTP status output'
        $statusCode = 0
    }
    elseif (Test-Path -LiteralPath $responsePath -PathType Leaf) {
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

    Remove-Item -LiteralPath $requestPath, $responsePath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        StatusCode = if ($statusCode -gt 0) { $statusCode } else { $null }
        Body = $parsedBody
        Error = $errorMessage
    }
}

function Test-HttpSuccess {
    param([Parameter(Mandatory = $true)][object]$Response)

    return (
        $null -ne $Response.StatusCode -and
        [int]$Response.StatusCode -ge 200 -and
        [int]$Response.StatusCode -lt 300 -and
        $null -ne $Response.Body
    )
}

function Get-ConditionStatus {
    param(
        [AllowNull()][object[]]$Conditions,
        [Parameter(Mandatory = $true)][string]$Type
    )

    $match = @(
        @($Conditions) |
            Where-Object { [string]$_.type -eq $Type } |
            Select-Object -Last 1
    )
    if ($match.Count -eq 0) {
        return $null
    }
    return [string]$match[0].status
}

if ($ClusterUrl -cne 'https://10.10.10.10') {
    throw 'Authenticated runtime validation must use the management/API VIP https://10.10.10.10.'
}
if ($PrimaryNode -cne '10.10.10.11') {
    throw 'The runtime validation control node must be sen1 at 10.10.10.11.'
}
$expectedAddresses = @('10.10.10.11', '10.10.10.12', '10.10.10.13')
if (@(Compare-Object @($NodeAddresses | Sort-Object) @($expectedAddresses | Sort-Object)).Count -gt 0) {
    throw 'The runtime validation must cover exactly sen1, sen2, and sen3 addresses.'
}
if ($AuthenticatedResourceMaxWaitMinutes -lt 1 -or $AuthenticatedResourceMaxWaitMinutes -gt 20) {
    throw 'AuthenticatedResourceMaxWaitMinutes must be between 1 and 20.'
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$baseOutputDirectory = Join-Path $OutputDirectory 'base-runtime'
$resultPath = Join-Path $OutputDirectory 'runtime-completion.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$historyPath = Join-Path $OutputDirectory 'authenticated-resource-history.jsonl'
$tempDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-authenticated-runtime-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $tempDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $tempDirectory

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$baseRuntimePassed = $false
$apiAuthenticated = $false
$kubevirtHealthy = $false
$longhornHealthy = $false
$kubevirtApiVersion = 'kubevirt.io/v1'
$longhornApiVersion = $null
$kubevirtEvidence = @()
$longhornEvidence = @()
$token = $null
$credentials = $null
$adminPassword = $null

try {
    $baseScript = Join-Path $PSScriptRoot 'complete-three-node-runtime.ps1'
    if (-not (Test-Path -LiteralPath $baseScript -PathType Leaf)) {
        throw "Base runtime validator is missing: $baseScript"
    }
    & $baseScript `
        -ClusterUrl $ClusterUrl `
        -PrimaryNode $PrimaryNode `
        -NodeAddresses $NodeAddresses `
        -CredentialPath $CredentialPath `
        -MaxWaitMinutes $BaseRuntimeMaxWaitMinutes `
        -OutputDirectory $baseOutputDirectory

    $baseResultPath = Join-Path $baseOutputDirectory 'runtime-completion.json'
    if (-not (Test-Path -LiteralPath $baseResultPath -PathType Leaf)) {
        throw 'The base authenticated Kubernetes runtime result is missing.'
    }
    $baseResult = Get-Content -LiteralPath $baseResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $baseRuntimePassed = [bool]$baseResult.passed
    if (-not $baseRuntimePassed) {
        throw "Base authenticated Kubernetes runtime validation failed: $($baseResult.failure)"
    }

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw "Protected credential file is missing after base runtime validation: $CredentialPath"
    }
    $credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $adminPassword = Get-PropertyValue -Object $credentials -Names @('adminPassword', 'AdminPassword')
    if ([string]::IsNullOrWhiteSpace($adminPassword) -or $adminPassword.Length -lt 16) {
        throw 'The protected credential file does not contain a valid administrator password.'
    }

    $loginDeadline = (Get-Date).ToUniversalTime().AddMinutes(5)
    do {
        $loginResponse = Invoke-CurlJson `
            -Method POST `
            -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
            -Body ([ordered]@{
                username = 'admin'
                password = $adminPassword
                responseType = 'token'
            }) `
            -WorkingDirectory $tempDirectory
        if (Test-HttpSuccess -Response $loginResponse) {
            $token = Get-PropertyValue -Object $loginResponse.Body -Names @('token')
            $apiAuthenticated = -not [string]::IsNullOrWhiteSpace($token)
        }
        if (-not $apiAuthenticated) {
            Start-Sleep -Seconds 8
        }
    } while (-not $apiAuthenticated -and (Get-Date).ToUniversalTime() -lt $loginDeadline)
    if (-not $apiAuthenticated) {
        throw 'Rancher API authentication at the management VIP did not succeed.'
    }

    $resourceDeadline = (Get-Date).ToUniversalTime().AddMinutes($AuthenticatedResourceMaxWaitMinutes)
    $attempt = 0
    do {
        $attempt++
        $kubevirtResponse = Invoke-CurlJson `
            -Method GET `
            -Uri "$ClusterUrl/k8s/clusters/local/apis/kubevirt.io/v1/namespaces/harvester-system/kubevirts" `
            -BearerToken $token `
            -WorkingDirectory $tempDirectory

        $kubevirtEvidence = @()
        $kubevirtHealthy = $false
        if (Test-HttpSuccess -Response $kubevirtResponse) {
            foreach ($item in @($kubevirtResponse.Body.items)) {
                $available = Get-ConditionStatus -Conditions @($item.status.conditions) -Type 'Available'
                $kubevirtEvidence += [pscustomobject]@{
                    name = [string]$item.metadata.name
                    namespace = [string]$item.metadata.namespace
                    phase = [string]$item.status.phase
                    available = $available
                }
            }
            $kubevirtHealthy = (
                $kubevirtEvidence.Count -ge 1 -and
                @($kubevirtEvidence | Where-Object {
                    [string]$_.phase -ne 'Deployed' -or [string]$_.available -ne 'True'
                }).Count -eq 0
            )
        }

        $longhornResponse = Invoke-CurlJson `
            -Method GET `
            -Uri "$ClusterUrl/k8s/clusters/local/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes" `
            -BearerToken $token `
            -WorkingDirectory $tempDirectory
        $longhornApiVersion = 'longhorn.io/v1beta2'
        if ($null -ne $longhornResponse.StatusCode -and [int]$longhornResponse.StatusCode -eq 404) {
            $longhornResponse = Invoke-CurlJson `
                -Method GET `
                -Uri "$ClusterUrl/k8s/clusters/local/apis/longhorn.io/v1beta1/namespaces/longhorn-system/nodes" `
                -BearerToken $token `
                -WorkingDirectory $tempDirectory
            $longhornApiVersion = 'longhorn.io/v1beta1'
        }

        $longhornEvidence = @()
        $longhornHealthy = $false
        if (Test-HttpSuccess -Response $longhornResponse) {
            foreach ($item in @($longhornResponse.Body.items)) {
                $longhornEvidence += [pscustomobject]@{
                    name = [string]$item.metadata.name
                    ready = (Get-ConditionStatus -Conditions @($item.status.conditions) -Type 'Ready')
                    schedulable = (Get-ConditionStatus -Conditions @($item.status.conditions) -Type 'Schedulable')
                    allowScheduling = [bool]$item.spec.allowScheduling
                }
            }
            $actualLonghornNames = @($longhornEvidence | ForEach-Object { [string]$_.name } | Sort-Object)
            $expectedLonghornNames = @('sen1', 'sen2', 'sen3')
            $longhornHealthy = (
                $longhornEvidence.Count -eq 3 -and
                @(Compare-Object $expectedLonghornNames $actualLonghornNames).Count -eq 0 -and
                @($longhornEvidence | Where-Object { [string]$_.ready -ne 'True' }).Count -eq 0
            )
        }

        [ordered]@{
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            attempt = $attempt
            authenticatedThrough = $ClusterUrl
            kubevirtStatusCode = $kubevirtResponse.StatusCode
            kubevirtResourceCount = $kubevirtEvidence.Count
            kubevirtHealthy = $kubevirtHealthy
            longhornStatusCode = $longhornResponse.StatusCode
            longhornApiVersion = $longhornApiVersion
            longhornNodeCount = $longhornEvidence.Count
            longhornHealthy = $longhornHealthy
            passed = ($kubevirtHealthy -and $longhornHealthy)
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath $historyPath -Encoding UTF8

        if (-not ($kubevirtHealthy -and $longhornHealthy)) {
            Start-Sleep -Seconds 15
        }
    } while (-not ($kubevirtHealthy -and $longhornHealthy) -and (Get-Date).ToUniversalTime() -lt $resourceDeadline)

    if (-not $kubevirtHealthy) {
        throw 'Authenticated KubeVirt validation at the management VIP did not prove an Available, Deployed KubeVirt resource.'
    }
    if (-not $longhornHealthy) {
        throw 'Authenticated Longhorn validation at the management VIP did not prove exactly sen1, sen2, and sen3 as Ready Longhorn nodes.'
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
        schemaVersion = '2.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        clusterUrl = $ClusterUrl
        primaryNode = $PrimaryNode
        expectedNodeAddresses = $NodeAddresses
        baseAuthenticatedKubernetesRuntimePassed = $baseRuntimePassed
        rancherApiAuthenticationPassed = $apiAuthenticated
        kubevirtApiVersion = $kubevirtApiVersion
        kubevirtResourceCount = $kubevirtEvidence.Count
        kubevirtHealthy = $kubevirtHealthy
        kubevirtResources = $kubevirtEvidence
        longhornApiVersion = $longhornApiVersion
        longhornNodeCount = $longhornEvidence.Count
        longhornHealthy = $longhornHealthy
        longhornNodes = $longhornEvidence
        authenticatedKubernetesKubeVirtLonghornValidationPassed = $passed
        credentialValuesWrittenToEvidence = $false
        kubeconfigWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        installationApiQualified = $passed
        workloadQualified = $false
        trueAirgapQualified = $false
        haQualified = $false
        upgradeQualified = $false
        backupRestoreQualified = $false
        productionReleaseApproved = $false
        passed = $passed
        failure = $failure
    } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry authenticated three-node runtime continuation

- Management/API endpoint: **$ClusterUrl**
- Base authenticated Kubernetes validation passed: **$baseRuntimePassed**
- Rancher API authentication passed: **$apiAuthenticated**
- Authenticated KubeVirt validation passed: **$kubevirtHealthy**
- Authenticated Longhorn validation passed: **$longhornHealthy**
- KubeVirt resources observed: **$($kubevirtEvidence.Count)**
- Longhorn nodes observed: **$($longhornEvidence.Count) / 3**
- EULA automatically accepted: **false**
- Production release approved: **false**
- Passed: **$passed**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $token = $null
    $adminPassword = $null
    $credentials = $null
}