[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$Namespace = 'layersentry-validation',
    [string]$VmName = 'layersentry-smoke-vm',
    [string]$StoragePvcName = 'layersentry-storage-vm-disk',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-node-failure-recovery'),
    [ValidateRange(10, 90)]
    [int]$FailoverTimeoutMinutes = 35,
    [ValidateRange(10, 90)]
    [int]$RecoveryTimeoutMinutes = 35
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedHyperVNodes = @('sen1', 'sen2', 'sen3')
$ExpectedAddresses = [ordered]@{
    sen1 = '10.10.10.11'
    sen2 = '10.10.10.12'
    sen3 = '10.10.10.13'
}
$ClusterVip = ([uri]$ClusterUrl).Host

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Credential file is missing: $CredentialPath"
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$TimelinePath = Join-Path $OutputDirectory 'failure-recovery-timeline.jsonl'
$ResultPath = Join-Path $OutputDirectory 'failure-recovery-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Failure = $null
$Passed = $false
$Token = $null
$LoginUser = $null
$SourceNode = $null
$TargetNode = $null
$FailedHyperVVm = $null
$FailedNodeInternalIp = $null
$NodePort = $null
$OldVmiUid = $null
$NewVmiUid = $null
$FailoverObservedAt = $null
$FailedNodeNotReadyAt = $null
$NodePortOutageStartedAt = $null
$NodePortRecoveredAt = $null
$LonghornVolumeName = $null
$LonghornBefore = $null
$LonghornDuring = $null
$LonghornAfter = $null
$HyperVNodeStopped = $false
$FailedNodeRestarted = $false
$ReadyNodesDuringFailure = @()
$ReadyNodesAfterRecovery = @()
$VmiAfterFailover = $null
$VmiAfterRecovery = $null

function Write-Timeline {
    param([Parameter(Mandatory = $true)][object]$Record)
    $ordered = [ordered]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($property in $Record.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }
    ($ordered | ConvertTo-Json -Compress -Depth 25) |
        Add-Content -LiteralPath $TimelinePath -Encoding UTF8
}

function Get-PropertyValue {
    param([object]$Object, [string[]]$Names)
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

function Invoke-JsonRequest {
    param(
        [ValidateSet('GET','POST')][string]$Method,
        [string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [int]$TimeoutSeconds = 30,
        [switch]$AllowHttpError
    )

    $headers = @{ Accept = 'application/json'; 'User-Agent' = 'LayerSentry-HA-Validation/1.0' }
    if ($BearerToken) { $headers.Authorization = "Bearer $BearerToken" }
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
        $parameters.Body = ($Body | ConvertTo-Json -Depth 30 -Compress)
    }
    try {
        $response = Invoke-WebRequest @parameters
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
            $value = $response.Content | ConvertFrom-Json
        }
        return [pscustomobject]@{
            statusCode = [int]$response.StatusCode
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
                try { $responseText = $reader.ReadToEnd() }
                finally { $reader.Dispose(); $stream.Dispose() }
            }
        }
        if (-not $AllowHttpError) {
            $message = if ($responseText) { $responseText } else { $exception.Message }
            throw "HTTP $Method $Uri failed with status $statusCode: $message"
        }
        $value = $null
        if ($responseText) {
            try { $value = $responseText | ConvertFrom-Json } catch { $value = $null }
        }
        return [pscustomobject]@{
            statusCode = $statusCode
            body = $value
            error = $exception.Message
        }
    }
}

function Test-TcpPort {
    param([string]$Address, [int]$Port, [int]$TimeoutMilliseconds = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Test-ClusterVip {
    return (Test-TcpPort -Address $ClusterVip -Port 443 -TimeoutMilliseconds 1500) -or
        (Test-TcpPort -Address $ClusterVip -Port 6443 -TimeoutMilliseconds 1500)
}

function Get-NodeReadyStatus {
    param([object]$Node)
    $condition = @($Node.status.conditions |
        Where-Object { [string]$_.type -eq 'Ready' } |
        Select-Object -Last 1)
    if ($condition.Count -eq 0) { return $null }
    return [string]$condition[0].status
}

function Get-VmiReadyStatus {
    param([object]$Vmi)
    $condition = @($Vmi.status.conditions |
        Where-Object { [string]$_.type -eq 'Ready' } |
        Select-Object -Last 1)
    if ($condition.Count -eq 0) { return $null }
    return [string]$condition[0].status
}

function Get-InternalIp {
    param([object]$Node)
    $address = @($Node.status.addresses |
        Where-Object { [string]$_.type -eq 'InternalIP' } |
        Select-Object -First 1)
    if ($address.Count -eq 0) { return $null }
    return [string]$address[0].address
}

function Get-ReachableNodePorts {
    param([int]$Port)
    $reachable = @()
    foreach ($name in $ExpectedHyperVNodes) {
        $address = $ExpectedAddresses[$name]
        if (Test-TcpPort -Address $address -Port $Port -TimeoutMilliseconds 1500) {
            $reachable += $address
        }
    }
    return @($reachable)
}

function Get-ClusterSnapshot {
    param(
        [string]$Proxy,
        [string]$Bearer,
        [string]$VmiUri,
        [int]$ServiceNodePort,
        [string]$LonghornUri
    )

    $nodesResponse = Invoke-JsonRequest -Method GET -Uri "$Proxy/api/v1/nodes" -BearerToken $Bearer -AllowHttpError
    $vmiResponse = Invoke-JsonRequest -Method GET -Uri $VmiUri -BearerToken $Bearer -AllowHttpError
    $longhornResponse = if ($LonghornUri) {
        Invoke-JsonRequest -Method GET -Uri $LonghornUri -BearerToken $Bearer -AllowHttpError
    } else { $null }

    $nodes = if ($nodesResponse.statusCode -ge 200 -and $nodesResponse.statusCode -lt 300) {
        @($nodesResponse.body.items)
    } else { @() }
    $readyNodes = @($nodes | Where-Object { (Get-NodeReadyStatus -Node $_) -eq 'True' } |
        ForEach-Object { [string]$_.metadata.name })
    $notReadyNodes = @($nodes | Where-Object { (Get-NodeReadyStatus -Node $_) -ne 'True' } |
        ForEach-Object { [string]$_.metadata.name })
    $vmi = if ($vmiResponse.statusCode -ge 200 -and $vmiResponse.statusCode -lt 300) {
        $vmiResponse.body
    } else { $null }
    $longhorn = if ($null -ne $longhornResponse -and
        $longhornResponse.statusCode -ge 200 -and $longhornResponse.statusCode -lt 300) {
        $longhornResponse.body
    } else { $null }

    return [pscustomobject]@{
        apiReachable = $nodes.Count -gt 0
        nodes = $nodes
        readyNodes = $readyNodes
        notReadyNodes = $notReadyNodes
        vmi = $vmi
        vmiUid = if ($null -ne $vmi) { [string]$vmi.metadata.uid } else { $null }
        vmiNode = if ($null -ne $vmi) { [string]$vmi.status.nodeName } else { $null }
        vmiPhase = if ($null -ne $vmi) { [string]$vmi.status.phase } else { $null }
        vmiReady = if ($null -ne $vmi) { Get-VmiReadyStatus -Vmi $vmi } else { $null }
        reachableNodePorts = Get-ReachableNodePorts -Port $ServiceNodePort
        vipReachable = Test-ClusterVip
        longhorn = $longhorn
        longhornState = if ($null -ne $longhorn) { [string]$longhorn.status.state } else { $null }
        longhornRobustness = if ($null -ne $longhorn) { [string]$longhorn.status.robustness } else { $null }
        longhornReplicaCount = if ($null -ne $longhorn) { [int]$longhorn.spec.numberOfReplicas } else { $null }
    }
}

function Convert-LonghornSummary {
    param([object]$Volume)
    if ($null -eq $Volume) { return $null }
    return [ordered]@{
        name = [string]$Volume.metadata.name
        state = [string]$Volume.status.state
        robustness = [string]$Volume.status.robustness
        currentNodeId = [string]$Volume.status.currentNodeID
        ownerId = [string]$Volume.status.ownerID
        numberOfReplicas = [int]$Volume.spec.numberOfReplicas
        sizeBytes = [int64]$Volume.spec.size
    }
}

foreach ($name in $ExpectedHyperVNodes) {
    $vm = Get-VM -Name $name -ErrorAction Stop
    if ($vm.State -ne 'Running') {
        throw "$name must be Running before the controlled failure test."
    }
    $processor = Get-VMProcessor -VMName $name -ErrorAction Stop
    if ($processor.Count -ne 10 -or -not [bool]$processor.ExposeVirtualizationExtensions) {
        throw "$name does not match the approved 10-vCPU nested-virtualization design."
    }
    if ([int64]$vm.MemoryStartup -ne 32GB -or [bool]$vm.DynamicMemoryEnabled) {
        throw "$name does not match the approved 32-GiB static-memory design."
    }
}

$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$password = Get-PropertyValue -Object $credentials -Names @(
    'nodePassword','NodePassword','password','Password','rancherPassword','RancherPassword'
)
if (-not $password) { throw 'No node/Rancher password was found in the protected credential file.' }

$previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

try {
    foreach ($candidateUser in @('admin','rancher')) {
        $login = Invoke-JsonRequest -Method POST `
            -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
            -Body ([ordered]@{ username = $candidateUser; password = $password; responseType = 'token' }) `
            -AllowHttpError
        if ($login.statusCode -ge 200 -and $login.statusCode -lt 300 -and $null -ne $login.body) {
            $candidateToken = Get-PropertyValue -Object $login.body -Names @('token')
            if ($candidateToken) { $Token = $candidateToken; $LoginUser = $candidateUser; break }
        }
    }
    if (-not $Token) { throw 'Harvester/Rancher authentication failed.' }

    $proxy = "$ClusterUrl/k8s/clusters/local"
    $vmiUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$VmName"
    $serviceUri = "$proxy/api/v1/namespaces/$Namespace/services/$VmName-ssh"
    $pvcUri = "$proxy/api/v1/namespaces/$Namespace/persistentvolumeclaims/$StoragePvcName"

    $nodes = @((Invoke-JsonRequest -Method GET -Uri "$proxy/api/v1/nodes" -BearerToken $Token).body.items)
    if ($nodes.Count -ne 3) { throw "Kubernetes reports $($nodes.Count) nodes; expected 3." }
    $readyNodes = @($nodes | Where-Object { (Get-NodeReadyStatus -Node $_) -eq 'True' })
    if ($readyNodes.Count -ne 3) { throw "Only $($readyNodes.Count) Kubernetes nodes are Ready before the test." }

    $vmiBefore = (Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token).body
    if ([string]$vmiBefore.status.phase -ne 'Running' -or (Get-VmiReadyStatus -Vmi $vmiBefore) -ne 'True') {
        throw 'The retained validation VMI is not Running and Ready before the test.'
    }
    $SourceNode = [string]$vmiBefore.status.nodeName
    $OldVmiUid = [string]$vmiBefore.metadata.uid
    if ([string]::IsNullOrWhiteSpace($SourceNode)) { throw 'The retained validation VMI has no source node.' }

    $service = (Invoke-JsonRequest -Method GET -Uri $serviceUri -BearerToken $Token).body
    if (@($service.spec.ports).Count -ne 1 -or $null -eq $service.spec.ports[0].nodePort) {
        throw 'The retained validation VM service has no single NodePort.'
    }
    $NodePort = [int]$service.spec.ports[0].nodePort
    if ((Get-ReachableNodePorts -Port $NodePort).Count -eq 0) {
        throw 'The retained validation guest is unreachable before the failure test.'
    }

    $sourceNodeObject = @($nodes | Where-Object { [string]$_.metadata.name -eq $SourceNode })
    if ($sourceNodeObject.Count -ne 1) {
        throw "Could not resolve exactly one Kubernetes node object for '$SourceNode'."
    }
    $FailedNodeInternalIp = Get-InternalIp -Node $sourceNodeObject[0]
    $FailedHyperVVm = $null
    foreach ($entry in $ExpectedAddresses.GetEnumerator()) {
        if ([string]$entry.Value -eq $FailedNodeInternalIp) {
            $FailedHyperVVm = [string]$entry.Key
            break
        }
    }
    if (-not $FailedHyperVVm) {
        if ($ExpectedHyperVNodes -contains $SourceNode) {
            $FailedHyperVVm = $SourceNode
        }
        else {
            throw "Could not map Kubernetes node '$SourceNode'/$FailedNodeInternalIp to sen1, sen2, or sen3."
        }
    }

    $pvcResponse = Invoke-JsonRequest -Method GET -Uri $pvcUri -BearerToken $Token -AllowHttpError
    $longhornUri = $null
    if ($pvcResponse.statusCode -ge 200 -and $pvcResponse.statusCode -lt 300) {
        $pvName = [string]$pvcResponse.body.spec.volumeName
        if ($pvName) {
            $pv = (Invoke-JsonRequest -Method GET -Uri "$proxy/api/v1/persistentvolumes/$pvName" -BearerToken $Token).body
            $LonghornVolumeName = [string]$pv.spec.csi.volumeHandle
            if ($LonghornVolumeName) {
                $longhornUri = "$proxy/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes/$LonghornVolumeName"
                $longhornResponse = Invoke-JsonRequest -Method GET -Uri $longhornUri -BearerToken $Token -AllowHttpError
                if ($longhornResponse.statusCode -ge 200 -and $longhornResponse.statusCode -lt 300) {
                    $LonghornBefore = $longhornResponse.body
                }
            }
        }
    }

    Write-Timeline -Record ([pscustomobject]@{
        event = 'preflight-pass'
        sourceNode = $SourceNode
        sourceInternalIp = $FailedNodeInternalIp
        failedHyperVVm = $FailedHyperVVm
        oldVmiUid = $OldVmiUid
        serviceNodePort = $NodePort
        vipReachable = Test-ClusterVip
        longhornVolume = $LonghornVolumeName
        longhornRobustness = if ($LonghornBefore) { [string]$LonghornBefore.status.robustness } else { $null }
    })

    Stop-VM -Name $FailedHyperVVm -TurnOff -Force -ErrorAction Stop
    $HyperVNodeStopped = $true
    Write-Timeline -Record ([pscustomobject]@{
        event = 'hyperv-node-powered-off'
        hyperVVm = $FailedHyperVVm
        kubernetesNode = $SourceNode
    })

    $failoverDeadline = (Get-Date).ToUniversalTime().AddMinutes($FailoverTimeoutMinutes)
    do {
        $snapshot = Get-ClusterSnapshot -Proxy $proxy -Bearer $Token -VmiUri $vmiUri `
            -ServiceNodePort $NodePort -LonghornUri $longhornUri
        $failedNodeObject = @($snapshot.nodes | Where-Object { [string]$_.metadata.name -eq $SourceNode })
        $failedNodeReady = if ($failedNodeObject.Count -eq 1) { Get-NodeReadyStatus -Node $failedNodeObject[0] } else { 'Absent' }

        if ($failedNodeReady -ne 'True' -and $null -eq $FailedNodeNotReadyAt) {
            $FailedNodeNotReadyAt = (Get-Date).ToUniversalTime()
        }
        if ($snapshot.reachableNodePorts.Count -eq 0 -and $null -eq $NodePortOutageStartedAt) {
            $NodePortOutageStartedAt = (Get-Date).ToUniversalTime()
        }
        if ($snapshot.reachableNodePorts.Count -gt 0 -and $null -ne $NodePortOutageStartedAt -and $null -eq $NodePortRecoveredAt) {
            $NodePortRecoveredAt = (Get-Date).ToUniversalTime()
        }
        if ($snapshot.longhorn) { $LonghornDuring = $snapshot.longhorn }

        Write-Timeline -Record ([pscustomobject]@{
            event = 'failover-probe'
            vipReachable = $snapshot.vipReachable
            readyNodes = $snapshot.readyNodes
            notReadyNodes = $snapshot.notReadyNodes
            failedNodeReady = $failedNodeReady
            vmiUid = $snapshot.vmiUid
            vmiNode = $snapshot.vmiNode
            vmiPhase = $snapshot.vmiPhase
            vmiReady = $snapshot.vmiReady
            reachableNodePorts = $snapshot.reachableNodePorts
            longhornState = $snapshot.longhornState
            longhornRobustness = $snapshot.longhornRobustness
        })

        if (-not $snapshot.vipReachable) {
            # A short control-plane VIP transition is expected; it becomes a
            # failure only if the deadline expires without recovery.
        }
        if ($snapshot.longhornRobustness -eq 'faulted') {
            throw 'The retained Longhorn validation volume became faulted during one-node failure.'
        }

        if ($failedNodeReady -ne 'True' -and
            $snapshot.readyNodes.Count -ge 2 -and
            $snapshot.vipReachable -and
            $snapshot.vmiPhase -eq 'Running' -and
            $snapshot.vmiReady -eq 'True' -and
            $snapshot.vmiNode -and
            $snapshot.vmiNode -ne $SourceNode -and
            $snapshot.reachableNodePorts.Count -gt 0) {
            $TargetNode = [string]$snapshot.vmiNode
            $NewVmiUid = [string]$snapshot.vmiUid
            $VmiAfterFailover = $snapshot.vmi
            $ReadyNodesDuringFailure = @($snapshot.readyNodes)
            $FailoverObservedAt = (Get-Date).ToUniversalTime()
            if ($null -eq $NodePortRecoveredAt) { $NodePortRecoveredAt = $FailoverObservedAt }
            break
        }

        if ((Get-Date).ToUniversalTime() -ge $failoverDeadline) {
            throw "Guest failover did not complete within $FailoverTimeoutMinutes minutes after stopping $FailedHyperVVm."
        }
        Start-Sleep -Seconds 10
    } while ($true)

    Start-VM -Name $FailedHyperVVm -ErrorAction Stop | Out-Null
    $FailedNodeRestarted = $true
    Write-Timeline -Record ([pscustomobject]@{
        event = 'hyperv-node-restarted'
        hyperVVm = $FailedHyperVVm
        targetGuestNode = $TargetNode
    })

    $recoveryDeadline = (Get-Date).ToUniversalTime().AddMinutes($RecoveryTimeoutMinutes)
    do {
        $snapshot = Get-ClusterSnapshot -Proxy $proxy -Bearer $Token -VmiUri $vmiUri `
            -ServiceNodePort $NodePort -LonghornUri $longhornUri
        if ($snapshot.longhorn) { $LonghornAfter = $snapshot.longhorn }
        Write-Timeline -Record ([pscustomobject]@{
            event = 'recovery-probe'
            vipReachable = $snapshot.vipReachable
            readyNodes = $snapshot.readyNodes
            notReadyNodes = $snapshot.notReadyNodes
            vmiUid = $snapshot.vmiUid
            vmiNode = $snapshot.vmiNode
            vmiPhase = $snapshot.vmiPhase
            vmiReady = $snapshot.vmiReady
            reachableNodePorts = $snapshot.reachableNodePorts
            longhornState = $snapshot.longhornState
            longhornRobustness = $snapshot.longhornRobustness
        })

        $longhornRecovered = $true
        if ($longhornUri) {
            $longhornRecovered = $snapshot.longhornRobustness -eq 'healthy'
        }
        if ($snapshot.readyNodes.Count -eq 3 -and
            $snapshot.vipReachable -and
            $snapshot.vmiPhase -eq 'Running' -and
            $snapshot.vmiReady -eq 'True' -and
            $snapshot.reachableNodePorts.Count -gt 0 -and
            $longhornRecovered) {
            $ReadyNodesAfterRecovery = @($snapshot.readyNodes)
            $VmiAfterRecovery = $snapshot.vmi
            break
        }
        if ((Get-Date).ToUniversalTime() -ge $recoveryDeadline) {
            throw "All three nodes and Longhorn did not recover within $RecoveryTimeoutMinutes minutes."
        }
        Start-Sleep -Seconds 10
    } while ($true)

    if ($TargetNode -eq $SourceNode) {
        throw 'The validation guest did not move to a different node during the outage.'
    }
    if ($ReadyNodesDuringFailure.Count -lt 2) {
        throw 'Fewer than two Kubernetes nodes remained Ready during the controlled failure.'
    }
    if ($ReadyNodesAfterRecovery.Count -ne 3) {
        throw 'The cluster did not return to three Ready Kubernetes nodes.'
    }
    $Passed = $true
}
catch {
    $Failure = $_.Exception.Message
    Write-Timeline -Record ([pscustomobject]@{ event = 'failure'; error = $Failure })
    throw
}
finally {
    if ($HyperVNodeStopped -and -not $FailedNodeRestarted -and $FailedHyperVVm) {
        try {
            $vm = Get-VM -Name $FailedHyperVVm -ErrorAction Stop
            if ($vm.State -eq 'Off') {
                Start-VM -Name $FailedHyperVVm -ErrorAction Stop | Out-Null
            }
            $FailedNodeRestarted = $true
            Write-Timeline -Record ([pscustomobject]@{
                event = 'finally-node-restarted'
                hyperVVm = $FailedHyperVVm
            })
        }
        catch {
            Write-Timeline -Record ([pscustomobject]@{
                event = 'finally-node-restart-failed'
                hyperVVm = $FailedHyperVVm
                error = $_.Exception.Message
            })
        }
    }

    $finished = (Get-Date).ToUniversalTime()
    $outageSeconds = $null
    if ($NodePortOutageStartedAt -and $NodePortRecoveredAt) {
        $outageSeconds = [int64]($NodePortRecoveredAt - $NodePortOutageStartedAt).TotalSeconds
    }
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        authenticated = -not [string]::IsNullOrWhiteSpace($Token)
        authenticatedUser = $LoginUser
        credentialValuesRetained = $false
        namespace = $Namespace
        virtualMachine = $VmName
        serviceNodePort = $NodePort
        failedHyperVVm = $FailedHyperVVm
        failedKubernetesNode = $SourceNode
        failedNodeInternalIp = $FailedNodeInternalIp
        targetKubernetesNode = $TargetNode
        oldVmiUid = $OldVmiUid
        failoverVmiUid = $NewVmiUid
        vmiObjectRecreated = $OldVmiUid -and $NewVmiUid -and $OldVmiUid -ne $NewVmiUid
        failedNodeNotReadyAtUtc = if ($FailedNodeNotReadyAt) { $FailedNodeNotReadyAt.ToString('o') } else { $null }
        failoverObservedAtUtc = if ($FailoverObservedAt) { $FailoverObservedAt.ToString('o') } else { $null }
        guestServiceOutageSeconds = $outageSeconds
        readyNodesDuringFailure = $ReadyNodesDuringFailure
        readyNodesAfterRecovery = $ReadyNodesAfterRecovery
        longhornVolume = $LonghornVolumeName
        longhornBefore = Convert-LonghornSummary -Volume $LonghornBefore
        longhornDuringFailure = Convert-LonghornSummary -Volume $LonghornDuring
        longhornAfterRecovery = Convert-LonghornSummary -Volume $LonghornAfter
        failedNodeRestartAttempted = $HyperVNodeStopped
        failedNodeRestarted = $FailedNodeRestarted
        passed = $Passed
        failure = $Failure
        oneNodeControlPlaneSurvivalQualifiedInNestedPoc = $Passed
        guestVmFailureRecoveryQualifiedInNestedPoc = $Passed
        longhornSingleNodeSurvivalQualifiedInNestedPoc = $Passed -and ($null -eq $LonghornVolumeName -or $LonghornAfter.status.robustness -eq 'healthy')
        physicalHostHaQualified = $false
        productionReleaseApproved = $false
        trueAirgapQualified = $false
    }
    $result | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry controlled node-failure and recovery validation

- Failed Hyper-V VM: $FailedHyperVVm
- Failed Kubernetes node: $SourceNode
- Guest target node after failover: $TargetNode
- Ready nodes during failure: $($ReadyNodesDuringFailure -join ', ')
- Ready nodes after recovery: $($ReadyNodesAfterRecovery -join ', ')
- Guest service outage: $outageSeconds seconds
- Longhorn robustness during failure: $($result.longhornDuringFailure.robustness)
- Longhorn robustness after recovery: $($result.longhornAfterRecovery.robustness)
- Nested-POC node-failure recovery passed: $($result.passed)
- Physical-host HA qualified: **false**
- True air-gap qualified: **false**
- Production release approved: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $Token = $null
    $password = $null
    $credentials = $null
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
}
