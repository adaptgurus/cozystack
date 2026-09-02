[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen1', 'sen2', 'sen3'),
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-installer-autopilot'),
    [ValidateRange(1, 180)]
    [int]$MaxIterations = 120,
    [ValidateRange(3, 120)]
    [int]$PollSeconds = 12,
    [ValidateRange(10, 180)]
    [int]$ClusterReadyTimeoutMinutes = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedVmNames = @('sen1', 'sen2', 'sen3')
if (@($VmNames).Count -ne 3 -or (@($VmNames | Sort-Object) -join ',') -ne (@($ExpectedVmNames | Sort-Object) -join ',')) {
    throw 'Autopilot is restricted to exactly sen1, sen2, and sen3.'
}

$CaptureScript = Join-Path $PSScriptRoot 'capture-hyperv-console.ps1'
$OcrScript = Join-Path $PSScriptRoot 'read-console-ocr.ps1'
$ClassifierScript = Join-Path $PSScriptRoot 'classify-harvester-installer-screen.ps1'
$CommandScript = Join-Path $PSScriptRoot 'invoke-hyperv-console-command.ps1'
$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json'
$ClusterVip = '10.10.10.10'
$NodeAddresses = [ordered]@{
    sen1 = '10.10.10.11'
    sen2 = '10.10.10.12'
    sen3 = '10.10.10.13'
}

foreach ($path in @($CaptureScript, $OcrScript, $ClassifierScript, $CommandScript, $CredentialPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required autopilot input is missing: $path"
    }
}

foreach ($vmName in $VmNames) {
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    if ($vm.Generation -ne 2) {
        throw "$vmName is not a Generation 2 UEFI VM."
    }
    $processor = Get-VMProcessor -VMName $vmName
    if ($processor.Count -ne 10) {
        throw "$vmName has $($processor.Count) vCPU; expected 10."
    }
    if (-not $processor.ExposeVirtualizationExtensions) {
        throw "$vmName does not expose virtualization extensions."
    }
    if ([int64]$vm.MemoryStartup -ne 32GB -or $vm.DynamicMemoryEnabled) {
        throw "$vmName must have exactly 32 GiB static startup memory."
    }
    $disks = @(Get-VMHardDiskDrive -VMName $vmName | Sort-Object ControllerNumber, ControllerLocation)
    if ($disks.Count -lt 2) {
        throw "$vmName has fewer than two attached hard disks."
    }
    $osVhd = Get-VHD -Path $disks[0].Path
    $dataVhd = Get-VHD -Path $disks[1].Path
    if ($osVhd.Size -lt 250GB) {
        throw "$vmName installation disk is smaller than 250 GiB."
    }
    if ($dataVhd.Size -lt 300GB) {
        throw "$vmName data disk is smaller than 300 GiB."
    }
    if ((Get-VMNetworkAdapter -VMName $vmName | Select-Object -First 1).MacAddressSpoofing -ne 'On') {
        throw "$vmName does not have MAC-address spoofing enabled."
    }
    if ($vm.State -eq 'Off') {
        Start-VM -Name $vmName | Out-Null
    }
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$HistoryPath = Join-Path $OutputDirectory 'autopilot-history.jsonl'
$SummaryPath = Join-Path $OutputDirectory 'autopilot-summary.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$StartTime = Get-Date

$Runtime = @{}
foreach ($vmName in $VmNames) {
    $Runtime[$vmName] = [ordered]@{
        vm = $vmName
        lastState = $null
        repeatCount = 0
        actionsSent = 0
        installationStarted = $false
        installationStartedAt = $null
        diskBootPrepared = $false
        diskBootPreparedAt = $null
        bootedFromDisk = $false
        completed = $false
        lastClassification = $null
        lastOcrText = $null
        lastCapture = $null
    }
}

function Write-HistoryRecord {
    param([Parameter(Mandatory = $true)][hashtable]$Record)
    $Record.timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    ($Record | ConvertTo-Json -Compress -Depth 12) |
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

function Test-ClusterReady {
    return (Test-TcpPort -Address $ClusterVip -Port 443) -or
        (Test-TcpPort -Address $ClusterVip -Port 6443)
}

function Invoke-SafeConsoleAction {
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
    $requestPath = Join-Path $requestDirectory ('{0:D3}-{1}.json' -f $Iteration, $VmName)
    $request = [ordered]@{
        requestId = "autopilot-$Iteration-$VmName"
        delayAfterSeconds = 2
        targets = @(
            [ordered]@{
                vm = $VmName
                actions = @($Actions)
            }
        )
    }
    $request | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $requestPath -Encoding UTF8

    & $CommandScript -RequestPath $requestPath -OutputDirectory $resultDirectory
    $Runtime[$VmName].actionsSent++
    Write-HistoryRecord -Record @{
        event = 'console-action'
        iteration = $Iteration
        vm = $VmName
        reason = $Reason
        actionKinds = @($Actions | ForEach-Object { [string]$_.kind })
        secretValuesLogged = $false
    }
}

function Set-VMToDiskBoot {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    if ($Runtime[$VmName].diskBootPrepared) {
        return
    }

    Write-HistoryRecord -Record @{
        event = 'prepare-disk-boot'
        vm = $VmName
        reason = $Reason
    }

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(2)
        while ((Get-VM -Name $VmName).State -ne 'Off') {
            if ((Get-Date) -gt $deadline) {
                throw "Timed out stopping $VmName before changing boot media."
            }
            Start-Sleep -Seconds 2
        }
    }

    $osDisk = Get-VMHardDiskDrive -VMName $VmName |
        Sort-Object ControllerNumber, ControllerLocation |
        Select-Object -First 1
    if ($null -eq $osDisk) {
        throw "No OS disk was found for $VmName."
    }
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDisk
    foreach ($dvd in @(Get-VMDvdDrive -VMName $VmName)) {
        if (-not [string]::IsNullOrWhiteSpace($dvd.Path)) {
            Set-VMDvdDrive -VMName $VmName `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $null
        }
    }
    Start-VM -Name $VmName | Out-Null
    $Runtime[$VmName].diskBootPrepared = $true
    $Runtime[$VmName].diskBootPreparedAt = (Get-Date).ToUniversalTime().ToString('o')
}

function Get-InstallerState {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][int]$Iteration
    )

    $iterationDirectory = Join-Path $OutputDirectory ('iteration-{0:D3}' -f $Iteration)
    $captureDirectory = Join-Path $iterationDirectory 'consoles'
    $stateDirectory = Join-Path $iterationDirectory 'states'
    New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null

    & $CaptureScript -VmNames @($VmName) -OutputDirectory $captureDirectory
    $image = Join-Path $captureDirectory "$VmName-console.png"
    $ocrPath = Join-Path $stateDirectory "$VmName-ocr.json"
    $statePath = Join-Path $stateDirectory "$VmName-state.json"

    & $OcrScript -ImagePath $image -LanguageTag 'en-US' |
        Set-Content -LiteralPath $ocrPath -Encoding UTF8
    & $ClassifierScript -OcrJsonPath $ocrPath |
        Set-Content -LiteralPath $statePath -Encoding UTF8

    $ocr = Get-Content -LiteralPath $ocrPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $classification = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Runtime[$VmName].lastClassification = $classification
    $Runtime[$VmName].lastOcrText = [string]$ocr.text
    $Runtime[$VmName].lastCapture = $image

    $state = [string]$classification.state
    if ($Runtime[$VmName].lastState -eq $state) {
        $Runtime[$VmName].repeatCount++
    }
    else {
        $Runtime[$VmName].lastState = $state
        $Runtime[$VmName].repeatCount = 1
    }

    Write-HistoryRecord -Record @{
        event = 'screen-classification'
        iteration = $Iteration
        vm = $VmName
        state = $state
        confidence = [string]$classification.confidence
        reason = [string]$classification.reason
        repeatCount = $Runtime[$VmName].repeatCount
        ocrText = [string]$ocr.text
    }
    return $classification
}

function Get-ActionForState {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][int]$Iteration,
        [Parameter(Mandatory = $true)][bool]$ClusterReady
    )

    $enter = @([ordered]@{ kind = 'key'; code = 13 })
    switch ($State) {
        'CLUSTER_TOKEN' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'secret'; name = 'clusterToken' }, $enter[0])
                reason = 'Enter the locally protected common cluster token.'
            }
        }
        'NTP_SERVERS' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'text'; value = 'time.cloudflare.com,time.google.com' }, $enter[0])
                reason = 'Configure two public NTP sources for the connected POC.'
            }
        }
        'TIMEZONE' {
            return [ordered]@{
                actions = $enter
                reason = 'Accept the installer default UTC timezone.'
            }
        }
        'PROXY' {
            return [ordered]@{
                actions = $enter
                reason = 'Leave proxy configuration empty on the direct-NAT POC network.'
            }
        }
        'SSH_KEY' {
            return [ordered]@{
                actions = $enter
                reason = 'Leave the optional SSH public key blank for this console-controlled POC.'
            }
        }
        'PASSWORD' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'secret'; name = 'nodePassword' }, $enter[0])
                reason = 'Enter the locally protected node password.'
            }
        }
        'CONFIRM_PASSWORD' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'secret'; name = 'nodePassword' }, $enter[0])
                reason = 'Confirm the locally protected node password.'
            }
        }
        'VIP_OR_MANAGEMENT_ADDRESS' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'text'; value = $ClusterVip }, $enter[0])
                reason = 'Use the approved LayerSentry cluster VIP or join address.'
            }
        }
        'DNS_SERVERS' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'text'; value = '8.8.8.8,1.1.1.1' }, $enter[0])
                reason = 'Configure the connected-POC DNS resolvers.'
            }
        }
        'HOSTNAME' {
            return [ordered]@{
                actions = @([ordered]@{ kind = 'text'; value = $VmName }, $enter[0])
                reason = 'Set the node hostname equal to its Hyper-V VM name.'
            }
        }
        'REVIEW_OR_INSTALL_CONFIRMATION' {
            if ($VmName -ne 'sen1' -and -not $ClusterReady) {
                return [ordered]@{
                    actions = @()
                    reason = 'Hold join-node installation until the first-node VIP is reachable.'
                }
            }
            if ($Runtime[$VmName].repeatCount -gt 3) {
                throw "$VmName remained on the installation review/confirmation screen after three Enter actions."
            }
            $Runtime[$VmName].installationStarted = $true
            if ($null -eq $Runtime[$VmName].installationStartedAt) {
                $Runtime[$VmName].installationStartedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
            return [ordered]@{
                actions = $enter
                reason = 'Confirm the reviewed installation configuration.'
            }
        }
        default {
            return $null
        }
    }
}

$terminalStates = @('BOOTED_OR_LOGIN')
$pass = $false
$failureMessage = $null
try {
    for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
        $clusterReady = Test-ClusterReady
        Write-HistoryRecord -Record @{
            event = 'iteration-start'
            iteration = $iteration
            clusterReady = $clusterReady
        }

        foreach ($vmName in $VmNames) {
            $vm = Get-VM -Name $vmName -ErrorAction Stop

            if ($Runtime[$vmName].installationStarted -and $vm.State -eq 'Off') {
                Set-VMToDiskBoot -VmName $vmName -Reason 'VM powered off after installation started.'
                Start-Sleep -Seconds 8
            }
            elseif ($vm.State -eq 'Off' -and -not $Runtime[$vmName].completed) {
                Start-VM -Name $vmName | Out-Null
                Start-Sleep -Seconds 8
            }

            $classification = Get-InstallerState -VmName $vmName -Iteration $iteration
            $state = [string]$classification.state
            $confidence = [string]$classification.confidence

            if ($confidence -eq 'low' -and $state -notin @('INSTALLING', 'INSTALLER_UNCLASSIFIED')) {
                throw "$vmName screen classification is low confidence: $state."
            }

            if ($state -eq 'INSTALL_COMPLETE') {
                Start-Sleep -Seconds 15
                Set-VMToDiskBoot -VmName $vmName -Reason 'Installer reported completion or reboot.'
                Start-Sleep -Seconds 10
                continue
            }

            if ($state -eq 'INSTALLING') {
                if (-not $Runtime[$vmName].installationStarted) {
                    $Runtime[$vmName].installationStarted = $true
                    $Runtime[$vmName].installationStartedAt = (Get-Date).ToUniversalTime().ToString('o')
                }
                continue
            }

            if ($Runtime[$vmName].installationStarted -and
                -not $Runtime[$vmName].diskBootPrepared -and
                $state -in @('INSTALLATION_MODE', 'INSTALLER_UNCLASSIFIED')) {
                $startedAt = [DateTime]::Parse([string]$Runtime[$vmName].installationStartedAt)
                if (((Get-Date).ToUniversalTime() - $startedAt).TotalMinutes -ge 8) {
                    Set-VMToDiskBoot -VmName $vmName -Reason 'Installer media appeared again after installation started.'
                    Start-Sleep -Seconds 10
                    continue
                }
            }

            if ($state -in $terminalStates) {
                if ($Runtime[$vmName].diskBootPrepared -or $Runtime[$vmName].installationStarted) {
                    $Runtime[$vmName].bootedFromDisk = $true
                    if ($NodeAddresses.Contains($vmName)) {
                        $Runtime[$vmName].completed = Test-TcpPort -Address $NodeAddresses[$vmName] -Port 22 -TimeoutMilliseconds 1000
                    }
                }
                continue
            }

            if ($state -in @(
                'UNKNOWN',
                'NETWORK_CONFIGURATION',
                'INSTALLATION_MODE',
                'INSTALL_DISK',
                'DATA_DISK',
                'INSTALLER_UNCLASSIFIED'
            )) {
                throw "$vmName reached an unhandled or unsafe installer state: $state."
            }

            if ($Runtime[$vmName].repeatCount -gt 2 -and
                $state -notin @('REVIEW_OR_INSTALL_CONFIRMATION')) {
                throw "$vmName remained on $state after two actions; stopping rather than guessing."
            }

            $action = Get-ActionForState `
                -VmName $vmName `
                -State $state `
                -Iteration $iteration `
                -ClusterReady $clusterReady
            if ($null -eq $action) {
                throw "$vmName reached a recognized but unsupported state: $state."
            }
            if (@($action.actions).Count -gt 0) {
                Invoke-SafeConsoleAction `
                    -VmName $vmName `
                    -Actions @($action.actions) `
                    -Reason ([string]$action.reason) `
                    -Iteration $iteration
                Start-Sleep -Seconds 3
            }
            else {
                Write-HistoryRecord -Record @{
                    event = 'action-held'
                    iteration = $iteration
                    vm = $vmName
                    state = $state
                    reason = [string]$action.reason
                }
            }
        }

        $clusterReady = Test-ClusterReady
        $nodesReady = @($VmNames | ForEach-Object {
            Test-TcpPort -Address $NodeAddresses[$_] -Port 22 -TimeoutMilliseconds 1000
        })
        if ($clusterReady -and (@($nodesReady | Where-Object { $_ }).Count -eq 3)) {
            foreach ($vmName in $VmNames) {
                $Runtime[$vmName].completed = $true
            }
            $pass = $true
            break
        }

        if ($Runtime['sen1'].installationStartedAt) {
            $sen1Started = [DateTime]::Parse([string]$Runtime['sen1'].installationStartedAt)
            if (((Get-Date).ToUniversalTime() - $sen1Started).TotalMinutes -gt $ClusterReadyTimeoutMinutes -and -not $clusterReady) {
                throw "Cluster VIP $ClusterVip did not become reachable within $ClusterReadyTimeoutMinutes minutes of starting sen1 installation."
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $pass) {
        throw "Autopilot reached the maximum of $MaxIterations iterations without all nodes and the VIP becoming reachable."
    }
}
catch {
    $failureMessage = $_.Exception.Message
    Write-HistoryRecord -Record @{
        event = 'failure'
        error = $failureMessage
    }
    throw
}
finally {
    $finishedAt = Get-Date
    $summary = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $StartTime.ToUniversalTime().ToString('o')
        finishedAtUtc = $finishedAt.ToUniversalTime().ToString('o')
        durationSeconds = [int64]($finishedAt - $StartTime).TotalSeconds
        clusterVip = $ClusterVip
        clusterReady = Test-ClusterReady
        passed = $pass
        failure = $failureMessage
        containsCredentialValues = $false
        installationAuthorized = $true
        virtualMachines = @($VmNames | ForEach-Object { $Runtime[$_] })
    }
    $summary | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $SummaryPath -Encoding UTF8

    @"
# LayerSentry three-node installer autopilot

- Started: $($summary.startedAtUtc)
- Finished: $($summary.finishedAtUtc)
- Duration: $($summary.durationSeconds) seconds
- Cluster VIP: $ClusterVip
- Cluster ready: $($summary.clusterReady)
- Autopilot passed: $($summary.passed)
- Credential values retained in evidence: **false**
- Failure: $($summary.failure)

This workflow performs the user-authorized POC installation only. A successful
installation does not by itself grant production, air-gap, HA, upgrade, backup,
or release qualification.
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}
