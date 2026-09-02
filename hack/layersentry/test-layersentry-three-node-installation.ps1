[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-three-node-qualification'),
    [ValidateRange(5, 180)]
    [int]$WaitMinutes = 90,
    [ValidateRange(5, 60)]
    [int]$PollSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$VmNames = @('sen1', 'sen2', 'sen3')
$NodeAddresses = [ordered]@{
    sen1 = '10.10.10.11'
    sen2 = '10.10.10.12'
    sen3 = '10.10.10.13'
}
$ClusterVip = '10.10.10.10'
$CaptureScript = Join-Path $PSScriptRoot 'capture-hyperv-console.ps1'

if (-not (Test-Path -LiteralPath $CaptureScript -PathType Leaf)) {
    throw "Console capture script is missing: $CaptureScript"
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$TimelinePath = Join-Path $OutputDirectory 'probe-timeline.jsonl'
$ResultPath = Join-Path $OutputDirectory 'qualification-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Deadline = $Start.AddMinutes($WaitMinutes)
$Passed = $false
$Failure = $null

function Write-Timeline {
    param([Parameter(Mandatory = $true)][object]$Record)
    $ordered = [ordered]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($property in $Record.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }
    ($ordered | ConvertTo-Json -Compress -Depth 12) |
        Add-Content -LiteralPath $TimelinePath -Encoding UTF8
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

function Get-HttpsProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [int]$TimeoutSeconds = 10
    )

    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.UserAgent = 'LayerSentry-Qualification/1.0'
        try {
            $response = [System.Net.HttpWebResponse]$request.GetResponse()
            try {
                return [ordered]@{
                    uri = $Uri
                    reachable = $true
                    statusCode = [int]$response.StatusCode
                    statusDescription = $response.StatusDescription
                    location = $response.Headers['Location']
                    server = $response.Headers['Server']
                    error = $null
                }
            }
            finally {
                $response.Close()
            }
        }
        catch [System.Net.WebException] {
            $webException = $_.Exception
            if ($null -ne $webException.Response) {
                $response = [System.Net.HttpWebResponse]$webException.Response
                try {
                    return [ordered]@{
                        uri = $Uri
                        reachable = $true
                        statusCode = [int]$response.StatusCode
                        statusDescription = $response.StatusDescription
                        location = $response.Headers['Location']
                        server = $response.Headers['Server']
                        error = $webException.Message
                    }
                }
                finally {
                    $response.Close()
                }
            }
            return [ordered]@{
                uri = $Uri
                reachable = $false
                statusCode = $null
                statusDescription = $null
                location = $null
                server = $null
                error = $webException.Message
            }
        }
    }
    finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    }
}

function Get-VMRecord {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $processor = Get-VMProcessor -VMName $VmName -ErrorAction Stop
    $firmware = Get-VMFirmware -VMName $VmName -ErrorAction Stop
    $adapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop |
        Select-Object -First 1
    $disks = @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop |
        Sort-Object ControllerNumber, ControllerLocation |
        ForEach-Object {
            $vhd = Get-VHD -Path $_.Path -ErrorAction Stop
            [ordered]@{
                path = $_.Path
                maximumBytes = [int64]$vhd.Size
                currentFileBytes = [int64]$vhd.FileSize
                type = $vhd.VhdType.ToString()
                controllerNumber = $_.ControllerNumber
                controllerLocation = $_.ControllerLocation
            }
        })
    $dvd = @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
        ForEach-Object {
            [ordered]@{
                path = $_.Path
                mediaAttached = -not [string]::IsNullOrWhiteSpace($_.Path)
            }
        })
    $firstBootType = $null
    $firstBootPath = $null
    if ($firmware.BootOrder.Count -gt 0) {
        $first = $firmware.BootOrder[0]
        $firstBootType = $first.BootType.ToString()
        if ($first.PSObject.Properties['Device'] -and $null -ne $first.Device) {
            if ($first.Device.PSObject.Properties['Path']) {
                $firstBootPath = $first.Device.Path
            }
        }
    }

    $address = $NodeAddresses[$VmName]
    return [ordered]@{
        name = $VmName
        expectedAddress = $address
        exists = $true
        state = $vm.State.ToString()
        status = $vm.Status
        uptimeSeconds = [int64]$vm.Uptime.TotalSeconds
        generation = $vm.Generation
        processorCount = $processor.Count
        exposeVirtualizationExtensions = [bool]$processor.ExposeVirtualizationExtensions
        startupMemoryBytes = [int64]$vm.MemoryStartup
        assignedMemoryBytes = [int64]$vm.MemoryAssigned
        dynamicMemoryEnabled = [bool]$vm.DynamicMemoryEnabled
        secureBoot = $firmware.SecureBoot.ToString()
        firstBootType = $firstBootType
        firstBootPath = $firstBootPath
        switchName = $adapter.SwitchName
        macAddress = $adapter.MacAddress
        macAddressSpoofing = $adapter.MacAddressSpoofing.ToString()
        hyperVReportedAddresses = @($adapter.IPAddresses)
        ping = Test-Ping -Address $address
        ssh22 = Test-TcpPort -Address $address -Port 22
        rke2Supervisor9345 = Test-TcpPort -Address $address -Port 9345
        kubeApi6443 = Test-TcpPort -Address $address -Port 6443
        disks = $disks
        dvdDrives = $dvd
    }
}

function Ensure-DiskBootAndNoIso {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $dvdWithMedia = @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) })
    $firmware = Get-VMFirmware -VMName $VmName -ErrorAction Stop
    $osDisk = Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop |
        Sort-Object ControllerNumber, ControllerLocation |
        Select-Object -First 1

    $mustChange = $dvdWithMedia.Count -gt 0
    if (-not $mustChange -and $firmware.BootOrder.Count -gt 0) {
        $first = $firmware.BootOrder[0]
        if ($first.BootType.ToString() -ne 'Drive') {
            $mustChange = $true
        }
    }
    if (-not $mustChange) {
        return
    }

    $wasRunning = $vm.State -eq 'Running'
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-VM -Name $VmName).State -ne 'Off') {
            if ((Get-Date) -gt $deadline) {
                throw "Timed out stopping $VmName to finalize boot order."
            }
            Start-Sleep -Seconds 2
        }
    }
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDisk
    foreach ($dvd in $dvdWithMedia) {
        Set-VMDvdDrive -VMName $VmName `
            -ControllerNumber $dvd.ControllerNumber `
            -ControllerLocation $dvd.ControllerLocation `
            -Path $null
    }
    if ($wasRunning -or (Get-VM -Name $VmName).State -eq 'Off') {
        Start-VM -Name $VmName | Out-Null
    }
    Write-Timeline -Record ([pscustomobject]@{
        event = 'boot-finalized'
        vm = $VmName
        isoDetached = $true
        osDiskFirst = $true
    })
}

try {
    $iteration = 0
    do {
        $iteration++
        $records = @($VmNames | ForEach-Object { Get-VMRecord -VmName $_ })
        $vip443 = Test-TcpPort -Address $ClusterVip -Port 443
        $vip6443 = Test-TcpPort -Address $ClusterVip -Port 6443
        $nodeReachableCount = @($records | Where-Object { $_.ping -or $_.ssh22 }).Count
        Write-Timeline -Record ([pscustomobject]@{
            event = 'probe'
            iteration = $iteration
            vip443 = $vip443
            vip6443 = $vip6443
            nodeReachableCount = $nodeReachableCount
            nodes = @($records | ForEach-Object {
                [ordered]@{
                    name = $_.name
                    ping = $_.ping
                    ssh22 = $_.ssh22
                    rke2Supervisor9345 = $_.rke2Supervisor9345
                    kubeApi6443 = $_.kubeApi6443
                    osVhdFileBytes = $_.disks[0].currentFileBytes
                    dvdMediaAttached = @($_.dvdDrives | Where-Object { $_.mediaAttached }).Count -gt 0
                }
            })
        })

        if (($vip443 -or $vip6443) -and $nodeReachableCount -eq 3) {
            $Passed = $true
            break
        }
        if ((Get-Date).ToUniversalTime() -ge $Deadline) {
            throw "VIP and three-node reachability did not pass within $WaitMinutes minutes."
        }
        Start-Sleep -Seconds $PollSeconds
    } while ($true)

    foreach ($vmName in $VmNames) {
        Ensure-DiskBootAndNoIso -VmName $vmName
    }
    Start-Sleep -Seconds 20

    $finalRecords = @($VmNames | ForEach-Object { Get-VMRecord -VmName $_ })
    $uiProbe = Get-HttpsProbe -Uri "https://$ClusterVip/"
    $apiProbe = Get-HttpsProbe -Uri "https://$ClusterVip/v1/harvester"
    $vip443 = Test-TcpPort -Address $ClusterVip -Port 443
    $vip6443 = Test-TcpPort -Address $ClusterVip -Port 6443

    if (-not ($vip443 -or $vip6443)) {
        throw 'Cluster VIP stopped responding after boot-media finalization.'
    }
    if (@($finalRecords | Where-Object { -not ($_.ping -or $_.ssh22) }).Count -ne 0) {
        throw 'One or more nodes stopped responding after boot-media finalization.'
    }
    if (-not [bool]$uiProbe.reachable) {
        throw 'The LayerSentry/Harvester HTTPS UI endpoint is not reachable.'
    }
}
catch {
    $Failure = $_.Exception.Message
    Write-Timeline -Record ([pscustomobject]@{
        event = 'failure'
        error = $Failure
    })
    throw
}
finally {
    $consoleDirectory = Join-Path $OutputDirectory 'final-consoles'
    try {
        & $CaptureScript -VmNames $VmNames -OutputDirectory $consoleDirectory
    }
    catch {
        Write-Timeline -Record ([pscustomobject]@{
            event = 'console-capture-failure'
            error = $_.Exception.Message
        })
    }

    $finalRecords = @()
    foreach ($vmName in $VmNames) {
        try {
            $finalRecords += Get-VMRecord -VmName $vmName
        }
        catch {
            $finalRecords += [ordered]@{
                name = $vmName
                exists = $false
                error = $_.Exception.Message
            }
        }
    }
    $uiProbe = Get-HttpsProbe -Uri "https://$ClusterVip/"
    $apiProbe = Get-HttpsProbe -Uri "https://$ClusterVip/v1/harvester"
    $finished = (Get-Date).ToUniversalTime()
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        passed = $Passed -and $null -eq $Failure
        failure = $Failure
        clusterVip = $ClusterVip
        vipHttps443 = Test-TcpPort -Address $ClusterVip -Port 443
        vipKubernetes6443 = Test-TcpPort -Address $ClusterVip -Port 6443
        uiProbe = $uiProbe
        harvesterApiProbe = $apiProbe
        virtualMachines = $finalRecords
        installationQualified = $Passed -and $null -eq $Failure
        productionReleaseApproved = $false
        trueAirgapQualified = $false
        haQualified = $false
        upgradeQualified = $false
        backupRestoreQualified = $false
        workloadQualified = $false
    }
    $result | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry three-node installation qualification

- Started: $($result.startedAtUtc)
- Finished: $($result.finishedAtUtc)
- Duration: $($result.durationSeconds) seconds
- VIP HTTPS 443: $($result.vipHttps443)
- VIP Kubernetes 6443: $($result.vipKubernetes6443)
- HTTPS UI reachable: $($result.uiProbe.reachable)
- Installation qualification passed: $($result.installationQualified)
- Production release approved: **false**
- True air-gap qualified: **false**
- HA qualified: **false**
- Upgrade qualified: **false**
- Backup/restore qualified: **false**
- Workload qualified: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}
