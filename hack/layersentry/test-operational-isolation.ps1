[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$Namespace = 'layersentry-validation',
    [string]$ProbePodName = 'layersentry-egress-probe',
    [string]$NatPrefix = '10.10.10.0/24',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-operational-isolation'),
    [ValidateRange(5, 45)]
    [int]$TimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NodeAddresses = @('10.10.10.11','10.10.10.12','10.10.10.13')
$ClusterVip = ([uri]$ClusterUrl).Host

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Credential file is missing: $CredentialPath"
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$TimelinePath = Join-Path $OutputDirectory 'isolation-timeline.jsonl'
$ResultPath = Join-Path $OutputDirectory 'isolation-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Failure = $null
$Passed = $false
$Token = $null
$LoginUser = $null
$Proxy = $null
$ProbeImage = $null
$ProbeNode = $null
$PodCreated = $false
$NatRemoved = $false
$NatRestored = $false
$NatConfiguration = $null
$StaticMappings = @()
$EgressOkBefore = $false
$EgressBlockedDuring = $false
$EgressOkAfter = $false
$BlockedSamples = 0
$VipSurvived = $true
$AllNodesSurvived = $true
$ApiSurvived = $true
$LonghornHealthyDuring = $false
$KubeVirtAvailableDuring = $false

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
        [ValidateSet('GET','POST','DELETE')][string]$Method,
        [string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [int]$TimeoutSeconds = 30,
        [switch]$AllowHttpError
    )

    $headers = @{ Accept = 'application/json'; 'User-Agent' = 'LayerSentry-Isolation-Validation/1.0' }
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
            content = [string]$response.Content
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
            content = [string]$responseText
            body = $value
            error = $exception.Message
        }
    }
}

function Invoke-TextRequest {
    param(
        [string]$Uri,
        [string]$BearerToken,
        [switch]$AllowHttpError
    )
    $response = Invoke-JsonRequest -Method GET -Uri $Uri -BearerToken $BearerToken -AllowHttpError:$AllowHttpError
    return $response
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

function Test-Ping {
    param([string]$Address)
    try { return [bool](Test-Connection -ComputerName $Address -Count 1 -Quiet -ErrorAction Stop) }
    catch { return $false }
}

function Test-InternalCluster {
    $vip = (Test-TcpPort -Address $ClusterVip -Port 443) -or
        (Test-TcpPort -Address $ClusterVip -Port 6443)
    $nodeResults = @($NodeAddresses | ForEach-Object {
        (Test-Ping -Address $_) -or (Test-TcpPort -Address $_ -Port 22)
    })
    return [pscustomobject]@{
        vip = $vip
        allNodes = @($nodeResults | Where-Object { $_ }).Count -eq 3
        nodes = $nodeResults
    }
}

function Get-ProbeLogs {
    $uri = "$Proxy/api/v1/namespaces/$Namespace/pods/$ProbePodName/log?container=probe&tailLines=200"
    $response = Invoke-TextRequest -Uri $uri -BearerToken $Token -AllowHttpError
    if ($response.statusCode -ge 200 -and $response.statusCode -lt 300) {
        return [string]$response.content
    }
    return ''
}

function Get-LatestProbeState {
    param([string]$Logs)
    $entries = @()
    foreach ($line in ($Logs -split "`r?`n")) {
        if ($line -match '^(\d+)\s+(EGRESS_OK|EGRESS_BLOCKED)$') {
            $entries += [pscustomobject]@{ epoch = [int64]$Matches[1]; state = $Matches[2] }
        }
    }
    if ($entries.Count -eq 0) { return $null }
    return $entries | Sort-Object epoch | Select-Object -Last 1
}

function Get-CommonCachedBusyboxImage {
    $nodes = @((Invoke-JsonRequest -Method GET -Uri "$Proxy/api/v1/nodes" -BearerToken $Token).body.items)
    if ($nodes.Count -ne 3) { throw "Expected 3 nodes while selecting a cached probe image; found $($nodes.Count)." }
    $sets = @()
    foreach ($node in $nodes) {
        $names = @($node.status.images | ForEach-Object { @($_.names) } |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -match '(?i)busybox' } |
            Sort-Object -Unique)
        if ($names.Count -eq 0) {
            throw "Node $($node.metadata.name) has no cached image name containing busybox."
        }
        $sets += ,$names
    }
    $common = @($sets[0] | Where-Object {
        $candidate = $_
        ($sets[1] -contains $candidate) -and ($sets[2] -contains $candidate)
    })
    if ($common.Count -eq 0) {
        throw 'No common cached busybox image name exists on all three nodes.'
    }
    $digestRefs = @($common | Where-Object { $_ -match '@sha256:[0-9a-f]{64}$' })
    if ($digestRefs.Count -gt 0) { return [string]($digestRefs | Sort-Object | Select-Object -First 1) }
    return [string]($common | Sort-Object | Select-Object -First 1)
}

function Restore-NatConfiguration {
    if (-not $NatRemoved -or $NatRestored -or $null -eq $NatConfiguration) { return }
    $existing = @(Get-NetNat -ErrorAction SilentlyContinue | Where-Object {
        [string]$_.InternalIPInterfaceAddressPrefix -eq [string]$NatConfiguration.InternalIPInterfaceAddressPrefix
    })
    if ($existing.Count -eq 0) {
        New-NetNat -Name ([string]$NatConfiguration.Name) `
            -InternalIPInterfaceAddressPrefix ([string]$NatConfiguration.InternalIPInterfaceAddressPrefix) `
            -ErrorAction Stop | Out-Null
    }
    foreach ($mapping in $StaticMappings) {
        $parameters = @{
            NatName = [string]$NatConfiguration.Name
            Protocol = [string]$mapping.Protocol
            ExternalIPAddress = [string]$mapping.ExternalIPAddress
            ExternalPort = [int]$mapping.ExternalPort
            InternalIPAddress = [string]$mapping.InternalIPAddress
            InternalPort = [int]$mapping.InternalPort
            ErrorAction = 'Stop'
        }
        New-NetNatStaticMapping @parameters | Out-Null
    }
    $NatRestored = $true
    Write-Timeline -Record ([pscustomobject]@{
        event = 'nat-restored'
        name = [string]$NatConfiguration.Name
        prefix = [string]$NatConfiguration.InternalIPInterfaceAddressPrefix
        staticMappingCount = $StaticMappings.Count
    })
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
    $Proxy = "$ClusterUrl/k8s/clusters/local"

    $internal = Test-InternalCluster
    if (-not $internal.vip -or -not $internal.allNodes) {
        throw 'VIP or one or more nodes are unreachable before operational isolation.'
    }
    $nodes = @((Invoke-JsonRequest -Method GET -Uri "$Proxy/api/v1/nodes" -BearerToken $Token).body.items)
    $readyCount = @($nodes | Where-Object {
        @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
    }).Count
    if ($readyCount -ne 3) { throw "Only $readyCount Kubernetes nodes are Ready before isolation." }

    $ProbeImage = Get-CommonCachedBusyboxImage
    $existingPod = Invoke-JsonRequest -Method GET `
        -Uri "$Proxy/api/v1/namespaces/$Namespace/pods/$ProbePodName" `
        -BearerToken $Token -AllowHttpError
    if ($existingPod.statusCode -ge 200 -and $existingPod.statusCode -lt 300) {
        Invoke-JsonRequest -Method DELETE `
            -Uri "$Proxy/api/v1/namespaces/$Namespace/pods/$ProbePodName?gracePeriodSeconds=0" `
            -BearerToken $Token | Out-Null
    }

    $pod = [ordered]@{
        apiVersion = 'v1'
        kind = 'Pod'
        metadata = [ordered]@{
            name = $ProbePodName
            namespace = $Namespace
            labels = [ordered]@{
                'layersentry.io/validation' = 'operational-isolation'
            }
            annotations = [ordered]@{
                'layersentry.io/test-class' = 'operational-isolation-not-fresh-airgap-install'
            }
        }
        spec = [ordered]@{
            restartPolicy = 'Never'
            containers = @(
                [ordered]@{
                    name = 'probe'
                    image = $ProbeImage
                    imagePullPolicy = 'IfNotPresent'
                    command = @('/bin/sh','-c')
                    args = @('while true; do ts=$(date -u +%s); if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then echo "$ts EGRESS_OK"; else echo "$ts EGRESS_BLOCKED"; fi; sleep 5; done')
                    resources = [ordered]@{
                        requests = [ordered]@{ cpu = '5m'; memory = '8Mi' }
                        limits = [ordered]@{ cpu = '100m'; memory = '64Mi' }
                    }
                    securityContext = [ordered]@{
                        allowPrivilegeEscalation = $false
                        readOnlyRootFilesystem = $true
                        capabilities = [ordered]@{ drop = @('ALL'); add = @('NET_RAW') }
                    }
                }
            )
        }
    }
    Invoke-JsonRequest -Method POST `
        -Uri "$Proxy/api/v1/namespaces/$Namespace/pods" `
        -BearerToken $Token -Body $pod | Out-Null
    $PodCreated = $true

    $deadline = (Get-Date).ToUniversalTime().AddMinutes(8)
    do {
        $podResponse = Invoke-JsonRequest -Method GET `
            -Uri "$Proxy/api/v1/namespaces/$Namespace/pods/$ProbePodName" `
            -BearerToken $Token -AllowHttpError
        if ($podResponse.statusCode -ge 200 -and $podResponse.statusCode -lt 300) {
            $ProbeNode = [string]$podResponse.body.spec.nodeName
            $ready = @($podResponse.body.status.conditions |
                Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
            if ([string]$podResponse.body.status.phase -eq 'Running' -and $ready) { break }
            if ([string]$podResponse.body.status.phase -eq 'Failed') {
                throw 'Operational-isolation probe pod entered phase Failed.'
            }
        }
        if ((Get-Date).ToUniversalTime() -ge $deadline) {
            throw 'Operational-isolation probe pod did not become Running and Ready.'
        }
        Start-Sleep -Seconds 5
    } while ($true)

    do {
        $logs = Get-ProbeLogs
        $latest = Get-LatestProbeState -Logs $logs
        if ($latest -and $latest.state -eq 'EGRESS_OK') {
            $EgressOkBefore = $true
            break
        }
        if ((Get-Date).ToUniversalTime() -ge $deadline) {
            throw 'Probe pod did not prove working egress before NAT removal.'
        }
        Start-Sleep -Seconds 5
    } while ($true)

    $nats = @(Get-NetNat -ErrorAction Stop | Where-Object {
        [string]$_.InternalIPInterfaceAddressPrefix -eq $NatPrefix
    })
    if ($nats.Count -ne 1) {
        throw "Expected exactly one Windows NAT for $NatPrefix; found $($nats.Count)."
    }
    $nat = $nats[0]
    $NatConfiguration = [ordered]@{
        Name = [string]$nat.Name
        InternalIPInterfaceAddressPrefix = [string]$nat.InternalIPInterfaceAddressPrefix
    }
    $StaticMappings = @(Get-NetNatStaticMapping -NatName $nat.Name -ErrorAction SilentlyContinue |
        ForEach-Object {
            [ordered]@{
                Protocol = [string]$_.Protocol
                ExternalIPAddress = [string]$_.ExternalIPAddress
                ExternalPort = [int]$_.ExternalPort
                InternalIPAddress = [string]$_.InternalIPAddress
                InternalPort = [int]$_.InternalPort
            }
        })
    Write-Timeline -Record ([pscustomobject]@{
        event = 'pre-isolation-pass'
        probeImage = $ProbeImage
        probeNode = $ProbeNode
        natName = $NatConfiguration.Name
        natPrefix = $NatConfiguration.InternalIPInterfaceAddressPrefix
        staticMappingCount = $StaticMappings.Count
        egressState = 'EGRESS_OK'
    })

    Remove-NetNat -Name $nat.Name -Confirm:$false -ErrorAction Stop
    $NatRemoved = $true
    $removedEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Timeline -Record ([pscustomobject]@{
        event = 'nat-removed'
        name = $NatConfiguration.Name
        prefix = $NatConfiguration.InternalIPInterfaceAddressPrefix
        epoch = $removedEpoch
    })

    $isolationDeadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)
    do {
        $internal = Test-InternalCluster
        if (-not $internal.vip) { $VipSurvived = $false }
        if (-not $internal.allNodes) { $AllNodesSurvived = $false }
        $nodesResponse = Invoke-JsonRequest -Method GET -Uri "$Proxy/api/v1/nodes" -BearerToken $Token -AllowHttpError
        if ($nodesResponse.statusCode -lt 200 -or $nodesResponse.statusCode -ge 300) {
            $ApiSurvived = $false
        }
        else {
            $readyCount = @($nodesResponse.body.items | Where-Object {
                @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
            }).Count
            if ($readyCount -ne 3) { $ApiSurvived = $false }
        }

        $kubevirt = Invoke-JsonRequest -Method GET `
            -Uri "$Proxy/apis/kubevirt.io/v1/namespaces/harvester-system/kubevirts" `
            -BearerToken $Token -AllowHttpError
        if ($kubevirt.statusCode -ge 200 -and $kubevirt.statusCode -lt 300) {
            $KubeVirtAvailableDuring = @($kubevirt.body.items | Where-Object {
                @($_.status.conditions | Where-Object { $_.type -eq 'Available' -and $_.status -eq 'True' }).Count -gt 0
            }).Count -gt 0
        }

        $longhornNodes = Invoke-JsonRequest -Method GET `
            -Uri "$Proxy/apis/longhorn.io/v1beta2/namespaces/longhorn-system/nodes" `
            -BearerToken $Token -AllowHttpError
        if ($longhornNodes.statusCode -ge 200 -and $longhornNodes.statusCode -lt 300) {
            $LonghornHealthyDuring = @($longhornNodes.body.items | Where-Object {
                @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
            }).Count -eq 3
        }

        $logs = Get-ProbeLogs
        $entries = @()
        foreach ($line in ($logs -split "`r?`n")) {
            if ($line -match '^(\d+)\s+(EGRESS_OK|EGRESS_BLOCKED)$') {
                $entries += [pscustomobject]@{ epoch = [int64]$Matches[1]; state = $Matches[2] }
            }
        }
        $blocked = @($entries | Where-Object { $_.epoch -ge $removedEpoch -and $_.state -eq 'EGRESS_BLOCKED' })
        $BlockedSamples = $blocked.Count
        if ($BlockedSamples -ge 3) { $EgressBlockedDuring = $true }

        Write-Timeline -Record ([pscustomobject]@{
            event = 'isolation-probe'
            vipReachable = $internal.vip
            allNodesReachable = $internal.allNodes
            apiReachableAndThreeReady = $ApiSurvived
            kubevirtAvailable = $KubeVirtAvailableDuring
            longhornThreeNodesReady = $LonghornHealthyDuring
            blockedSamples = $BlockedSamples
            latestProbeState = if ($entries.Count -gt 0) { [string](($entries | Sort-Object epoch | Select-Object -Last 1).state) } else { $null }
        })

        if (-not $VipSurvived -or -not $AllNodesSurvived -or -not $ApiSurvived) {
            throw 'Internal cluster reachability or readiness failed while only the Windows NAT was removed.'
        }
        if ($EgressBlockedDuring -and $KubeVirtAvailableDuring -and $LonghornHealthyDuring) { break }
        if ((Get-Date).ToUniversalTime() -ge $isolationDeadline) {
            throw 'Operational isolation did not produce three blocked egress samples while cluster services stayed healthy.'
        }
        Start-Sleep -Seconds 5
    } while ($true)

    Restore-NatConfiguration
    $restoredEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $restoreDeadline = (Get-Date).ToUniversalTime().AddMinutes(10)
    do {
        $internal = Test-InternalCluster
        $logs = Get-ProbeLogs
        $entries = @()
        foreach ($line in ($logs -split "`r?`n")) {
            if ($line -match '^(\d+)\s+(EGRESS_OK|EGRESS_BLOCKED)$') {
                $entries += [pscustomobject]@{ epoch = [int64]$Matches[1]; state = $Matches[2] }
            }
        }
        $restoredOk = @($entries | Where-Object { $_.epoch -ge $restoredEpoch -and $_.state -eq 'EGRESS_OK' }).Count -gt 0
        Write-Timeline -Record ([pscustomobject]@{
            event = 'restoration-probe'
            vipReachable = $internal.vip
            allNodesReachable = $internal.allNodes
            egressOkAfterRestore = $restoredOk
        })
        if ($internal.vip -and $internal.allNodes -and $restoredOk) {
            $EgressOkAfter = $true
            break
        }
        if ((Get-Date).ToUniversalTime() -ge $restoreDeadline) {
            throw 'Egress or internal cluster reachability did not recover after restoring Windows NAT.'
        }
        Start-Sleep -Seconds 5
    } while ($true)

    $Passed = $EgressOkBefore -and $EgressBlockedDuring -and $EgressOkAfter -and
        $VipSurvived -and $AllNodesSurvived -and $ApiSurvived -and
        $KubeVirtAvailableDuring -and $LonghornHealthyDuring -and $NatRestored
    if (-not $Passed) { throw 'One or more operational-isolation pass conditions were not met.' }
}
catch {
    $Failure = $_.Exception.Message
    Write-Timeline -Record ([pscustomobject]@{ event = 'failure'; error = $Failure })
    throw
}
finally {
    try { Restore-NatConfiguration }
    catch {
        Write-Timeline -Record ([pscustomobject]@{ event = 'nat-restore-failure'; error = $_.Exception.Message })
        if (-not $Failure) { $Failure = "NAT restoration failed: $($_.Exception.Message)" }
    }

    if ($PodCreated -and $Token -and $Proxy) {
        try {
            Invoke-JsonRequest -Method DELETE `
                -Uri "$Proxy/api/v1/namespaces/$Namespace/pods/$ProbePodName?gracePeriodSeconds=0" `
                -BearerToken $Token -AllowHttpError | Out-Null
        }
        catch {
            Write-Timeline -Record ([pscustomobject]@{ event = 'probe-pod-cleanup-failure'; error = $_.Exception.Message })
        }
    }

    $finished = (Get-Date).ToUniversalTime()
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        authenticated = -not [string]::IsNullOrWhiteSpace($Token)
        authenticatedUser = $LoginUser
        credentialValuesRetained = $false
        clusterVip = $ClusterVip
        nodeAddresses = $NodeAddresses
        probePod = "$Namespace/$ProbePodName"
        probeImage = $ProbeImage
        probeScheduledNode = $ProbeNode
        natConfiguration = $NatConfiguration
        staticMappingCount = $StaticMappings.Count
        natRemoved = $NatRemoved
        natRestored = $NatRestored
        egressOkBeforeIsolation = $EgressOkBefore
        egressBlockedDuringIsolation = $EgressBlockedDuring
        blockedSampleCount = $BlockedSamples
        egressOkAfterRestore = $EgressOkAfter
        vipSurvivedIsolation = $VipSurvived
        allNodesSurvivedIsolation = $AllNodesSurvived
        kubernetesApiAndThreeReadySurvived = $ApiSurvived
        kubevirtAvailableDuringIsolation = $KubeVirtAvailableDuring
        longhornThreeNodesReadyDuringIsolation = $LonghornHealthyDuring
        passed = $Passed -and $null -eq $Failure
        failure = $Failure
        operationalIsolationQualified = $Passed -and $null -eq $Failure
        freshOfflineInstallationQualified = $false
        trueAirgapQualified = $false
        productionReleaseApproved = $false
    }
    $result | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry operational isolation validation

- NAT prefix: $NatPrefix
- Probe image: $ProbeImage
- Egress working before isolation: $EgressOkBefore
- Egress blocked during isolation: $EgressBlockedDuring
- Blocked samples: $BlockedSamples
- Egress working after NAT restore: $EgressOkAfter
- VIP survived: $VipSurvived
- All three nodes survived: $AllNodesSurvived
- Kubernetes API and three Ready nodes survived: $ApiSurvived
- KubeVirt remained Available: $KubeVirtAvailableDuring
- Longhorn retained three Ready nodes: $LonghornHealthyDuring
- NAT restored: $NatRestored
- Operational isolation passed: $($result.operationalIsolationQualified)
- Fresh offline installation qualified: **false**
- True air-gap qualified: **false**
- Production release approved: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $Token = $null
    $password = $null
    $credentials = $null
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
}
