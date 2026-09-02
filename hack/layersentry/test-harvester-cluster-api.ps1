[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-harvester-api-validation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Credential file is missing: $CredentialPath"
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$ResultPath = Join-Path $OutputDirectory 'cluster-api-validation.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Failure = $null
$Passed = $false
$LoginUser = $null
$Token = $null

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

$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$password = Get-PropertyValue -Object $credentials -Names @(
    'nodePassword',
    'NodePassword',
    'password',
    'Password',
    'rancherPassword',
    'RancherPassword'
)
if ([string]::IsNullOrWhiteSpace($password)) {
    throw 'No node/Rancher password was found in the protected local credential file.'
}

$credentialAcl = Get-Acl -LiteralPath $CredentialPath
$unexpectedCredentialAccess = @($credentialAcl.Access | Where-Object {
    $_.AccessControlType -eq 'Allow' -and
    $_.IdentityReference.Value -notmatch 'SYSTEM$|Administrators$' -and
    ($_.FileSystemRights.ToString() -match 'Read|FullControl|Modify')
})
if ($unexpectedCredentialAccess.Count -gt 0) {
    throw 'The local bootstrap credential file grants read access outside SYSTEM/Administrators.'
}

$previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [int]$TimeoutSeconds = 30,
        [switch]$AllowHttpError
    )

    $headers = @{
        Accept = 'application/json'
        'User-Agent' = 'LayerSentry-Cluster-Validation/1.0'
    }
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $headers.Authorization = "Bearer $BearerToken"
    }
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        UseBasicParsing = $true
        TimeoutSec = $TimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json'
        $parameters.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    try {
        $response = Invoke-WebRequest @parameters
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
            $value = $response.Content | ConvertFrom-Json
        }
        return [pscustomobject]@{
            statusCode = [int]$response.StatusCode
            headers = $response.Headers
            body = $value
            error = $null
        }
    }
    catch [System.Net.WebException] {
        $exception = $_.Exception
        $statusCode = $null
        $responseText = $null
        if ($null -ne $exception.Response) {
            $statusCode = [int]$exception.Response.StatusCode
            $stream = $exception.Response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    $responseText = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                    $stream.Dispose()
                }
            }
        }
        if (-not $AllowHttpError) {
            throw "HTTP $Method $Uri failed with status $statusCode: $($exception.Message)"
        }
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace($responseText)) {
            try { $value = $responseText | ConvertFrom-Json } catch { $value = $null }
        }
        return [pscustomobject]@{
            statusCode = $statusCode
            headers = $null
            body = $value
            error = $exception.Message
        }
    }
}

function Get-CollectionItems {
    param([object]$Body)
    if ($null -eq $Body) { return @() }
    if ($Body.PSObject.Properties['items']) { return @($Body.items) }
    if ($Body.PSObject.Properties['data']) { return @($Body.data) }
    return @()
}

function Get-ConditionStatus {
    param(
        [object[]]$Conditions,
        [Parameter(Mandatory = $true)][string]$Type
    )
    $condition = @($Conditions | Where-Object { [string]$_.type -eq $Type } | Select-Object -Last 1)
    if ($condition.Count -eq 0) { return $null }
    return [string]$condition[0].status
}

function Convert-KubernetesNodeSummary {
    param([Parameter(Mandatory = $true)][object]$Node)
    $conditions = @($Node.status.conditions)
    $labels = $Node.metadata.labels
    $addresses = @($Node.status.addresses | ForEach-Object {
        [ordered]@{ type = [string]$_.type; address = [string]$_.address }
    })
    return [ordered]@{
        name = [string]$Node.metadata.name
        uid = [string]$Node.metadata.uid
        creationTimestamp = [string]$Node.metadata.creationTimestamp
        ready = (Get-ConditionStatus -Conditions $conditions -Type 'Ready')
        memoryPressure = (Get-ConditionStatus -Conditions $conditions -Type 'MemoryPressure')
        diskPressure = (Get-ConditionStatus -Conditions $conditions -Type 'DiskPressure')
        pidPressure = (Get-ConditionStatus -Conditions $conditions -Type 'PIDPressure')
        networkUnavailable = (Get-ConditionStatus -Conditions $conditions -Type 'NetworkUnavailable')
        addresses = $addresses
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
            kubeProxyVersion = [string]$Node.status.nodeInfo.kubeProxyVersion
        }
        roles = @($labels.PSObject.Properties |
            Where-Object { $_.Name -like 'node-role.kubernetes.io/*' } |
            ForEach-Object { $_.Name.Substring('node-role.kubernetes.io/'.Length) } |
            Sort-Object)
        kubevirtSchedulable = if ($labels.PSObject.Properties['kubevirt.io/schedulable']) {
            [string]$labels.'kubevirt.io/schedulable'
        } else { $null }
        cpuVendor = if ($labels.PSObject.Properties['cpu-feature.node.kubevirt.io/vmx']) {
            'vmx'
        } elseif ($labels.PSObject.Properties['cpu-feature.node.kubevirt.io/svm']) {
            'svm'
        } else { $null }
        taints = @($Node.spec.taints | ForEach-Object {
            [ordered]@{
                key = [string]$_.key
                value = [string]$_.value
                effect = [string]$_.effect
            }
        })
    }
}

function Convert-DeploymentSummary {
    param([Parameter(Mandatory = $true)][object]$Deployment)
    return [ordered]@{
        namespace = [string]$Deployment.metadata.namespace
        name = [string]$Deployment.metadata.name
        desired = [int]$Deployment.spec.replicas
        updated = [int]$Deployment.status.updatedReplicas
        ready = [int]$Deployment.status.readyReplicas
        available = [int]$Deployment.status.availableReplicas
        unavailable = [int]$Deployment.status.unavailableReplicas
    }
}

function Convert-PodSummary {
    param([Parameter(Mandatory = $true)][object]$Pod)
    $containerStatuses = @($Pod.status.containerStatuses)
    $notReady = @($containerStatuses | Where-Object { -not [bool]$_.ready } | ForEach-Object {
        [ordered]@{
            name = [string]$_.name
            restartCount = [int]$_.restartCount
            waitingReason = if ($null -ne $_.state.waiting) { [string]$_.state.waiting.reason } else { $null }
            terminatedReason = if ($null -ne $_.state.terminated) { [string]$_.state.terminated.reason } else { $null }
        }
    })
    return [ordered]@{
        namespace = [string]$Pod.metadata.namespace
        name = [string]$Pod.metadata.name
        nodeName = [string]$Pod.spec.nodeName
        phase = [string]$Pod.status.phase
        readyCondition = (Get-ConditionStatus -Conditions @($Pod.status.conditions) -Type 'Ready')
        notReadyContainers = $notReady
        totalRestarts = [int](($containerStatuses | Measure-Object -Property restartCount -Sum).Sum)
    }
}

try {
    $root = Invoke-JsonRequest -Method GET -Uri "$ClusterUrl/" -AllowHttpError
    if ($null -eq $root.statusCode) {
        throw "Cluster HTTPS endpoint is not reachable: $($root.error)"
    }

    foreach ($candidateUser in @('admin', 'rancher')) {
        $loginBody = [ordered]@{
            username = $candidateUser
            password = $password
            responseType = 'token'
        }
        $login = Invoke-JsonRequest `
            -Method POST `
            -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
            -Body $loginBody `
            -AllowHttpError
        if ($login.statusCode -ge 200 -and $login.statusCode -lt 300 -and $null -ne $login.body) {
            $candidateToken = Get-PropertyValue -Object $login.body -Names @('token')
            if (-not [string]::IsNullOrWhiteSpace($candidateToken)) {
                $LoginUser = $candidateUser
                $Token = $candidateToken
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'Harvester/Rancher local authentication failed for the reviewed admin usernames.'
    }

    $proxy = "$ClusterUrl/k8s/clusters/local"
    $versionResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/version" -BearerToken $Token
    $nodesResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/api/v1/nodes" -BearerToken $Token
    $podsResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/api/v1/pods?limit=1000" -BearerToken $Token -TimeoutSeconds 60
    $deploymentsResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/apis/apps/v1/deployments?limit=1000" -BearerToken $Token -TimeoutSeconds 60
    $storageClassesResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/apis/storage.k8s.io/v1/storageclasses" -BearerToken $Token
    $kubevirtResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/apis/kubevirt.io/v1/namespaces/harvester-system/kubevirts" -BearerToken $Token -AllowHttpError
    $virtHandlersResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/api/v1/namespaces/harvester-system/pods?labelSelector=kubevirt.io%2B%3Dvirt-handler" -BearerToken $Token -AllowHttpError
    $longhornNodesResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes" -BearerToken $Token -AllowHttpError
    $harvesterSettingsResponse = Invoke-JsonRequest -Method GET -Uri "$proxy/apis/harvesterhci.io/v1beta1/settings" -BearerToken $Token -AllowHttpError

    $nodes = @(Get-CollectionItems -Body $nodesResponse.body | ForEach-Object {
        Convert-KubernetesNodeSummary -Node $_
    })
    $pods = @(Get-CollectionItems -Body $podsResponse.body | ForEach-Object {
        Convert-PodSummary -Pod $_
    })
    $deployments = @(Get-CollectionItems -Body $deploymentsResponse.body | ForEach-Object {
        Convert-DeploymentSummary -Deployment $_
    })
    $storageClasses = @(Get-CollectionItems -Body $storageClassesResponse.body | ForEach-Object {
        [ordered]@{
            name = [string]$_.metadata.name
            provisioner = [string]$_.provisioner
            reclaimPolicy = [string]$_.reclaimPolicy
            volumeBindingMode = [string]$_.volumeBindingMode
            allowVolumeExpansion = [bool]$_.allowVolumeExpansion
            isDefault = ([string]$_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true')
        }
    })
    $kubevirts = @(Get-CollectionItems -Body $kubevirtResponse.body | ForEach-Object {
        [ordered]@{
            namespace = [string]$_.metadata.namespace
            name = [string]$_.metadata.name
            phase = [string]$_.status.phase
            observedGeneration = [int64]$_.status.observedGeneration
            conditions = @($_.status.conditions | ForEach-Object {
                [ordered]@{
                    type = [string]$_.type
                    status = [string]$_.status
                    reason = [string]$_.reason
                    message = [string]$_.message
                }
            })
        }
    })
    $virtHandlers = @(Get-CollectionItems -Body $virtHandlersResponse.body | ForEach-Object {
        Convert-PodSummary -Pod $_
    })
    $longhornNodes = @(Get-CollectionItems -Body $longhornNodesResponse.body | ForEach-Object {
        [ordered]@{
            name = [string]$_.metadata.name
            allowScheduling = [bool]$_.spec.allowScheduling
            ready = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Ready')
            schedulable = (Get-ConditionStatus -Conditions @($_.status.conditions) -Type 'Schedulable')
            diskStatus = @($_.status.diskStatus.PSObject.Properties | ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    storageAvailable = [int64]$_.Value.storageAvailable
                    storageMaximum = [int64]$_.Value.storageMaximum
                    scheduledReplica = [int64]$_.Value.storageScheduled
                    conditions = @($_.Value.conditions | ForEach-Object {
                        [ordered]@{
                            type = [string]$_.type
                            status = [string]$_.status
                            reason = [string]$_.reason
                        }
                    })
                }
            })
        }
    })

    $safeSettings = @()
    foreach ($setting in @(Get-CollectionItems -Body $harvesterSettingsResponse.body)) {
        $name = [string]$setting.metadata.name
        if ($name -in @(
            'server-version',
            'upgrade-checker-enabled',
            'support-bundle-timeout',
            'default-vm-termination-grace-period-seconds',
            'overcommit-config',
            'storage-network',
            'vip-pools'
        )) {
            $safeSettings += [ordered]@{
                name = $name
                value = [string]$setting.value
                default = [string]$setting.default
            }
        }
    }

    $unhealthyDeployments = @($deployments | Where-Object {
        $_.desired -gt 0 -and ($_.available -lt $_.desired -or $_.ready -lt $_.desired)
    })
    $unhealthyPods = @($pods | Where-Object {
        $_.phase -notin @('Running', 'Succeeded') -or
        ($_.phase -eq 'Running' -and $_.readyCondition -ne 'True')
    })
    $readyNodeCount = @($nodes | Where-Object { $_.ready -eq 'True' }).Count
    $kubevirtAvailable = @($kubevirts | Where-Object {
        @($_.conditions | Where-Object { $_.type -eq 'Available' -and $_.status -eq 'True' }).Count -gt 0
    }).Count -gt 0
    $readyVirtHandlerCount = @($virtHandlers | Where-Object {
        $_.phase -eq 'Running' -and $_.readyCondition -eq 'True'
    }).Count
    $readyLonghornNodeCount = @($longhornNodes | Where-Object { $_.ready -eq 'True' }).Count
    $schedulableLonghornNodeCount = @($longhornNodes | Where-Object {
        $_.allowScheduling -and ($_.schedulable -eq 'True' -or $null -eq $_.schedulable)
    }).Count

    $criticalNamespaces = @(
        'cattle-system',
        'harvester-system',
        'kube-system',
        'longhorn-system'
    )
    $criticalUnhealthyPods = @($unhealthyPods | Where-Object {
        $_.namespace -in $criticalNamespaces
    })

    if ($nodes.Count -ne 3) {
        throw "Kubernetes reports $($nodes.Count) nodes; expected exactly 3."
    }
    if ($readyNodeCount -ne 3) {
        throw "Only $readyNodeCount of 3 Kubernetes nodes are Ready."
    }
    if (-not $kubevirtAvailable) {
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
        throw "$($criticalUnhealthyPods.Count) critical-system pods are not Running/Succeeded and Ready."
    }
    if ($unhealthyDeployments.Count -gt 0) {
        throw "$($unhealthyDeployments.Count) deployments have fewer available replicas than desired."
    }

    $Passed = $true
}
catch {
    $Failure = $_.Exception.Message
    throw
}
finally {
    $finished = (Get-Date).ToUniversalTime()
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        clusterUrl = $ClusterUrl
        authenticated = -not [string]::IsNullOrWhiteSpace($Token)
        authenticatedUser = $LoginUser
        credentialValuesRetained = $false
        passed = $Passed
        failure = $Failure
        kubernetesVersion = if ($null -ne $versionResponse) { $versionResponse.body } else { $null }
        nodeCount = if ($null -ne $nodes) { $nodes.Count } else { 0 }
        readyNodeCount = if ($null -ne $readyNodeCount) { $readyNodeCount } else { 0 }
        nodes = if ($null -ne $nodes) { $nodes } else { @() }
        podCounts = if ($null -ne $pods) {
            @($pods | Group-Object phase | ForEach-Object {
                [ordered]@{ phase = $_.Name; count = $_.Count }
            })
        } else { @() }
        unhealthyPods = if ($null -ne $unhealthyPods) { $unhealthyPods } else { @() }
        deploymentCount = if ($null -ne $deployments) { $deployments.Count } else { 0 }
        unhealthyDeployments = if ($null -ne $unhealthyDeployments) { $unhealthyDeployments } else { @() }
        storageClasses = if ($null -ne $storageClasses) { $storageClasses } else { @() }
        kubevirt = if ($null -ne $kubevirts) { $kubevirts } else { @() }
        virtHandlers = if ($null -ne $virtHandlers) { $virtHandlers } else { @() }
        longhornNodes = if ($null -ne $longhornNodes) { $longhornNodes } else { @() }
        safeHarvesterSettings = if ($null -ne $safeSettings) { $safeSettings } else { @() }
        installationApiQualified = $Passed
        workloadQualified = $false
        productionReleaseApproved = $false
        trueAirgapQualified = $false
        haQualified = $false
        upgradeQualified = $false
        backupRestoreQualified = $false
    }
    $result | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry Harvester API validation

- Cluster URL: $ClusterUrl
- Authentication succeeded: $($result.authenticated)
- Authenticated user: $($result.authenticatedUser)
- Kubernetes nodes: $($result.nodeCount)
- Ready nodes: $($result.readyNodeCount)
- Deployments: $($result.deploymentCount)
- Installation/API qualification passed: $($result.installationApiQualified)
- Workload qualification: **false**
- Production release approved: **false**
- True air-gap qualified: **false**
- HA qualified: **false**
- Upgrade qualified: **false**
- Backup/restore qualified: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $Token = $null
    $password = $null
    $credentials = $null
}
