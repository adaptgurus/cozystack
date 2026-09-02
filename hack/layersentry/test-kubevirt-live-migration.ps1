[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$Namespace = 'layersentry-validation',
    [string]$VmName = 'layersentry-smoke-vm',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-kubevirt-migration-validation'),
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
$TimelinePath = Join-Path $OutputDirectory 'migration-timeline.jsonl'
$ResultPath = Join-Path $OutputDirectory 'migration-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Deadline = $Start.AddMinutes($TimeoutMinutes)
$Failure = $null
$Passed = $false
$Token = $null
$LoginUser = $null
$SourceNode = $null
$TargetNode = $null
$MigrationName = $null
$Migration = $null
$VmiBefore = $null
$VmiAfter = $null
$Service = $null
$NodePort = $null
$ReachableBefore = @()
$ReachableDuring = @()
$ReachableAfter = @()
$WarningEvents = @()

function Write-Timeline {
    param([Parameter(Mandatory = $true)][object]$Record)
    $ordered = [ordered]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($property in $Record.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }
    ($ordered | ConvertTo-Json -Compress -Depth 20) |
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
    $headers = @{ Accept = 'application/json'; 'User-Agent' = 'LayerSentry-Migration-Validation/1.0' }
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
        return [pscustomobject]@{ statusCode = [int]$response.StatusCode; body = $value; error = $null }
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
        return [pscustomobject]@{ statusCode = $statusCode; body = $value; error = $exception.Message }
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

function Get-ReachableNodePorts {
    param([int]$Port)
    $reachable = @()
    foreach ($address in @('10.10.10.11','10.10.10.12','10.10.10.13')) {
        if (Test-TcpPort -Address $address -Port $Port -TimeoutMilliseconds 2000) {
            $reachable += $address
        }
    }
    return @($reachable)
}

function Get-ReadyCondition {
    param([object]$Vmi)
    $condition = @($Vmi.status.conditions |
        Where-Object { [string]$_.type -eq 'Ready' } |
        Select-Object -Last 1)
    if ($condition.Count -eq 0) { return $null }
    return [string]$condition[0].status
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
    $vmUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$VmName"
    $vmiUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$VmName"
    $serviceUri = "$proxy/api/v1/namespaces/$Namespace/services/$VmName-ssh"

    $vmResponse = Invoke-JsonRequest -Method GET -Uri $vmUri -BearerToken $Token
    $VmiBefore = (Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token).body
    $Service = (Invoke-JsonRequest -Method GET -Uri $serviceUri -BearerToken $Token).body
    if ([string]$VmiBefore.status.phase -ne 'Running') {
        throw "Validation VMI phase is '$($VmiBefore.status.phase)' instead of Running."
    }
    if ((Get-ReadyCondition -Vmi $VmiBefore) -ne 'True') {
        throw 'Validation VMI is not Ready before migration.'
    }
    if ([string]$vmResponse.body.spec.template.spec.evictionStrategy -ne 'LiveMigrate') {
        throw 'Validation VM does not have evictionStrategy=LiveMigrate.'
    }
    $SourceNode = [string]$VmiBefore.status.nodeName
    if ([string]::IsNullOrWhiteSpace($SourceNode)) { throw 'Validation VMI has no source node.' }
    if (@($Service.spec.ports).Count -ne 1 -or $null -eq $Service.spec.ports[0].nodePort) {
        throw 'Validation SSH service does not have exactly one NodePort.'
    }
    $NodePort = [int]$Service.spec.ports[0].nodePort
    $ReachableBefore = Get-ReachableNodePorts -Port $NodePort
    if ($ReachableBefore.Count -eq 0) { throw 'Validation guest SSH NodePort is unreachable before migration.' }

    $MigrationName = 'layersentry-smoke-migration-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $migrationDocument = [ordered]@{
        apiVersion = 'kubevirt.io/v1'
        kind = 'VirtualMachineInstanceMigration'
        metadata = [ordered]@{
            name = $MigrationName
            namespace = $Namespace
            labels = [ordered]@{
                'layersentry.io/validation' = 'live-migration'
                'layersentry.io/source-vm' = $VmName
            }
            annotations = [ordered]@{
                'layersentry.io/test-class' = 'nested-poc-not-physical-host-certification'
            }
        }
        spec = [ordered]@{ vmiName = $VmName }
    }
    $migrationCreate = Invoke-JsonRequest -Method POST `
        -Uri "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstancemigrations" `
        -BearerToken $Token `
        -Body $migrationDocument
    Write-Timeline -Record ([pscustomobject]@{
        event = 'migration-created'
        migration = $MigrationName
        vm = $VmName
        sourceNode = $SourceNode
        nodePort = $NodePort
        reachableBefore = $ReachableBefore
    })

    $migrationUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstancemigrations/$MigrationName"
    do {
        $Migration = (Invoke-JsonRequest -Method GET -Uri $migrationUri -BearerToken $Token).body
        $currentVmi = (Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token).body
        $phase = [string]$Migration.status.phase
        $currentNode = [string]$currentVmi.status.nodeName
        $ready = Get-ReadyCondition -Vmi $currentVmi
        $ReachableDuring = Get-ReachableNodePorts -Port $NodePort
        $migrationState = $currentVmi.status.migrationState
        Write-Timeline -Record ([pscustomobject]@{
            event = 'migration-probe'
            migrationPhase = $phase
            currentNode = $currentNode
            vmiPhase = [string]$currentVmi.status.phase
            vmiReady = $ready
            migrationState = $migrationState
            reachableNodePorts = $ReachableDuring
        })

        if ($phase -in @('Failed','Unknown')) {
            throw "KubeVirt migration entered terminal phase '$phase'."
        }
        if ($phase -eq 'Succeeded') { break }
        if ((Get-Date).ToUniversalTime() -ge $Deadline) {
            throw "Live migration did not reach Succeeded within $TimeoutMinutes minutes."
        }
        Start-Sleep -Seconds 5
    } while ($true)

    Start-Sleep -Seconds 10
    $VmiAfter = (Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token).body
    $TargetNode = [string]$VmiAfter.status.nodeName
    $ReachableAfter = Get-ReachableNodePorts -Port $NodePort
    if ([string]$VmiAfter.status.phase -ne 'Running') {
        throw "Validation VMI phase after migration is '$($VmiAfter.status.phase)' instead of Running."
    }
    if ((Get-ReadyCondition -Vmi $VmiAfter) -ne 'True') {
        throw 'Validation VMI is not Ready after migration.'
    }
    if ([string]::IsNullOrWhiteSpace($TargetNode) -or $TargetNode -eq $SourceNode) {
        throw "Migration did not move the VMI away from source node '$SourceNode'."
    }
    if ($ReachableAfter.Count -eq 0) {
        throw 'Validation guest SSH NodePort is unreachable after migration.'
    }
    $state = $VmiAfter.status.migrationState
    if ($null -eq $state -or -not [bool]$state.completed -or [bool]$state.failed) {
        throw 'VMI migrationState does not report completed=true and failed=false.'
    }

    $fieldSelector = [uri]::EscapeDataString("involvedObject.name=$MigrationName")
    $eventsResponse = Invoke-JsonRequest -Method GET `
        -Uri "$proxy/api/v1/namespaces/$Namespace/events?fieldSelector=$fieldSelector" `
        -BearerToken $Token `
        -AllowHttpError
    if ($eventsResponse.statusCode -ge 200 -and $eventsResponse.statusCode -lt 300) {
        $WarningEvents = @($eventsResponse.body.items | Where-Object { [string]$_.type -eq 'Warning' } | ForEach-Object {
            [ordered]@{
                reason = [string]$_.reason
                message = [string]$_.message
                count = [int]$_.count
                firstTimestamp = [string]$_.firstTimestamp
                lastTimestamp = [string]$_.lastTimestamp
            }
        })
    }
    if ($WarningEvents.Count -gt 0) {
        throw "Migration produced $($WarningEvents.Count) Warning events."
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
    $migrationStateSummary = if ($null -ne $VmiAfter -and $null -ne $VmiAfter.status.migrationState) {
        [ordered]@{
            sourceNode = [string]$VmiAfter.status.migrationState.sourceNode
            targetNode = [string]$VmiAfter.status.migrationState.targetNode
            targetNodeAddress = [string]$VmiAfter.status.migrationState.targetNodeAddress
            startTimestamp = [string]$VmiAfter.status.migrationState.startTimestamp
            endTimestamp = [string]$VmiAfter.status.migrationState.endTimestamp
            completed = [bool]$VmiAfter.status.migrationState.completed
            failed = [bool]$VmiAfter.status.migrationState.failed
            abortRequested = [bool]$VmiAfter.status.migrationState.abortRequested
            mode = [string]$VmiAfter.status.migrationState.mode
            migrationUid = [string]$VmiAfter.status.migrationState.migrationUid
        }
    } else { $null }
    $migrationConditions = if ($null -ne $Migration) {
        @($Migration.status.conditions | ForEach-Object {
            [ordered]@{
                type = [string]$_.type
                status = [string]$_.status
                reason = [string]$_.reason
                message = [string]$_.message
            }
        })
    } else { @() }
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
        migration = $MigrationName
        migrationPhase = if ($null -ne $Migration) { [string]$Migration.status.phase } else { $null }
        sourceNode = $SourceNode
        targetNode = $TargetNode
        nodeChanged = -not [string]::IsNullOrWhiteSpace($TargetNode) -and $TargetNode -ne $SourceNode
        serviceNodePort = $NodePort
        reachableBefore = $ReachableBefore
        reachableDuringLastProbe = $ReachableDuring
        reachableAfter = $ReachableAfter
        migrationState = $migrationStateSummary
        migrationConditions = $migrationConditions
        warningEvents = $WarningEvents
        passed = $Passed
        failure = $Failure
        liveMigrationQualifiedInNestedPoc = $Passed
        physicalHostLiveMigrationQualified = $false
        productionReleaseApproved = $false
        haFailureRecoveryQualified = $false
        trueAirgapQualified = $false
    }
    $result | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry KubeVirt live-migration validation

- VM: $Namespace/$VmName
- Migration: $MigrationName
- Migration phase: $($result.migrationPhase)
- Source node: $SourceNode
- Target node: $TargetNode
- Node changed: $($result.nodeChanged)
- SSH NodePort reachable before: $($ReachableBefore -join ', ')
- SSH NodePort reachable after: $($ReachableAfter -join ', ')
- Nested-POC live migration passed: $($result.liveMigrationQualifiedInNestedPoc)
- Physical-host migration qualified: **false**
- HA failure recovery qualified: **false**
- True air-gap qualified: **false**
- Production release approved: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $Token = $null
    $password = $null
    $credentials = $null
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
}
