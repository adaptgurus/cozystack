[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-harvester-api-validation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$resultPath = Join-Path $OutputDirectory 'cluster-api-validation.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$transportDirectory = Join-Path $OutputDirectory '.transport'
if (Test-Path -LiteralPath $transportDirectory) {
    Remove-Item -LiteralPath $transportDirectory -Recurse -Force
}
New-Item -Path $transportDirectory -ItemType Directory -Force | Out-Null

$startedAt = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$authenticated = $false
$authenticatedUser = $null
$token = $null
$credentials = $null
$passwordCandidates = @()
$loginAttemptCount = 0
$rootStatusCode = $null
$curlVersion = $null
$settings = @()
$nodes = @()
$pods = @()
$deployments = @()
$storageClasses = @()
$kubevirtItems = @()
$virtHandlers = @()
$longhornNodes = @()
$readyNodeCount = 0
$readyVirtHandlerCount = 0
$readyLonghornNodeCount = 0
$schedulableLonghornNodeCount = 0
$criticalUnhealthyPods = @()
$unhealthyDeployments = @()
$kubernetesVersion = $null

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }
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

function Get-CollectionItems {
    param([object]$Body)

    if ($null -eq $Body) {
        return @()
    }
    if ($null -ne $Body.PSObject.Properties['items']) {
        return @($Body.items)
    }
    if ($null -ne $Body.PSObject.Properties['data']) {
        return @($Body.data)
    }
    return @()
}

function Get-ConditionStatus {
    param(
        [object[]]$Conditions,
        [Parameter(Mandatory = $true)][string]$Type
    )

    $matches = @(
        $Conditions |
            Where-Object { [string]$_.type -eq $Type } |
            Select-Object -Last 1
    )
    if ($matches.Count -eq 0) {
        return $null
    }
    return [string]$matches[0].status
}

$curlCommand = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $curlCommand) {
    throw 'curl.exe is required for PowerShell 5.1-compatible TLS validation but is not installed.'
}
$curlPath = $curlCommand.Source
$curlVersion = [string]((& $curlPath --version | Select-Object -First 1))

function Invoke-LayerSentryJsonRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [int]$TimeoutSeconds = 45,
        [switch]$AllowHttpError
    )

    $requestId = [Guid]::NewGuid().ToString('N')
    $responsePath = Join-Path $transportDirectory "$requestId.response.json"
    $stderrPath = Join-Path $transportDirectory "$requestId.stderr.txt"
    $requestBodyPath = Join-Path $transportDirectory "$requestId.request.json"

    $arguments = @(
        '--silent',
        '--show-error',
        '--insecure',
        '--http1.1',
        '--connect-timeout', '10',
        '--max-time', [string]$TimeoutSeconds,
        '--request', $Method,
        '--header', 'Accept: application/json',
        '--header', 'User-Agent: LayerSentry-Cluster-Validation/2.0',
        '--output', $responsePath,
        '--write-out', '%{http_code}'
    )

    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $arguments += @('--header', "Authorization: Bearer $BearerToken")
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        [System.IO.File]::WriteAllText(
            $requestBodyPath,
            $json,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $arguments += @(
            '--header', 'Content-Type: application/json',
            '--data-binary', "@$requestBodyPath"
        )
    }

    $statusText = [string](& $curlPath @arguments 2> $stderrPath)
    $curlExitCode = $LASTEXITCODE
    $stderrText = $null
    if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
        $stderrText = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue).Trim()
    }

    if ($curlExitCode -ne 0) {
        $message = "curl.exe failed with exit code $curlExitCode for $Method $Uri"
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            $message += ": $stderrText"
        }
        if (-not $AllowHttpError) {
            throw $message
        }
        return [pscustomobject]@{
            StatusCode = $null
            Body = $null
            Error = $message
            CurlExitCode = $curlExitCode
        }
    }

    $statusCode = 0
    if (-not [int]::TryParse($statusText.Trim(), [ref]$statusCode)) {
        throw "curl.exe returned an invalid HTTP status value for $Method $Uri: $statusText"
    }

    $responseText = $null
    $parsedBody = $null
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
        $responseText = Get-Content -LiteralPath $responsePath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($responseText)) {
            try {
                $parsedBody = $responseText | ConvertFrom-Json
            }
            catch {
                $parsedBody = $null
            }
        }
    }

    if ($statusCode -ge 400 -and -not $AllowHttpError) {
        throw "HTTP $Method $Uri failed with status ${statusCode}."
    }

    return [pscustomobject]@{
        StatusCode = $statusCode
        Body = $parsedBody
        Error = if ($statusCode -ge 400) { "HTTP $statusCode" } else { $null }
        CurlExitCode = $curlExitCode
    }
}

function Convert-NodeSummary {
    param([Parameter(Mandatory = $true)][object]$Node)

    $conditions = @($Node.status.conditions)
    $labels = $Node.metadata.labels
    $roles = @()
    if ($null -ne $labels) {
        $roles = @(
            $labels.PSObject.Properties |
                Where-Object { $_.Name -like 'node-role.kubernetes.io/*' } |
                ForEach-Object { $_.Name.Substring('node-role.kubernetes.io/'.Length) } |
                Sort-Object
        )
    }

    $cpuVendor = $null
    if ($null -ne $labels -and $null -ne $labels.PSObject.Properties['cpu-feature.node.kubevirt.io/vmx']) {
        $cpuVendor = 'vmx'
    }
    elseif ($null -ne $labels -and $null -ne $labels.PSObject.Properties['cpu-feature.node.kubevirt.io/svm']) {
        $cpuVendor = 'svm'
    }

    return [ordered]@{
        name = [string]$Node.metadata.name
        ready = (Get-ConditionStatus -Conditions $conditions -Type 'Ready')
        memoryPressure = (Get-ConditionStatus -Conditions $conditions -Type 'MemoryPressure')
        diskPressure = (Get-ConditionStatus -Conditions $conditions -Type 'DiskPressure')
        pidPressure = (Get-ConditionStatus -Conditions $conditions -Type 'PIDPressure')
        networkUnavailable = (Get-ConditionStatus -Conditions $conditions -Type 'NetworkUnavailable')
        roles = $roles
        cpuVendor = $cpuVendor
        addresses = @($Node.status.addresses | ForEach-Object {
            [ordered]@{
                type = [string]$_.type
                address = [string]$_.address
            }
        })
        capacity = [ordered]@{
            cpu = [string]$Node.status.capacity.cpu
            memory = [string]$Node.status.capacity.memory
            pods = [string]$Node.status.capacity.pods
        }
        allocatable = [ordered]@{
            cpu = [string]$Node.status.allocatable.cpu
            memory = [string]$Node.status.allocatable.memory
            pods = [string]$Node.status.allocatable.pods
        }
        systemInfo = [ordered]@{
            architecture = [string]$Node.status.nodeInfo.architecture
            operatingSystem = [string]$Node.status.nodeInfo.operatingSystem
            osImage = [string]$Node.status.nodeInfo.osImage
            kernelVersion = [string]$Node.status.nodeInfo.kernelVersion
            containerRuntimeVersion = [string]$Node.status.nodeInfo.containerRuntimeVersion
            kubeletVersion = [string]$Node.status.nodeInfo.kubeletVersion
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw "Credential file is missing: $CredentialPath"
    }

    $credentialAcl = Get-Acl -LiteralPath $CredentialPath
    $unexpectedCredentialAccess = @(
        $credentialAcl.Access |
            Where-Object {
                $_.AccessControlType -eq 'Allow' -and
                $_.IdentityReference.Value -notmatch 'SYSTEM$|Administrators$' -and
                ($_.FileSystemRights.ToString() -match 'Read|FullControl|Modify')
            }
    )
    if ($unexpectedCredentialAccess.Count -gt 0) {
        throw 'The local bootstrap credential file grants read access outside SYSTEM/Administrators.'
    }

    $credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($names in @(
        @('adminPassword', 'AdminPassword'),
        @('rancherPassword', 'RancherPassword'),
        @('nodePassword', 'NodePassword'),
        @('password', 'Password')
    )) {
        $candidate = Get-PropertyValue -Object $credentials -Names $names
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -notin $passwordCandidates) {
            $passwordCandidates += $candidate
        }
    }
    if ($passwordCandidates.Count -eq 0) {
        throw 'No candidate administrator or node password exists in the protected local credential file.'
    }

    $rootResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$ClusterUrl/" -AllowHttpError
    $rootStatusCode = $rootResponse.StatusCode
    if ($null -eq $rootStatusCode) {
        throw "Cluster HTTPS endpoint is not reachable: $($rootResponse.Error)"
    }

    foreach ($candidateUser in @('admin', 'rancher')) {
        foreach ($candidatePassword in $passwordCandidates) {
            $loginAttemptCount++
            $loginResponse = Invoke-LayerSentryJsonRequest `
                -Method POST `
                -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
                -Body ([ordered]@{
                    username = $candidateUser
                    password = $candidatePassword
                    responseType = 'token'
                }) `
                -AllowHttpError

            if ($null -ne $loginResponse.StatusCode -and
                $loginResponse.StatusCode -ge 200 -and
                $loginResponse.StatusCode -lt 300 -and
                $null -ne $loginResponse.Body) {
                $candidateToken = Get-PropertyValue -Object $loginResponse.Body -Names @('token')
                if (-not [string]::IsNullOrWhiteSpace($candidateToken)) {
                    $authenticated = $true
                    $authenticatedUser = $candidateUser
                    $token = $candidateToken
                    break
                }
            }
        }
        if ($authenticated) {
            break
        }
    }

    if (-not $authenticated) {
        throw 'Local administrator authentication failed. The first-login web password is unfinished or differs from every protected bootstrap credential candidate.'
    }

    foreach ($settingName in @('first-login', 'eula-agreed', 'ui-pl', 'ui-brand', 'server-url')) {
        $settingResponse = Invoke-LayerSentryJsonRequest `
            -Method GET `
            -Uri "$ClusterUrl/v3/settings/$settingName" `
            -BearerToken $token `
            -AllowHttpError
        if ($settingResponse.StatusCode -ge 200 -and $settingResponse.StatusCode -lt 300 -and $null -ne $settingResponse.Body) {
            $settings += [ordered]@{
                name = $settingName
                value = [string](Get-PropertyValue -Object $settingResponse.Body -Names @('value'))
                default = [string](Get-PropertyValue -Object $settingResponse.Body -Names @('default'))
            }
        }
        else {
            $settings += [ordered]@{
                name = $settingName
                statusCode = $settingResponse.StatusCode
            }
        }
    }

    $proxy = "$ClusterUrl/k8s/clusters/local"
    $versionResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/version" -BearerToken $token
    $nodesResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/api/v1/nodes" -BearerToken $token
    $podsResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/api/v1/pods?limit=1000" -BearerToken $token -TimeoutSeconds 90
    $deploymentsResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/apis/apps/v1/deployments?limit=1000" -BearerToken $token -TimeoutSeconds 90
    $storageResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/apis/storage.k8s.io/v1/storageclasses" -BearerToken $token
    $kubevirtResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/apis/kubevirt.io/v1/namespaces/harvester-system/kubevirts" -BearerToken $token -AllowHttpError
    $virtHandlerResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/api/v1/namespaces/harvester-system/pods?labelSelector=kubevirt.io%2B%3Dvirt-handler" -BearerToken $token -AllowHttpError
    $longhornResponse = Invoke-LayerSentryJsonRequest -Method GET -Uri "$proxy/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes" -BearerToken $token -AllowHttpError

    $kubernetesVersion = $versionResponse.Body
    $nodes = @(
        Get-CollectionItems -Body $nodesResponse.Body |
            ForEach-Object { Convert-NodeSummary -Node $_ }
    )

    $pods = @(
        Get-CollectionItems -Body $podsResponse.Body |
            ForEach-Object {
                $conditions = @($_.status.conditions)
                $restartSum = (@($_.status.containerStatuses) |
                    Measure-Object -Property restartCount -Sum).Sum
                [ordered]@{
                    namespace = [string]$_.metadata.namespace
                    name = [string]$_.metadata.name
                    nodeName = [string]$_.spec.nodeName
                    phase = [string]$_.status.phase
                    ready = (Get-ConditionStatus -Conditions $conditions -Type 'Ready')
                    totalRestarts = if ($null -eq $restartSum) { 0 } else { [int]$restartSum }
                }
            }
    )

    $deployments = @(
        Get-CollectionItems -Body $deploymentsResponse.Body |
            ForEach-Object {
                [ordered]@{
                    namespace = [string]$_.metadata.namespace
                    name = [string]$_.metadata.name
                    desired = [int]$_.spec.replicas
                    ready = [int]$_.status.readyReplicas
                    available = [int]$_.status.availableReplicas
                    unavailable = [int]$_.status.unavailableReplicas
                }
            }
    )

    $storageClasses = @(
        Get-CollectionItems -Body $storageResponse.Body |
            ForEach-Object {
                [ordered]@{
                    name = [string]$_.metadata.name
                    provisioner = [string]$_.provisioner
                    reclaimPolicy = [string]$_.reclaimPolicy
                    volumeBindingMode = [string]$_.volumeBindingMode
                    allowVolumeExpansion = [bool]$_.allowVolumeExpansion
                    isDefault = ([string]$_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true')
                }
            }
    )

    $kubevirtItems = @(
        Get-CollectionItems -Body $kubevirtResponse.Body |
            ForEach-Object {
                [ordered]@{
                    namespace = [string]$_.metadata.namespace
                    name = [string]$_.metadata.name
                    phase = [string]$_.status.phase
                    available = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Available')
                    progressing = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Progressing')
                    degraded = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Degraded')
                }
            }
    )

    $virtHandlers = @(
        Get-CollectionItems -Body $virtHandlerResponse.Body |
            ForEach-Object {
                [ordered]@{
                    name = [string]$_.metadata.name
                    nodeName = [string]$_.spec.nodeName
                    phase = [string]$_.status.phase
                    ready = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Ready')
                }
            }
    )

    $longhornNodes = @(
        Get-CollectionItems -Body $longhornResponse.Body |
            ForEach-Object {
                $diskEvidence = @()
                if ($null -ne $_.status.diskStatus) {
                    $diskEvidence = @($_.status.diskStatus.PSObject.Properties | ForEach-Object {
                        [ordered]@{
                            name = $_.Name
                            storageAvailable = [int64]$_.Value.storageAvailable
                            storageMaximum = [int64]$_.Value.storageMaximum
                            storageScheduled = [int64]$_.Value.storageScheduled
                        }
                    })
                }
                [ordered]@{
                    name = [string]$_.metadata.name
                    allowScheduling = [bool]$_.spec.allowScheduling
                    ready = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Ready')
                    schedulable = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Schedulable')
                    disks = $diskEvidence
                }
            }
    )

    $readyNodeCount = @($nodes | Where-Object { $_.ready -eq 'True' }).Count
    $readyVirtHandlerCount = @(
        $virtHandlers |
            Where-Object { $_.phase -eq 'Running' -and $_.ready -eq 'True' }
    ).Count
    $readyLonghornNodeCount = @(
        $longhornNodes |
            Where-Object { $_.ready -eq 'True' }
    ).Count
    $schedulableLonghornNodeCount = @(
        $longhornNodes |
            Where-Object {
                $_.allowScheduling -and
                ($_.schedulable -eq 'True' -or [string]::IsNullOrWhiteSpace([string]$_.schedulable))
            }
    ).Count

    $criticalNamespaces = @(
        'cattle-system',
        'harvester-system',
        'kube-system',
        'longhorn-system'
    )
    $criticalUnhealthyPods = @(
        $pods |
            Where-Object {
                $_.namespace -in $criticalNamespaces -and
                ($_.phase -notin @('Running', 'Succeeded') -or
                 ($_.phase -eq 'Running' -and $_.ready -ne 'True'))
            }
    )
    $unhealthyDeployments = @(
        $deployments |
            Where-Object {
                $_.desired -gt 0 -and
                ($_.available -lt $_.desired -or $_.ready -lt $_.desired)
            }
    )

    $expectedNames = @('sen1', 'sen2', 'sen3')
    $actualNames = @($nodes | ForEach-Object { $_.name } | Sort-Object)
    $nodeDifference = @(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames)
    if ($nodes.Count -ne 3 -or $nodeDifference.Count -gt 0) {
        throw "Kubernetes node inventory is [$($actualNames -join ', ')]; expected exactly [sen1, sen2, sen3]."
    }
    if ($readyNodeCount -ne 3) {
        throw "Only $readyNodeCount of 3 Kubernetes nodes are Ready."
    }
    if (@($kubevirtItems | Where-Object { $_.available -eq 'True' }).Count -lt 1) {
        throw 'KubeVirt is not reporting Available=True.'
    }
    if ($readyVirtHandlerCount -lt 3) {
        throw "Only $readyVirtHandlerCount virt-handler pods are Running and Ready; expected at least 3."
    }
    if ($readyLonghornNodeCount -lt 3) {
        throw "Only $readyLonghornNodeCount Longhorn nodes report Ready=True; expected 3."
    }
    if ($schedulableLonghornNodeCount -lt 3) {
        throw "Only $schedulableLonghornNodeCount Longhorn nodes are schedulable; expected 3."
    }
    if ($criticalUnhealthyPods.Count -gt 0) {
        throw "$($criticalUnhealthyPods.Count) critical-system pods are not healthy."
    }
    if ($unhealthyDeployments.Count -gt 0) {
        throw "$($unhealthyDeployments.Count) deployments have fewer available replicas than desired."
    }

    $passed = $true
}
catch {
    $failure = $_.Exception.Message
    throw
}
finally {
    $finishedAt = (Get-Date).ToUniversalTime()
    $evidence = [ordered]@{
        schemaVersion = '3.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        clusterUrl = $ClusterUrl
        transport = [ordered]@{
            implementation = 'curl.exe'
            version = $curlVersion
            tlsCertificateVerification = 'disabled-for-self-signed-lab-endpoint'
            httpVersion = 'HTTP/1.1'
            rootStatusCode = $rootStatusCode
        }
        authenticated = $authenticated
        authenticatedUser = $authenticatedUser
        loginAttemptCount = $loginAttemptCount
        credentialValuesRetained = $false
        passed = $passed
        failure = $failure
        rancherSettings = $settings
        kubernetesVersion = $kubernetesVersion
        nodeCount = $nodes.Count
        readyNodeCount = $readyNodeCount
        nodes = $nodes
        podCounts = @($pods | Group-Object phase | ForEach-Object {
            [ordered]@{
                phase = $_.Name
                count = $_.Count
            }
        })
        criticalUnhealthyPods = $criticalUnhealthyPods
        deploymentCount = $deployments.Count
        unhealthyDeployments = $unhealthyDeployments
        storageClasses = $storageClasses
        kubevirt = $kubevirtItems
        virtHandlers = $virtHandlers
        readyVirtHandlerCount = $readyVirtHandlerCount
        longhornNodes = $longhornNodes
        readyLonghornNodeCount = $readyLonghornNodeCount
        schedulableLonghornNodeCount = $schedulableLonghornNodeCount
        installationApiQualified = $passed
        workloadQualified = $false
        productionReleaseApproved = $false
        trueAirgapQualified = $false
        haQualified = $false
        upgradeQualified = $false
        backupRestoreQualified = $false
    }
    $evidence | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry Harvester API validation

- Cluster URL: $ClusterUrl
- Transport: curl.exe over HTTP/1.1 with lab certificate verification disabled
- Root HTTP status: $rootStatusCode
- Authentication succeeded: $authenticated
- Authenticated user: $authenticatedUser
- Kubernetes nodes: $($nodes.Count)
- Ready nodes: $readyNodeCount
- Ready virt-handler pods: $readyVirtHandlerCount
- Ready Longhorn nodes: $readyLonghornNodeCount
- Schedulable Longhorn nodes: $schedulableLonghornNodeCount
- Installation/API qualification passed: $passed
- Workload qualification: **false**
- Production release approved: **false**
- True air-gap qualified: **false**
- HA qualified: **false**
- Upgrade qualified: **false**
- Backup/restore qualified: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8

    if (Test-Path -LiteralPath $transportDirectory) {
        Remove-Item -LiteralPath $transportDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $token = $null
    $passwordCandidates = @()
    $credentials = $null
}
