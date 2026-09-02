[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen1', 'sen2', 'sen3'),
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-installer-autopilot-v4'),
    [ValidateRange(1, 300)]
    [int]$MaxIterations = 180,
    [ValidateRange(3, 120)]
    [int]$PollSeconds = 12,
    [ValidateRange(15, 240)]
    [int]$FirstNodeTimeoutMinutes = 120,
    [ValidateRange(15, 240)]
    [int]$JoinNodesTimeoutMinutes = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedVmNames = @('sen1', 'sen2', 'sen3')
$actualNames = @($VmNames | Sort-Object)
if ($actualNames.Count -ne 3 -or ($actualNames -join ',') -ne (($ExpectedVmNames | Sort-Object) -join ',')) {
    throw 'Autopilot v4 is restricted to exactly sen1, sen2, and sen3.'
}

$CaptureScript = Join-Path $PSScriptRoot 'capture-hyperv-console.ps1'
$OcrScript = Join-Path $PSScriptRoot 'read-console-ocr.ps1'
$CommandScript = Join-Path $PSScriptRoot 'invoke-hyperv-console-command.ps1'
$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json'
$ClusterVip = '10.10.10.10'
$NodeAddresses = [ordered]@{
    sen1 = '10.10.10.11'
    sen2 = '10.10.10.12'
    sen3 = '10.10.10.13'
}
$NtpServers = 'time.cloudflare.com,time.google.com'
$DnsServers = '8.8.8.8,1.1.1.1'
$MinimumOsDiskBytes = 250GB
$MinimumDataDiskBytes = 300GB
$LikelyInstalledVhdBytes = 2GB

foreach ($path in @($CaptureScript, $OcrScript, $CommandScript, $CredentialPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required autopilot input is missing: $path"
    }
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

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$HistoryPath = Join-Path $OutputDirectory 'autopilot-history.jsonl'
$SummaryPath = Join-Path $OutputDirectory 'autopilot-summary.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$StartTime = (Get-Date).ToUniversalTime()
$FirstNodeDeadline = $StartTime.AddMinutes($FirstNodeTimeoutMinutes)
$JoinNodesDeadline = $null
$Failure = $null
$Passed = $false

$Runtime = @{}
foreach ($vmName in $VmNames) {
    $Runtime[$vmName] = [ordered]@{
        vm = $vmName
        initialOsVhdFileBytes = 0L
        currentOsVhdFileBytes = 0L
        installationLikelyStarted = $false
        installationConfirmedByScreen = $false
        installationConfirmationSent = $false
        installationConfirmationSentAtUtc = $null
        diskBootPrepared = $false
        diskBootPreparedAtUtc = $null
        bootedFromDisk = $false
        reachable = $false
        lastState = $null
        sameStateCount = 0
        unknownCount = 0
        actionsSent = 0
        lastActionAtUtc = $null
        lastOcrText = $null
        lastConsolePath = $null
        lastClassificationReason = $null
        lastVmUptimeSeconds = 0L
        uptimeResetObserved = $false
    }
}

function Write-History {
    param([Parameter(Mandatory = $true)][object]$Record)
    $ordered = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($property in $Record.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }
    ($ordered | ConvertTo-Json -Compress -Depth 15) |
        Add-Content -LiteralPath $HistoryPath -Encoding UTF8
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 1500
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
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Test-Ping {
    param([Parameter(Mandatory = $true)][string]$Address)
    try {
        return [bool](Test-Connection -ComputerName $Address -Count 1 -Quiet -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Test-NodeReachable {
    param([Parameter(Mandatory = $true)][string]$Address)
    return (Test-TcpPort -Address $Address -Port 22 -TimeoutMilliseconds 1000) -or
        (Test-Ping -Address $Address)
}

function Test-ClusterReady {
    return (Test-TcpPort -Address $ClusterVip -Port 443 -TimeoutMilliseconds 1500) -or
        (Test-TcpPort -Address $ClusterVip -Port 6443 -TimeoutMilliseconds 1500)
}

function Get-OrderedDisks {
    param([Parameter(Mandatory = $true)][string]$VmName)
    return @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop |
        Sort-Object ControllerNumber, ControllerLocation)
}

function Get-OsVhd {
    param([Parameter(Mandatory = $true)][string]$VmName)
    $disk = Get-OrderedDisks -VmName $VmName | Select-Object -First 1
    if ($null -eq $disk -or [string]::IsNullOrWhiteSpace($disk.Path)) {
        throw "No OS VHDX is attached to $VmName."
    }
    return Get-VHD -Path $disk.Path -ErrorAction Stop
}

function Assert-VMDesign {
    param([Parameter(Mandatory = $true)][string]$VmName)
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.Generation -ne 2) {
        throw "$VmName is not a Generation 2 UEFI VM."
    }
    $processor = Get-VMProcessor -VMName $VmName -ErrorAction Stop
    if ($processor.Count -ne 10) {
        throw "$VmName has $($processor.Count) vCPU; expected 10."
    }
    if (-not [bool]$processor.ExposeVirtualizationExtensions) {
        throw "$VmName does not expose nested virtualization extensions."
    }
    if ([int64]$vm.MemoryStartup -ne 32GB -or [bool]$vm.DynamicMemoryEnabled) {
        throw "$VmName must have exactly 32 GiB static startup memory."
    }
    $disks = Get-OrderedDisks -VmName $VmName
    if ($disks.Count -lt 2) {
        throw "$VmName has fewer than two attached hard disks."
    }
    $osVhd = Get-VHD -Path $disks[0].Path -ErrorAction Stop
    $dataVhd = Get-VHD -Path $disks[1].Path -ErrorAction Stop
    if ([int64]$osVhd.Size -lt $MinimumOsDiskBytes) {
        throw "$VmName OS disk is smaller than 250 GiB."
    }
    if ([int64]$dataVhd.Size -lt $MinimumDataDiskBytes) {
        throw "$VmName data disk is smaller than 300 GiB."
    }
    $adapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop |
        Select-Object -First 1
    if ($null -eq $adapter) {
        throw "$VmName has no network adapter."
    }
    if ($adapter.SwitchName -ne 'Cozystack-NAT') {
        throw "$VmName is attached to '$($adapter.SwitchName)' instead of Cozystack-NAT."
    }
    if ($adapter.MacAddressSpoofing.ToString() -ne 'On') {
        throw "$VmName does not have MAC-address spoofing enabled."
    }
    $firmware = Get-VMFirmware -VMName $VmName -ErrorAction Stop
    if ($firmware.SecureBoot.ToString() -eq 'On') {
        throw "$VmName Secure Boot must be disabled for this candidate ISO."
    }
    $Runtime[$VmName].initialOsVhdFileBytes = [int64]$osVhd.FileSize
    $Runtime[$VmName].currentOsVhdFileBytes = [int64]$osVhd.FileSize
    if ([int64]$osVhd.FileSize -ge $LikelyInstalledVhdBytes) {
        $Runtime[$VmName].installationLikelyStarted = $true
    }
    if ($vm.State -eq 'Off') {
        Start-VM -Name $VmName | Out-Null
    }
}

function Convert-OcrToState {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$VmName
    )

    $normalized = ($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()
    $lower = $normalized.ToLowerInvariant()
    $state = 'UNKNOWN'
    $reason = 'No reviewed installer or installed-system pattern matched.'
    $confidence = 'low'

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $state = 'BLANK_OR_BOOTING'
        $reason = 'Console OCR returned no text.'
        $confidence = 'medium'
    }
    elseif ($lower -match 'passwords?\s+(do\s+not|don.t)\s+match|invalid\s+(password|value|address|token)|validation\s+(failed|error)|unable\s+to\s+continue|installation\s+failed|fatal\s+error|panic') {
        $state = 'INSTALLER_ERROR'
        $reason = 'Installer validation or fatal failure text is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'installation\s+(is\s+)?(complete|completed|successful|succeeded)|successfully\s+installed|remove\s+the\s+installation\s+media|reboot(ing|\s+the\s+system)?') {
        $state = 'INSTALL_COMPLETE'
        $reason = 'Installer completion or reboot text is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'installing\s+(harvester|layersentry)|installation\s+in\s+progress|writing\s+(the\s+)?(image|disk)|copying\s+(files|image)|formatting\s+(the\s+)?disk|extracting|setting\s+up\s+(the\s+)?system|installing\.{2,}') {
        $state = 'INSTALLING'
        $reason = 'Installer progress text is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'review\s+(the\s+)?configuration|configuration\s+summary|confirm\s+(the\s+)?installation|start\s+(the\s+)?installation|install\s+now|are\s+you\s+sure.*install|ready\s+to\s+install') {
        $state = 'REVIEW_OR_CONFIRM'
        $reason = 'Review or installation-confirmation screen is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'confirm\s+(the\s+)?password|re[- ]?enter\s+(the\s+)?password|password\s+confirmation|password\s+again') {
        $state = 'CONFIRM_PASSWORD'
        $reason = 'Password confirmation prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'set\s+(the\s+)?password|enter\s+(a\s+)?password|password\s+for\s+(the\s+)?(rancher|harvester|user|node)|os\s+password|\bpassword\b') {
        $state = 'PASSWORD'
        $reason = 'Password prompt is present.'
        $confidence = 'medium'
    }
    elseif ($lower -match 'ssh\s+(authorized\s+)?key|public\s+ssh\s+key|authorized[_ ]keys?|configure\s+ssh|ssh\s+access|cloud[- ]?init|remote\s+harvester|configuration\s+url') {
        $state = 'SSH_OR_REMOTE_CONFIG'
        $reason = 'Optional SSH, cloud-init, or remote-configuration prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'http\s+proxy|https\s+proxy|proxy\s+(address|url|configuration|settings)|no[_ -]?proxy|\bproxy\b') {
        $state = 'PROXY'
        $reason = 'Proxy configuration prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'time\s*zone|timezone') {
        $state = 'TIMEZONE'
        $reason = 'Timezone prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match '\bntp\b|network\s+time\s+protocol|time\s+server') {
        $state = 'NTP'
        $reason = 'NTP-server prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'cluster\s+token|token\s+for\s+(the\s+)?cluster|enter\s+(the\s+)?token') {
        $state = 'CLUSTER_TOKEN'
        $reason = 'Cluster-token prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'virtual\s+ip|\bvip\b|management\s+(address|url)|server\s+(address|url)|existing\s+cluster\s+(address|url)') {
        $state = 'VIP_OR_SERVER'
        $reason = 'VIP or existing-cluster server address prompt is present.'
        $confidence = 'medium'
    }
    elseif ($lower -match '\bdns\b|name\s+server') {
        $state = 'DNS'
        $reason = 'DNS-server prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'host\s*name|hostname') {
        $state = 'HOSTNAME'
        $reason = 'Hostname prompt is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'install(ation)?\s+(device|disk)|select\s+(the\s+)?disk.*install') {
        $state = 'INSTALL_DISK'
        $reason = 'Installation-disk selection is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'data\s+(device|disk)|select\s+(the\s+)?disk.*data') {
        $state = 'DATA_DISK'
        $reason = 'Data-disk selection is present.'
        $confidence = 'high'
    }
    elseif ($lower -match 'ip\s+address|subnet\s+mask|default\s+gateway|network\s+interface|static\s+ip|\bdhcp\b') {
        $state = 'NETWORK'
        $reason = 'Network-configuration prompt is present.'
        $confidence = 'medium'
    }
    elseif ($lower -match 'create\s+(a\s+)?new\s+(harvester\s+)?cluster|join\s+(an\s+)?existing\s+(harvester\s+)?cluster|installation\s+mode') {
        $state = 'INSTALLATION_MODE'
        $reason = 'Installation-mode selection is present.'
        $confidence = 'medium'
    }
    elseif ($lower -match 'start\s+(harvester|layersentry).*installer|harvester\s+installer|layersentry\s+installer') {
        $state = 'INSTALLER_MENU_OR_UNKNOWN'
        $reason = 'Installer media or an unclassified installer page is visible.'
        $confidence = 'medium'
    }
    elseif ($lower -match 'management\s+url|welcome\s+to\s+(harvester|layersentry)|harvester\s+console|login:|kubernetes\s+control\s+plane|rancher\s+is\s+ready') {
        $state = 'BOOTED_SYSTEM'
        $reason = 'Installed-system console or login text is visible.'
        $confidence = 'medium'
    }

    return [pscustomobject]@{
        vm = $VmName
        state = $state
        confidence = $confidence
        reason = $reason
        normalizedText = $normalized
    }
}

function Capture-And-ClassifyAll {
    param([Parameter(Mandatory = $true)][int]$Iteration)

    $iterationDirectory = Join-Path $OutputDirectory ('iteration-{0:D3}' -f $Iteration)
    $consoleDirectory = Join-Path $iterationDirectory 'consoles'
    $stateDirectory = Join-Path $iterationDirectory 'states'
    New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
    & $CaptureScript -VmNames $VmNames -OutputDirectory $consoleDirectory

    $results = @{}
    foreach ($vmName in $VmNames) {
        $image = Join-Path $consoleDirectory "$vmName-console.png"
        $ocrPath = Join-Path $stateDirectory "$vmName-ocr.json"
        $statePath = Join-Path $stateDirectory "$vmName-state.json"
        & $OcrScript -ImagePath $image -LanguageTag 'en-US' |
            Set-Content -LiteralPath $ocrPath -Encoding UTF8
        $ocr = Get-Content -LiteralPath $ocrPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $classification = Convert-OcrToState -Text ([string]$ocr.text) -VmName $vmName
        $classification | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $statePath -Encoding UTF8

        $previousState = [string]$Runtime[$vmName].lastState
        if ($previousState -eq [string]$classification.state) {
            $Runtime[$vmName].sameStateCount++
        }
        else {
            $Runtime[$vmName].lastState = [string]$classification.state
            $Runtime[$vmName].sameStateCount = 1
        }
        if ([string]$classification.state -in @('UNKNOWN', 'INSTALLER_MENU_OR_UNKNOWN')) {
            $Runtime[$vmName].unknownCount++
        }
        else {
            $Runtime[$vmName].unknownCount = 0
        }
        $Runtime[$vmName].lastOcrText = [string]$ocr.text
        $Runtime[$vmName].lastConsolePath = $image
        $Runtime[$vmName].lastClassificationReason = [string]$classification.reason
        $results[$vmName] = $classification

        Write-History -Record ([pscustomobject]@{
            event = 'screen-classification'
            iteration = $Iteration
            vm = $vmName
            state = $classification.state
            confidence = $classification.confidence
            reason = $classification.reason
            sameStateCount = $Runtime[$vmName].sameStateCount
            unknownCount = $Runtime[$vmName].unknownCount
            ocrText = [string]$ocr.text
        })
    }
    return $results
}

function Invoke-ConsoleAction {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][object[]]$Actions,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][int]$Iteration
    )

    $requestDirectory = Join-Path $OutputDirectory 'requests'
    $resultDirectory = Join-Path $OutputDirectory 'command-results'
    New-Item -Path $requestDirectory -ItemType Directory -Force | Out-Null
    New-Item -Path $resultDirectory -ItemType Directory -Force | Out-Null
    $requestPath = Join-Path $requestDirectory ('{0:D3}-{1}-{2:D3}.json' -f $Iteration, $VmName, $Runtime[$VmName].actionsSent)
    [ordered]@{
        requestId = "autopilot-v4-$Iteration-$VmName-$($Runtime[$VmName].actionsSent)"
        delayAfterSeconds = 2
        targets = @(
            [ordered]@{
                vm = $VmName
                actions = @($Actions)
            }
        )
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $requestPath -Encoding UTF8

    & $CommandScript -RequestPath $requestPath -OutputDirectory $resultDirectory
    $Runtime[$VmName].actionsSent++
    $Runtime[$VmName].lastActionAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-History -Record ([pscustomobject]@{
        event = 'console-action'
        iteration = $Iteration
        vm = $VmName
        reason = $Reason
        actionKinds = @($Actions | ForEach-Object { [string]$_.kind })
        secretValuesLogged = $false
    })
}

function Set-DiskBoot {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    if ([bool]$Runtime[$VmName].diskBootPrepared) {
        return
    }
    Write-History -Record ([pscustomobject]@{
        event = 'prepare-disk-boot'
        vm = $VmName
        reason = $Reason
    })

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-VM -Name $VmName).State -ne 'Off') {
            if ((Get-Date) -gt $deadline) {
                throw "Timed out stopping $VmName before changing boot media."
            }
            Start-Sleep -Seconds 2
        }
    }

    $osDisk = Get-OrderedDisks -VmName $VmName | Select-Object -First 1
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDisk
    foreach ($dvd in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace($dvd.Path)) {
            Set-VMDvdDrive -VMName $VmName `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $null
        }
    }
    Start-VM -Name $VmName | Out-Null
    $Runtime[$VmName].diskBootPrepared = $true
    $Runtime[$VmName].diskBootPreparedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}

function Update-VMRuntimeFacts {
    foreach ($vmName in $VmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $uptime = [int64]$vm.Uptime.TotalSeconds
        if ([int64]$Runtime[$vmName].lastVmUptimeSeconds -gt 120 -and $uptime -lt 90) {
            $Runtime[$vmName].uptimeResetObserved = $true
        }
        $Runtime[$vmName].lastVmUptimeSeconds = $uptime
        $osVhd = Get-OsVhd -VmName $vmName
        $Runtime[$vmName].currentOsVhdFileBytes = [int64]$osVhd.FileSize
        if ([int64]$osVhd.FileSize -ge $LikelyInstalledVhdBytes) {
            $Runtime[$vmName].installationLikelyStarted = $true
        }
        $Runtime[$vmName].reachable = Test-NodeReachable -Address $NodeAddresses[$vmName]
    }
}

function Get-SafeActions {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][bool]$ClusterReady
    )

    $enter = [ordered]@{ kind = 'key'; code = 13 }
    switch ($State) {
        'CLUSTER_TOKEN' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'secret'; name = 'clusterToken' }, $enter)
                reason = 'Enter the locally protected common cluster token.'
            }
        }
        'NTP' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'text'; value = $NtpServers }, $enter)
                reason = 'Configure the approved connected-POC NTP sources.'
            }
        }
        'TIMEZONE' {
            return [pscustomobject]@{
                actions = @($enter)
                reason = 'Accept the installer default UTC timezone.'
            }
        }
        'PROXY' {
            return [pscustomobject]@{
                actions = @($enter)
                reason = 'Leave proxy configuration empty on the direct-NAT POC network.'
            }
        }
        'SSH_OR_REMOTE_CONFIG' {
            return [pscustomobject]@{
                actions = @($enter)
                reason = 'Skip the optional SSH/cloud-init/remote configuration field.'
            }
        }
        'PASSWORD' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'secret'; name = 'nodePassword' }, $enter)
                reason = 'Enter the locally protected node password.'
            }
        }
        'CONFIRM_PASSWORD' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'secret'; name = 'nodePassword' }, $enter)
                reason = 'Confirm the locally protected node password.'
            }
        }
        'VIP_OR_SERVER' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'text'; value = $ClusterVip }, $enter)
                reason = 'Use the approved cluster VIP/server address.'
            }
        }
        'DNS' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'text'; value = $DnsServers }, $enter)
                reason = 'Configure the approved connected-POC DNS resolvers.'
            }
        }
        'HOSTNAME' {
            return [pscustomobject]@{
                actions = @([ordered]@{ kind = 'text'; value = $VmName }, $enter)
                reason = 'Set hostname equal to the Hyper-V VM name.'
            }
        }
        'REVIEW_OR_CONFIRM' {
            if ($VmName -ne 'sen1' -and -not $ClusterReady) {
                return [pscustomobject]@{
                    actions = @()
                    reason = 'Hold join-node confirmation until the first-node VIP is reachable.'
                }
            }
            return [pscustomobject]@{
                actions = @($enter)
                reason = 'Confirm the reviewed installation configuration.'
            }
        }
        default {
            return $null
        }
    }
}

try {
    foreach ($vmName in $VmNames) {
        Assert-VMDesign -VmName $vmName
    }
    Start-Sleep -Seconds 5

    for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
        Update-VMRuntimeFacts
        $clusterReady = Test-ClusterReady
        if ($clusterReady -and $null -eq $JoinNodesDeadline) {
            $JoinNodesDeadline = (Get-Date).ToUniversalTime().AddMinutes($JoinNodesTimeoutMinutes)
        }

        Write-History -Record ([pscustomobject]@{
            event = 'iteration-start'
            iteration = $iteration
            clusterReady = $clusterReady
            sen1Reachable = $Runtime['sen1'].reachable
            sen2Reachable = $Runtime['sen2'].reachable
            sen3Reachable = $Runtime['sen3'].reachable
        })

        if ($clusterReady -and
            [bool]$Runtime['sen1'].reachable -and
            [bool]$Runtime['sen2'].reachable -and
            [bool]$Runtime['sen3'].reachable) {
            $Passed = $true
            break
        }

        $classifications = Capture-And-ClassifyAll -Iteration $iteration

        foreach ($vmName in $VmNames) {
            $vm = Get-VM -Name $vmName -ErrorAction Stop
            $state = [string]$classifications[$vmName].state
            $isJoinNode = $vmName -ne 'sen1'

            if ([bool]$Runtime[$vmName].reachable -and $state -eq 'BOOTED_SYSTEM') {
                $Runtime[$vmName].bootedFromDisk = $true
                continue
            }

            if ($state -eq 'INSTALLER_ERROR') {
                throw "$vmName installer reports an error: $($classifications[$vmName].normalizedText)"
            }

            if ($state -eq 'INSTALLING') {
                $Runtime[$vmName].installationLikelyStarted = $true
                $Runtime[$vmName].installationConfirmedByScreen = $true
                continue
            }

            if ($state -eq 'INSTALL_COMPLETE') {
                $Runtime[$vmName].installationLikelyStarted = $true
                $Runtime[$vmName].installationConfirmedByScreen = $true
                Set-DiskBoot -VmName $vmName -Reason 'Installer completion/reboot text was detected.'
                Start-Sleep -Seconds 10
                continue
            }

            if ($state -eq 'BOOTED_SYSTEM') {
                if ([bool]$Runtime[$vmName].installationLikelyStarted -or [bool]$Runtime[$vmName].diskBootPrepared) {
                    $Runtime[$vmName].bootedFromDisk = $true
                    continue
                }
                # The candidate ISO may display Harvester branding in its live environment.
                # Do not infer successful installation without disk-growth or reachability evidence.
            }

            if ($state -eq 'INSTALLER_MENU_OR_UNKNOWN') {
                if ([bool]$Runtime[$vmName].installationLikelyStarted -or
                    [bool]$Runtime[$vmName].installationConfirmationSent -or
                    [bool]$Runtime[$vmName].uptimeResetObserved) {
                    Set-DiskBoot -VmName $vmName -Reason 'Installer media reappeared after installation evidence existed.'
                    Start-Sleep -Seconds 10
                    continue
                }
                if ([int]$Runtime[$vmName].unknownCount -le 2) {
                    Invoke-ConsoleAction -VmName $vmName -Actions @([ordered]@{ kind = 'key'; code = 13 }) `
                        -Reason 'Start the installer from its boot/menu screen.' -Iteration $iteration
                    Start-Sleep -Seconds 5
                    continue
                }
                throw "$vmName remained on an unclassified installer screen."
            }

            if ($state -eq 'BLANK_OR_BOOTING') {
                if ($vm.State -eq 'Off') {
                    if ([bool]$Runtime[$vmName].installationLikelyStarted) {
                        Set-DiskBoot -VmName $vmName -Reason 'VM powered off after installation evidence existed.'
                    }
                    else {
                        Start-VM -Name $vmName | Out-Null
                    }
                }
                continue
            }

            if ($state -in @('NETWORK', 'INSTALL_DISK', 'DATA_DISK', 'INSTALLATION_MODE')) {
                throw "$vmName returned to unsafe early installer state '$state'; refusing to overwrite prior network/disk selections."
            }

            if ($state -eq 'UNKNOWN') {
                if ([int]$Runtime[$vmName].unknownCount -le 3) {
                    Write-History -Record ([pscustomobject]@{
                        event = 'unknown-screen-held'
                        iteration = $iteration
                        vm = $vmName
                        unknownCount = $Runtime[$vmName].unknownCount
                    })
                    continue
                }
                throw "$vmName console remained unknown for more than three captures. OCR text: $($classifications[$vmName].normalizedText)"
            }

            $safe = Get-SafeActions -VmName $vmName -State $state -ClusterReady $clusterReady
            if ($null -eq $safe) {
                throw "$vmName reached recognized but unsupported state '$state'."
            }
            if ($state -eq 'REVIEW_OR_CONFIRM' -and @($safe.actions).Count -gt 0) {
                if ([int]$Runtime[$vmName].sameStateCount -gt 3) {
                    throw "$vmName remained on the review/confirmation screen after three confirmation attempts."
                }
                $Runtime[$vmName].installationConfirmationSent = $true
                $Runtime[$vmName].installationConfirmationSentAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                $Runtime[$vmName].installationLikelyStarted = $true
            }
            elseif ([int]$Runtime[$vmName].sameStateCount -gt 2 -and @($safe.actions).Count -gt 0) {
                throw "$vmName remained on '$state' after two identical actions; stopping rather than repeating secrets or text."
            }

            if (@($safe.actions).Count -gt 0) {
                Invoke-ConsoleAction -VmName $vmName -Actions @($safe.actions) `
                    -Reason ([string]$safe.reason) -Iteration $iteration
                Start-Sleep -Seconds 3
            }
            else {
                Write-History -Record ([pscustomobject]@{
                    event = 'action-held'
                    iteration = $iteration
                    vm = $vmName
                    state = $state
                    reason = [string]$safe.reason
                })
            }
        }

        if (-not (Test-ClusterReady) -and (Get-Date).ToUniversalTime() -gt $FirstNodeDeadline) {
            throw "Cluster VIP $ClusterVip did not become reachable within $FirstNodeTimeoutMinutes minutes."
        }
        if ($null -ne $JoinNodesDeadline -and
            (Get-Date).ToUniversalTime() -gt $JoinNodesDeadline -and
            (-not [bool]$Runtime['sen2'].reachable -or -not [bool]$Runtime['sen3'].reachable)) {
            throw "Join nodes did not become reachable within $JoinNodesTimeoutMinutes minutes after the VIP became reachable."
        }
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $Passed) {
        throw "Autopilot reached $MaxIterations iterations without the VIP and all three node IPs becoming reachable."
    }
}
catch {
    $Failure = $_.Exception.Message
    Write-History -Record ([pscustomobject]@{
        event = 'failure'
        error = $Failure
    })
    throw
}
finally {
    Update-VMRuntimeFacts
    $finished = (Get-Date).ToUniversalTime()
    $summary = [ordered]@{
        schemaVersion = '4.0'
        startedAtUtc = $StartTime.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $StartTime).TotalSeconds
        clusterVip = $ClusterVip
        clusterReady = Test-ClusterReady
        passed = $Passed
        failure = $Failure
        userAuthorizedDiskInstallation = $true
        credentialValuesRetainedInEvidence = $false
        virtualMachines = @($VmNames | ForEach-Object { $Runtime[$_] })
        installationQualificationOnly = $true
        productionReleaseApproved = $false
        airgapQualified = $false
        haQualified = $false
    }
    $summary | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $SummaryPath -Encoding UTF8

    @"
# LayerSentry installer autopilot v4

- Started: $($summary.startedAtUtc)
- Finished: $($summary.finishedAtUtc)
- Duration: $($summary.durationSeconds) seconds
- Cluster VIP: $ClusterVip
- Cluster VIP reachable: $($summary.clusterReady)
- All-node installation probe passed: $($summary.passed)
- Credential values retained in evidence: **false**
- Failure: $($summary.failure)

This result covers only the user-authorized POC installation workflow. It does
not by itself approve production release, air-gap operation, HA, upgrade,
backup/restore, storage, VM workload, or recovery qualification.
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}
