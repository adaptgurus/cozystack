[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$Namespace = 'layersentry-validation',
    [string]$VmName = 'layersentry-smoke-vm',
    [string]$ContainerDiskRepository = 'quay.io/kubevirt/cirros-container-disk-demo',
    [string]$ContainerDiskTag = 'latest',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-kubevirt-vm-validation'),
    [ValidateRange(5, 60)]
    [int]$TimeoutMinutes = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Credential file is missing: $CredentialPath"
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$TimelinePath = Join-Path $OutputDirectory 'vm-workload-timeline.jsonl'
$ResultPath = Join-Path $OutputDirectory 'vm-workload-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Deadline = $Start.AddMinutes($TimeoutMinutes)
$Failure = $null
$Passed = $false
$Token = $null
$LoginUser = $null
$ResolvedImage = $null
$IndexDigest = $null
$ManifestDigest = $null
$VirtualMachine = $null
$VirtualMachineInstance = $null
$LauncherPod = $null
$Service = $null
$NodePort = $null
$ReachableNodePorts = @()
$Events = @()

function Write-Timeline {
    param([Parameter(Mandatory = $true)][object]$Record)
    $ordered = [ordered]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($property in $Record.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }
    ($ordered | ConvertTo-Json -Compress -Depth 15) |
        Add-Content -LiteralPath $TimelinePath -Encoding UTF8
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

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [int]$TimeoutSeconds = 30,
        [switch]$AllowHttpError
    )

    $headers = @{
        Accept = 'application/json'
        'User-Agent' = 'LayerSentry-VM-Validation/1.0'
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
        $parameters.ContentType = if ($Method -eq 'PATCH') {
            'application/merge-patch+json'
        } else {
            'application/json'
        }
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
                try { $responseText = $reader.ReadToEnd() }
                finally {
                    $reader.Dispose()
                    $stream.Dispose()
                }
            }
        }
        if (-not $AllowHttpError) {
            $message = if ($responseText) { $responseText } else { $exception.Message }
            throw "HTTP $Method $Uri failed with status $statusCode: $message"
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

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 2000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Resolve-RegistryManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Reference
    )

    $parts = $Repository.Split('/', 2)
    if ($parts.Count -ne 2) {
        throw "Container disk repository must include registry and repository path: $Repository"
    }
    $registry = $parts[0]
    $repositoryPath = $parts[1]
    $manifestUri = "https://$registry/v2/$repositoryPath/manifests/$Reference"
    $accept = @(
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json',
        'application/vnd.oci.image.manifest.v1+json',
        'application/vnd.docker.distribution.manifest.v2+json'
    ) -join ', '

    function Invoke-RegistryGet {
        param([string]$Uri, [string]$Bearer = $null)
        $headers = @{ Accept = $accept; 'User-Agent' = 'LayerSentry-VM-Validation/1.0' }
        if ($Bearer) { $headers.Authorization = "Bearer $Bearer" }
        try {
            return Invoke-WebRequest -Method Get -Uri $Uri -Headers $headers `
                -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        }
        catch [System.Net.WebException] {
            if ($null -eq $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 401) {
                throw
            }
            $challenge = [string]$_.Exception.Response.Headers['WWW-Authenticate']
            if ($challenge -notmatch 'Bearer\s+realm="([^"]+)"') {
                throw "Registry authentication challenge is unsupported: $challenge"
            }
            $realm = $Matches[1]
            $service = if ($challenge -match 'service="([^"]+)"') { $Matches[1] } else { $registry }
            $scope = if ($challenge -match 'scope="([^"]+)"') { $Matches[1] } else { "repository:$repositoryPath:pull" }
            $tokenUri = "$realm?service=$([uri]::EscapeDataString($service))&scope=$([uri]::EscapeDataString($scope))"
            $tokenResponse = Invoke-WebRequest -Method Get -Uri $tokenUri `
                -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            $tokenBody = $tokenResponse.Content | ConvertFrom-Json
            $bearerToken = Get-PropertyValue -Object $tokenBody -Names @('token','access_token')
            if ([string]::IsNullOrWhiteSpace($bearerToken)) {
                throw 'Registry token endpoint did not return a bearer token.'
            }
            $headers.Authorization = "Bearer $bearerToken"
            return Invoke-WebRequest -Method Get -Uri $Uri -Headers $headers `
                -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        }
    }

    $response = Invoke-RegistryGet -Uri $manifestUri
    $digest = [string]$response.Headers['Docker-Content-Digest']
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "Registry did not return a valid manifest digest for $Repository`:$Reference"
    }
    $document = $response.Content | ConvertFrom-Json
    $mediaType = [string]$document.mediaType
    $selectedDigest = $digest
    if ($mediaType -in @(
        'application/vnd.oci.image.index.v1+json',
        'application/vnd.docker.distribution.manifest.list.v2+json'
    )) {
        $amd64 = @($document.manifests | Where-Object {
            [string]$_.platform.os -eq 'linux' -and
            [string]$_.platform.architecture -eq 'amd64'
        })
        if ($amd64.Count -ne 1) {
            throw "Registry index contains $($amd64.Count) linux/amd64 manifests; expected one."
        }
        $selectedDigest = [string]$amd64[0].digest
        if ($selectedDigest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw 'Selected linux/amd64 manifest digest is invalid.'
        }
        $child = Invoke-RegistryGet -Uri "https://$registry/v2/$repositoryPath/manifests/$selectedDigest"
        $confirmedDigest = [string]$child.Headers['Docker-Content-Digest']
        if ($confirmedDigest -ne $selectedDigest) {
            throw "Resolved child manifest digest changed from $selectedDigest to $confirmedDigest."
        }
    }

    return [pscustomobject]@{
        repository = $Repository
        requestedReference = $Reference
        indexDigest = $digest
        manifestDigest = $selectedDigest
        image = "$Repository@$selectedDigest"
        mediaType = $mediaType
    }
}

function Get-Condition {
    param([object[]]$Conditions, [string]$Type)
    return @($Conditions | Where-Object { [string]$_.type -eq $Type } | Select-Object -Last 1)
}

$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$password = Get-PropertyValue -Object $credentials -Names @(
    'nodePassword','NodePassword','password','Password','rancherPassword','RancherPassword'
)
if ([string]::IsNullOrWhiteSpace($password)) {
    throw 'No node/Rancher password was found in the protected credential file.'
}

$previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

try {
    foreach ($candidateUser in @('admin','rancher')) {
        $login = Invoke-JsonRequest -Method POST `
            -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
            -Body ([ordered]@{
                username = $candidateUser
                password = $password
                responseType = 'token'
            }) `
            -AllowHttpError
        if ($login.statusCode -ge 200 -and $login.statusCode -lt 300 -and $null -ne $login.body) {
            $candidateToken = Get-PropertyValue -Object $login.body -Names @('token')
            if ($candidateToken) {
                $Token = $candidateToken
                $LoginUser = $candidateUser
                break
            }
        }
    }
    if (-not $Token) {
        throw 'Harvester/Rancher authentication failed.'
    }

    $resolved = Resolve-RegistryManifest -Repository $ContainerDiskRepository -Reference $ContainerDiskTag
    $ResolvedImage = $resolved.image
    $IndexDigest = $resolved.indexDigest
    $ManifestDigest = $resolved.manifestDigest
    Write-Timeline -Record ([pscustomobject]@{
        event = 'container-disk-resolved'
        repository = $ContainerDiskRepository
        requestedTag = $ContainerDiskTag
        indexDigest = $IndexDigest
        manifestDigest = $ManifestDigest
        image = $ResolvedImage
    })

    $proxy = "$ClusterUrl/k8s/clusters/local"
    $namespaceUri = "$proxy/api/v1/namespaces/$Namespace"
    $namespaceGet = Invoke-JsonRequest -Method GET -Uri $namespaceUri -BearerToken $Token -AllowHttpError
    if ($namespaceGet.statusCode -eq 404) {
        $namespaceCreate = Invoke-JsonRequest -Method POST -Uri "$proxy/api/v1/namespaces" `
            -BearerToken $Token `
            -Body ([ordered]@{
                apiVersion = 'v1'
                kind = 'Namespace'
                metadata = [ordered]@{
                    name = $Namespace
                    labels = [ordered]@{
                        'layersentry.io/purpose' = 'vm-workload-validation'
                    }
                }
            })
        Write-Timeline -Record ([pscustomobject]@{ event = 'namespace-created'; namespace = $Namespace })
    }
    elseif ($namespaceGet.statusCode -lt 200 -or $namespaceGet.statusCode -ge 300) {
        throw "Namespace lookup failed with HTTP $($namespaceGet.statusCode)."
    }

    $vmUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$VmName"
    $vmiUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$VmName"
    $serviceUri = "$proxy/api/v1/namespaces/$Namespace/services/$VmName-ssh"

    $existingVm = Invoke-JsonRequest -Method GET -Uri $vmUri -BearerToken $Token -AllowHttpError
    if ($existingVm.statusCode -ge 200 -and $existingVm.statusCode -lt 300) {
        Invoke-JsonRequest -Method DELETE -Uri "$vmUri?propagationPolicy=Foreground" -BearerToken $Token | Out-Null
        Write-Timeline -Record ([pscustomobject]@{ event = 'previous-vm-deleted'; vm = $VmName })
    }
    $existingService = Invoke-JsonRequest -Method GET -Uri $serviceUri -BearerToken $Token -AllowHttpError
    if ($existingService.statusCode -ge 200 -and $existingService.statusCode -lt 300) {
        Invoke-JsonRequest -Method DELETE -Uri $serviceUri -BearerToken $Token | Out-Null
        Write-Timeline -Record ([pscustomobject]@{ event = 'previous-service-deleted'; service = "$VmName-ssh" })
    }

    $deleteDeadline = (Get-Date).ToUniversalTime().AddMinutes(5)
    do {
        $stillVm = Invoke-JsonRequest -Method GET -Uri $vmUri -BearerToken $Token -AllowHttpError
        $stillVmi = Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token -AllowHttpError
        if ($stillVm.statusCode -eq 404 -and $stillVmi.statusCode -eq 404) { break }
        if ((Get-Date).ToUniversalTime() -gt $deleteDeadline) {
            throw 'Timed out waiting for the previous validation VM/VMI to disappear.'
        }
        Start-Sleep -Seconds 5
    } while ($true)

    $labels = [ordered]@{
        'layersentry.io/validation' = 'vm-smoke'
        'layersentry.io/retained' = 'true'
        'app' = $VmName
    }
    $vmDocument = [ordered]@{
        apiVersion = 'kubevirt.io/v1'
        kind = 'VirtualMachine'
        metadata = [ordered]@{
            name = $VmName
            namespace = $Namespace
            labels = $labels
            annotations = [ordered]@{
                'layersentry.io/test-class' = 'poc-workload-not-production-approval'
                'layersentry.io/container-disk-manifest' = $ManifestDigest
            }
        }
        spec = [ordered]@{
            runStrategy = 'Always'
            template = [ordered]@{
                metadata = [ordered]@{ labels = $labels }
                spec = [ordered]@{
                    terminationGracePeriodSeconds = 0
                    evictionStrategy = 'LiveMigrate'
                    readinessProbe = [ordered]@{
                        tcpSocket = [ordered]@{ port = 22 }
                        initialDelaySeconds = 10
                        periodSeconds = 10
                        timeoutSeconds = 5
                        failureThreshold = 30
                        successThreshold = 1
                    }
                    domain = [ordered]@{
                        cpu = [ordered]@{ cores = 1; sockets = 1; threads = 1 }
                        resources = [ordered]@{
                            requests = [ordered]@{ memory = '256Mi' }
                            limits = [ordered]@{ memory = '512Mi' }
                        }
                        devices = [ordered]@{
                            disks = @(
                                [ordered]@{ name = 'containerdisk'; disk = [ordered]@{ bus = 'virtio' } },
                                [ordered]@{ name = 'cloudinitdisk'; disk = [ordered]@{ bus = 'virtio' } }
                            )
                            interfaces = @(
                                [ordered]@{
                                    name = 'default'
                                    masquerade = [ordered]@{}
                                    model = 'virtio'
                                    ports = @([ordered]@{ name = 'ssh'; port = 22; protocol = 'TCP' })
                                }
                            )
                            rng = [ordered]@{}
                        }
                    }
                    networks = @([ordered]@{ name = 'default'; pod = [ordered]@{} })
                    volumes = @(
                        [ordered]@{
                            name = 'containerdisk'
                            containerDisk = [ordered]@{
                                image = $ResolvedImage
                                imagePullPolicy = 'IfNotPresent'
                            }
                        },
                        [ordered]@{
                            name = 'cloudinitdisk'
                            cloudInitNoCloud = [ordered]@{
                                userData = "#cloud-config`nhostname: layersentry-smoke`nmanage_etc_hosts: true`nssh_pwauth: true`nchpasswd:`n  expire: false`n  list: |`n    cirros:layersentry-smoke`n"
                            }
                        }
                    )
                }
            }
        }
    }
    $vmCreate = Invoke-JsonRequest -Method POST `
        -Uri "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines" `
        -BearerToken $Token `
        -Body $vmDocument
    Write-Timeline -Record ([pscustomobject]@{
        event = 'virtual-machine-created'
        namespace = $Namespace
        vm = $VmName
        image = $ResolvedImage
    })

    $serviceDocument = [ordered]@{
        apiVersion = 'v1'
        kind = 'Service'
        metadata = [ordered]@{
            name = "$VmName-ssh"
            namespace = $Namespace
            labels = $labels
        }
        spec = [ordered]@{
            type = 'NodePort'
            selector = [ordered]@{ 'layersentry.io/validation' = 'vm-smoke' }
            ports = @([ordered]@{
                name = 'ssh'
                protocol = 'TCP'
                port = 22
                targetPort = 22
            })
        }
    }
    $serviceCreate = Invoke-JsonRequest -Method POST `
        -Uri "$proxy/api/v1/namespaces/$Namespace/services" `
        -BearerToken $Token `
        -Body $serviceDocument
    Write-Timeline -Record ([pscustomobject]@{
        event = 'nodeport-service-created'
        namespace = $Namespace
        service = "$VmName-ssh"
    })

    do {
        $vmGet = Invoke-JsonRequest -Method GET -Uri $vmUri -BearerToken $Token -AllowHttpError
        $vmiGet = Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token -AllowHttpError
        $serviceGet = Invoke-JsonRequest -Method GET -Uri $serviceUri -BearerToken $Token -AllowHttpError
        if ($vmGet.statusCode -ge 200 -and $vmGet.statusCode -lt 300) {
            $VirtualMachine = $vmGet.body
        }
        if ($vmiGet.statusCode -ge 200 -and $vmiGet.statusCode -lt 300) {
            $VirtualMachineInstance = $vmiGet.body
        }
        if ($serviceGet.statusCode -ge 200 -and $serviceGet.statusCode -lt 300) {
            $Service = $serviceGet.body
            if (@($Service.spec.ports).Count -gt 0 -and $null -ne $Service.spec.ports[0].nodePort) {
                $NodePort = [int]$Service.spec.ports[0].nodePort
            }
        }

        $phase = if ($null -ne $VirtualMachineInstance) { [string]$VirtualMachineInstance.status.phase } else { 'NotCreated' }
        $readyCondition = if ($null -ne $VirtualMachineInstance) {
            Get-Condition -Conditions @($VirtualMachineInstance.status.conditions) -Type 'Ready'
        } else { @() }
        $ready = $readyCondition.Count -gt 0 -and [string]$readyCondition[0].status -eq 'True'
        $nodeName = if ($null -ne $VirtualMachineInstance) { [string]$VirtualMachineInstance.status.nodeName } else { $null }
        $guestIp = if ($null -ne $VirtualMachineInstance) { [string]$VirtualMachineInstance.status.interfaces[0].ipAddress } else { $null }

        $ReachableNodePorts = @()
        if ($null -ne $NodePort) {
            foreach ($address in @('10.10.10.11','10.10.10.12','10.10.10.13')) {
                if (Test-TcpPort -Address $address -Port $NodePort -TimeoutMilliseconds 2000) {
                    $ReachableNodePorts += $address
                }
            }
        }
        Write-Timeline -Record ([pscustomobject]@{
            event = 'vm-probe'
            phase = $phase
            ready = $ready
            nodeName = $nodeName
            guestIp = $guestIp
            nodePort = $NodePort
            reachableNodePortAddresses = $ReachableNodePorts
        })

        if ($phase -eq 'Failed') {
            throw 'KubeVirt reported the validation VMI phase as Failed.'
        }
        if ($phase -eq 'Running' -and $ready -and $ReachableNodePorts.Count -gt 0) {
            break
        }
        if ((Get-Date).ToUniversalTime() -ge $Deadline) {
            throw "Validation VM did not become Running, Ready, and reachable on SSH NodePort within $TimeoutMinutes minutes."
        }
        Start-Sleep -Seconds 10
    } while ($true)

    $selector = [uri]::EscapeDataString("kubevirt.io/domain=$VmName")
    $pods = Invoke-JsonRequest -Method GET `
        -Uri "$proxy/api/v1/namespaces/$Namespace/pods?labelSelector=$selector" `
        -BearerToken $Token
    $podItems = @($pods.body.items)
    if ($podItems.Count -ne 1) {
        throw "Expected exactly one virt-launcher pod for $VmName; found $($podItems.Count)."
    }
    $LauncherPod = $podItems[0]
    if ([string]$LauncherPod.status.phase -ne 'Running') {
        throw "virt-launcher pod phase is '$($LauncherPod.status.phase)' instead of Running."
    }
    $notReadyContainers = @($LauncherPod.status.containerStatuses | Where-Object { -not [bool]$_.ready })
    if ($notReadyContainers.Count -gt 0) {
        throw "$($notReadyContainers.Count) virt-launcher containers are not Ready."
    }

    $fieldSelector = [uri]::EscapeDataString("involvedObject.name=$VmName")
    $eventResponse = Invoke-JsonRequest -Method GET `
        -Uri "$proxy/api/v1/namespaces/$Namespace/events?fieldSelector=$fieldSelector" `
        -BearerToken $Token `
        -AllowHttpError
    if ($eventResponse.statusCode -ge 200 -and $eventResponse.statusCode -lt 300) {
        $Events = @($eventResponse.body.items | ForEach-Object {
            [ordered]@{
                type = [string]$_.type
                reason = [string]$_.reason
                message = [string]$_.message
                firstTimestamp = [string]$_.firstTimestamp
                lastTimestamp = [string]$_.lastTimestamp
                count = [int]$_.count
            }
        })
    }

    $warningEvents = @($Events | Where-Object { $_.type -eq 'Warning' })
    if ($warningEvents.Count -gt 0) {
        throw "The validation VM has $($warningEvents.Count) Warning events."
    }

    $Passed = $true
}
catch {
    $Failure = $_.Exception.Message
    Write-Timeline -Record ([pscustomobject]@{ event = 'failure'; error = $Failure })
    throw
}
finally {
    $finished = (Get-Date).ToUniversalTime()
    $vmiConditions = if ($null -ne $VirtualMachineInstance) {
        @($VirtualMachineInstance.status.conditions | ForEach-Object {
            [ordered]@{
                type = [string]$_.type
                status = [string]$_.status
                reason = [string]$_.reason
                message = [string]$_.message
            }
        })
    } else { @() }
    $podSummary = if ($null -ne $LauncherPod) {
        [ordered]@{
            namespace = [string]$LauncherPod.metadata.namespace
            name = [string]$LauncherPod.metadata.name
            nodeName = [string]$LauncherPod.spec.nodeName
            phase = [string]$LauncherPod.status.phase
            podIp = [string]$LauncherPod.status.podIP
            hostIp = [string]$LauncherPod.status.hostIP
            containers = @($LauncherPod.status.containerStatuses | ForEach-Object {
                [ordered]@{
                    name = [string]$_.name
                    ready = [bool]$_.ready
                    restartCount = [int]$_.restartCount
                    image = [string]$_.image
                    imageId = [string]$_.imageID
                }
            })
        }
    } else { $null }

    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        clusterUrl = $ClusterUrl
        authenticated = -not [string]::IsNullOrWhiteSpace($Token)
        authenticatedUser = $LoginUser
        credentialValuesRetained = $false
        namespace = $Namespace
        virtualMachine = $VmName
        retainedForUserInspection = $true
        containerDisk = [ordered]@{
            repository = $ContainerDiskRepository
            requestedTag = $ContainerDiskTag
            indexDigest = $IndexDigest
            linuxAmd64ManifestDigest = $ManifestDigest
            immutableImage = $ResolvedImage
            testInputClassification = 'runtime-test-only-not-production-iso-input'
        }
        passed = $Passed
        failure = $Failure
        vmReady = if ($null -ne $VirtualMachine) { [bool]$VirtualMachine.status.ready } else { $false }
        printableStatus = if ($null -ne $VirtualMachine) { [string]$VirtualMachine.status.printableStatus } else { $null }
        vmiPhase = if ($null -ne $VirtualMachineInstance) { [string]$VirtualMachineInstance.status.phase } else { $null }
        vmiNodeName = if ($null -ne $VirtualMachineInstance) { [string]$VirtualMachineInstance.status.nodeName } else { $null }
        vmiGuestIp = if ($null -ne $VirtualMachineInstance -and @($VirtualMachineInstance.status.interfaces).Count -gt 0) {
            [string]$VirtualMachineInstance.status.interfaces[0].ipAddress
        } else { $null }
        vmiConditions = $vmiConditions
        serviceNodePort = $NodePort
        reachableNodePortAddresses = $ReachableNodePorts
        virtLauncherPod = $podSummary
        events = $Events
        vmWorkloadQualified = $Passed
        productionReleaseApproved = $false
        persistentStorageQualified = $false
        liveMigrationQualified = $false
        haQualified = $false
        trueAirgapQualified = $false
    }
    $result | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry KubeVirt VM workload validation

- VM: $Namespace/$VmName
- Container disk: $ResolvedImage
- VMI phase: $($result.vmiPhase)
- Scheduled node: $($result.vmiNodeName)
- Guest IP: $($result.vmiGuestIp)
- SSH NodePort: $($result.serviceNodePort)
- Reachable through node addresses: $($result.reachableNodePortAddresses -join ', ')
- VM workload qualification passed: $($result.vmWorkloadQualified)
- VM retained for UI inspection: **true**
- Persistent storage qualified: **false**
- Live migration qualified: **false**
- HA qualified: **false**
- True air-gap qualified: **false**
- Production release approved: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $Token = $null
    $password = $null
    $credentials = $null
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
}
