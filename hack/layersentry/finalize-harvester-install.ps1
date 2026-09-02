[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._/-]+$')]
    [string]$PublishBranch,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-RunLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Test-IpAddress {
    param([Parameter(Mandatory = $true)][string]$Address)
    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)
}

function Test-IcmpAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [int]$TimeoutMilliseconds = 1000
    )
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($Address, $TimeoutMilliseconds)
        return $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
    }
    catch {
        return $false
    }
    finally {
        $ping.Dispose()
    }
}

function Test-TcpAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [int]$TimeoutMilliseconds = 1200
    )
    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $asyncResult = $client.BeginConnect($Address, $Port, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($asyncResult)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $waitHandle) {
            $waitHandle.Close()
        }
        $client.Close()
        $client.Dispose()
    }
}

function Get-HttpsCode {
    param([Parameter(Mandatory = $true)][string]$Address)
    $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        return $null
    }
    try {
        $result = & $curl.Source `
            '--insecure' `
            '--silent' `
            '--output' 'NUL' `
            '--write-out' '%{http_code}' `
            '--connect-timeout' '2' `
            '--max-time' '6' `
            "https://$Address/" 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $text = ([string]$result).Trim()
        if ($text -match '^\d{3}$') {
            return [int]$text
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-DriveBySuffix {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][ValidateSet('os', 'data')][string]$Kind
    )
    $suffix = '-{0}\.vhdx$' -f $Kind
    $drives = @(
        Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
                ([string]$_.Path -match "(?i)$suffix")
            }
    )
    if ($drives.Count -ne 1) {
        throw "Expected exactly one $Kind disk ending in -$Kind.vhdx for $VmName; found $($drives.Count)."
    }
    return $drives[0]
}

function Get-DiskMetrics {
    param([Parameter(Mandatory = $true)]$Drive)
    $vhd = Get-VHD -Path $Drive.Path -ErrorAction Stop
    return [ordered]@{
        path = [string]$Drive.Path
        virtualSizeGiB = [math]::Round(([double]$vhd.Size / 1GB), 3)
        fileSizeGiB = [math]::Round(([double]$vhd.FileSize / 1GB), 3)
        type = [string]$vhd.VhdType
    }
}

function Get-DvdPaths {
    param([Parameter(Mandatory = $true)][string]$VmName)
    return @(
        Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
            ForEach-Object { [string]$_.Path } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Stop-VMForBootChange {
    param([Parameter(Mandatory = $true)][string]$VmName)
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ([string]$vm.State -eq 'Off') {
        return
    }

    Write-RunLog "Requesting controlled shutdown of $VmName before changing boot media."
    try {
        Stop-VM -Name $VmName -Force -ErrorAction Stop
    }
    catch {
        Write-RunLog "Controlled shutdown request for $VmName returned: $($_.Exception.Message)"
    }

    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        Start-Sleep -Seconds 1
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ([string]$vm.State -eq 'Off') {
            return
        }
    }

    Write-RunLog "$VmName did not shut down within 90 seconds; using Hyper-V TurnOff for the boot transition."
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 1
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ([string]$vm.State -eq 'Off') {
            return
        }
    }
    throw "$VmName did not reach Off state."
}

function Set-InstalledDiskBoot {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    Write-RunLog "Finalizing installed-disk boot for $VmName; reason=$Reason."
    Stop-VMForBootChange -VmName $VmName

    foreach ($dvd in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dvd.Path)) {
            Set-VMDvdDrive `
                -VMName $VmName `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $null `
                -ErrorAction Stop
        }
    }

    $osDrive = Get-DriveBySuffix -VmName $VmName -Kind 'os'
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDrive -ErrorAction Stop
    Start-VM -Name $VmName -ErrorAction Stop | Out-Null
    Write-RunLog "$VmName restarted with its OS VHDX first and installation media ejected."
}

function Get-NodeProbe {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)]$Runtime
    )
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $processor = Get-VMProcessor -VMName $VmName -ErrorAction Stop
    $networkAdapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop)
    $osDrive = Get-DriveBySuffix -VmName $VmName -Kind 'os'
    $dataDrive = Get-DriveBySuffix -VmName $VmName -Kind 'data'
    $osDisk = Get-DiskMetrics -Drive $osDrive
    $dataDisk = Get-DiskMetrics -Drive $dataDrive
    $dvdPaths = Get-DvdPaths -VmName $VmName

    $ping = Test-IcmpAddress -Address $Address
    $tcp22 = Test-TcpAddress -Address $Address -Port 22
    $tcp9345 = Test-TcpAddress -Address $Address -Port 9345
    $tcp10250 = Test-TcpAddress -Address $Address -Port 10250
    $serviceCount = @($tcp22, $tcp9345, $tcp10250 | Where-Object { $_ }).Count
    $online = (
        [string]$vm.State -eq 'Running' -and
        $dvdPaths.Count -eq 0 -and
        ($ping -or $serviceCount -ge 1) -and
        $serviceCount -ge 2
    )

    return [ordered]@{
        expectedIPAddress = $Address
        vmState = [string]$vm.State
        uptimeSeconds = [int64]$vm.Uptime.TotalSeconds
        cpuCount = [int]$processor.Count
        exposeVirtualizationExtensions = [bool]$processor.ExposeVirtualizationExtensions
        startupMemoryGiB = [math]::Round(([double]$vm.MemoryStartup / 1GB), 2)
        assignedMemoryGiB = [math]::Round(([double]$vm.MemoryAssigned / 1GB), 2)
        dynamicMemoryEnabled = [bool]$vm.DynamicMemoryEnabled
        switchNames = @($networkAdapters | ForEach-Object { [string]$_.SwitchName })
        macAddressSpoofing = @($networkAdapters | ForEach-Object { [string]$_.MacAddressSpoofing })
        dvdAttached = ($dvdPaths.Count -gt 0)
        dvdPaths = $dvdPaths
        osDisk = $osDisk
        dataDisk = $dataDisk
        bootTransitionCompleted = [bool]$Runtime.BootTransitionCompleted
        bootTransitionReason = $Runtime.BootTransitionReason
        bootTransitionAtUtc = $Runtime.BootTransitionAtUtc
        network = [ordered]@{
            ping = $ping
            tcp22 = $tcp22
            tcp9345 = $tcp9345
            tcp10250 = $tcp10250
            serviceCount = $serviceCount
        }
        online = $online
    }
}

function Assert-VMContract {
    param([Parameter(Mandatory = $true)][string]$VmName)
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $processor = Get-VMProcessor -VMName $VmName -ErrorAction Stop
    $networkAdapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop)
    $osDrive = Get-DriveBySuffix -VmName $VmName -Kind 'os'
    $dataDrive = Get-DriveBySuffix -VmName $VmName -Kind 'data'
    $osDisk = Get-DiskMetrics -Drive $osDrive
    $dataDisk = Get-DiskMetrics -Drive $dataDrive

    if ([int]$processor.Count -ne 10) {
        throw "$VmName CPU count is $($processor.Count); expected 10."
    }
    if ([math]::Abs(([double]$vm.MemoryStartup / 1GB) - 32.0) -gt 0.01) {
        throw "$VmName startup memory is not 32 GiB."
    }
    if ([bool]$vm.DynamicMemoryEnabled) {
        throw "$VmName has dynamic memory enabled; static 32 GiB is required."
    }
    if (-not [bool]$processor.ExposeVirtualizationExtensions) {
        throw "$VmName does not expose nested virtualization extensions."
    }
    if ([math]::Abs([double]$osDisk.virtualSizeGiB - 250.0) -gt 0.1) {
        throw "$VmName OS disk is $($osDisk.virtualSizeGiB) GiB; expected 250 GiB."
    }
    if ([math]::Abs([double]$dataDisk.virtualSizeGiB - 300.0) -gt 0.1) {
        throw "$VmName data disk is $($dataDisk.virtualSizeGiB) GiB; expected 300 GiB."
    }
    if (@($networkAdapters | Where-Object { [string]$_.SwitchName -eq 'Cozystack-NAT' }).Count -lt 1) {
        throw "$VmName is not connected to Cozystack-NAT."
    }
    if (@($networkAdapters | Where-Object { [string]$_.MacAddressSpoofing -eq 'On' }).Count -lt 1) {
        throw "$VmName does not have MAC address spoofing enabled."
    }
}

function Save-Consoles {
    $captureScript = Join-Path $RepositoryRoot 'hack/layersentry/capture-hyperv-console.ps1'
    if (-not (Test-Path -LiteralPath $captureScript -PathType Leaf)) {
        return
    }
    $tempCapture = Join-Path $env:RUNNER_TEMP 'layersentry-finalize-capture'
    if (Test-Path -LiteralPath $tempCapture) {
        Remove-Item -LiteralPath $tempCapture -Recurse -Force
    }
    try {
        & $captureScript -VmNames $script:VmNames -OutputDirectory $tempCapture
        foreach ($name in @('sen1-console.png', 'sen2-console.png', 'sen3-console.png', 'SHA256SUMS.txt')) {
            $source = Join-Path $tempCapture $name
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $OutputDirectory $name) -Force
            }
        }
    }
    catch {
        Write-RunLog "Console capture warning: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $tempCapture) {
            Remove-Item -LiteralPath $tempCapture -Recurse -Force
        }
    }
}

function Publish-Status {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('waiting', 'success', 'timeout', 'failure')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Nodes,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Vip,
        [Parameter(Mandatory = $true)][int]$StablePolls,
        [switch]$CaptureConsoles
    )
    foreach ($marker in @('WAITING', 'SUCCESS', 'TIMEOUT', 'FAILURE')) {
        $path = Join-Path $OutputDirectory $marker
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    New-Item -Path (Join-Path $OutputDirectory $Status.ToUpperInvariant()) -ItemType File -Force | Out-Null

    $document = [ordered]@{
        schemaVersion = '2.0'
        requestId = [string]$script:Request.requestId
        sourceCommit = [string]$env:GITHUB_SHA
        sourceRequest = [string]$RequestPath
        status = $Status
        message = $Message
        startedAtUtc = $script:StartedAt.ToUniversalTime().ToString('o')
        publishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        elapsedMinutes = [math]::Round(((Get-Date) - $script:StartedAt).TotalMinutes, 2)
        stablePolls = $StablePolls
        requiredStablePolls = $script:RequiredStablePolls
        vip = $Vip
        nodes = $Nodes
        credentialsRead = $false
        containsCredentialValues = $false
    }
    $document | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'status.json') -Encoding UTF8

    if ($CaptureConsoles) {
        Save-Consoles
    }

    $relativeOutput = $OutputDirectory.Substring($RepositoryRoot.Length).TrimStart('\', '/')
    & git -C $RepositoryRoot add -- $relativeOutput
    if ($LASTEXITCODE -ne 0) {
        throw "git add failed with exit code $LASTEXITCODE"
    }

    if (-not $script:StatusCommitCreated) {
        & git -C $RepositoryRoot commit -m "ops(status): finalize LayerSentry installation [$Status] [skip ci]"
        if ($LASTEXITCODE -ne 0) {
            throw "status commit failed with exit code $LASTEXITCODE"
        }
        $script:StatusCommitCreated = $true
    }
    else {
        & git -C $RepositoryRoot diff --cached --quiet -- $relativeOutput
        $diffCode = $LASTEXITCODE
        if ($diffCode -eq 1) {
            & git -C $RepositoryRoot commit --amend --no-edit
            if ($LASTEXITCODE -ne 0) {
                throw "status commit amend failed with exit code $LASTEXITCODE"
            }
        }
        elseif ($diffCode -ne 0) {
            throw "git diff failed with exit code $diffCode"
        }
    }

    & git -C $RepositoryRoot push --force origin "HEAD:$PublishBranch"
    if ($LASTEXITCODE -ne 0) {
        throw "status push failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Request file not found: $RequestPath"
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be within RepositoryRoot.'
}

$script:Request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$requiredProperties = @(
    'requestId', 'vmNames', 'expectedNodeIPs', 'vip', 'maxWaitMinutes',
    'pollSeconds', 'publishSeconds', 'minimumObservationMinutes',
    'diskStableSeconds', 'minimumInstalledDiskFileGiB', 'requiredStablePolls'
)
foreach ($name in $requiredProperties) {
    if (-not $script:Request.PSObject.Properties[$name]) {
        throw "Required request property is missing: $name"
    }
}

$script:VmNames = @($script:Request.vmNames | ForEach-Object { [string]$_ })
if ($script:VmNames.Count -ne 3 -or @($script:VmNames | Select-Object -Unique).Count -ne 3) {
    throw 'vmNames must contain exactly three unique names.'
}
foreach ($expected in @('sen1', 'sen2', 'sen3')) {
    if ($script:VmNames -notcontains $expected) {
        throw "vmNames must include $expected."
    }
}

$nodeIpMap = @{}
foreach ($vmName in $script:VmNames) {
    $property = $script:Request.expectedNodeIPs.PSObject.Properties[$vmName]
    if ($null -eq $property) {
        throw "expectedNodeIPs is missing $vmName."
    }
    $address = [string]$property.Value
    if (-not (Test-IpAddress -Address $address)) {
        throw "Invalid expected address for ${vmName}: $address"
    }
    $nodeIpMap[$vmName] = $address
}

$vipAddress = [string]$script:Request.vip
if (-not (Test-IpAddress -Address $vipAddress)) {
    throw "Invalid VIP address: $vipAddress"
}

$maxWaitMinutes = [int]$script:Request.maxWaitMinutes
$pollSeconds = [int]$script:Request.pollSeconds
$publishSeconds = [int]$script:Request.publishSeconds
$minimumObservationMinutes = [int]$script:Request.minimumObservationMinutes
$diskStableSeconds = [int]$script:Request.diskStableSeconds
$minimumInstalledDiskFileGiB = [double]$script:Request.minimumInstalledDiskFileGiB
$script:RequiredStablePolls = [int]$script:Request.requiredStablePolls

if ($maxWaitMinutes -lt 15 -or $maxWaitMinutes -gt 120) { throw 'maxWaitMinutes must be 15..120.' }
if ($pollSeconds -lt 5 -or $pollSeconds -gt 60) { throw 'pollSeconds must be 5..60.' }
if ($publishSeconds -lt 30 -or $publishSeconds -gt 600) { throw 'publishSeconds must be 30..600.' }
if ($minimumObservationMinutes -lt 1 -or $minimumObservationMinutes -gt 30) { throw 'minimumObservationMinutes must be 1..30.' }
if ($diskStableSeconds -lt 60 -or $diskStableSeconds -gt 900) { throw 'diskStableSeconds must be 60..900.' }
if ($minimumInstalledDiskFileGiB -lt 1.0 -or $minimumInstalledDiskFileGiB -gt 30.0) { throw 'minimumInstalledDiskFileGiB must be 1..30.' }
if ($script:RequiredStablePolls -lt 1 -or $script:RequiredStablePolls -gt 10) { throw 'requiredStablePolls must be 1..10.' }

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$script:LogPath = Join-Path $OutputDirectory 'finalize.log'
New-Item -Path $script:LogPath -ItemType File -Force | Out-Null

& git -C $RepositoryRoot config user.name 'github-actions[bot]'
& git -C $RepositoryRoot config user.email '41898282+github-actions[bot]@users.noreply.github.com'
& git -C $RepositoryRoot switch -C 'layersentry-finalize-status-work' $env:GITHUB_SHA
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create local finalization-status branch.'
}

$script:StatusCommitCreated = $false
$script:StartedAt = Get-Date
$lastPublishAt = [datetime]::MinValue
$lastConsoleCaptureAt = [datetime]::MinValue
$stableClusterPolls = 0
$runtime = @{}
$lastNodes = @{}
$lastVip = @{}
$terminalStatus = 'failure'
$terminalMessage = 'Finalization ended unexpectedly.'

try {
    foreach ($vmName in $script:VmNames) {
        Assert-VMContract -VmName $vmName
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $osDrive = Get-DriveBySuffix -VmName $vmName -Kind 'os'
        $osDisk = Get-DiskMetrics -Drive $osDrive
        $dvdPaths = Get-DvdPaths -VmName $vmName
        $runtime[$vmName] = [pscustomobject]@{
            LastState = [string]$vm.State
            LastUptimeSeconds = [int64]$vm.Uptime.TotalSeconds
            LastFileSizeGiB = [double]$osDisk.fileSizeGiB
            StableDiskSeconds = 0
            SeenNotRunning = ([string]$vm.State -ne 'Running')
            BootTransitionCompleted = ($dvdPaths.Count -eq 0)
            BootTransitionReason = if ($dvdPaths.Count -eq 0) { 'installation-media-already-ejected' } else { $null }
            BootTransitionAtUtc = if ($dvdPaths.Count -eq 0) { (Get-Date).ToUniversalTime().ToString('o') } else { $null }
        }
        Write-RunLog "Baseline $vmName state=$([string]$vm.State), uptime=$([int64]$vm.Uptime.TotalSeconds)s, osFile=$($osDisk.fileSizeGiB)GiB, dvdAttached=$($dvdPaths.Count -gt 0)."
    }

    while (((Get-Date) - $script:StartedAt).TotalMinutes -lt $maxWaitMinutes) {
        $now = Get-Date
        $elapsedSeconds = ($now - $script:StartedAt).TotalSeconds
        $nodes = @{}

        foreach ($vmName in $script:VmNames) {
            $rt = $runtime[$vmName]
            $vm = Get-VM -Name $vmName -ErrorAction Stop
            $osDrive = Get-DriveBySuffix -VmName $vmName -Kind 'os'
            $osDisk = Get-DiskMetrics -Drive $osDrive
            $dvdPaths = Get-DvdPaths -VmName $vmName
            $state = [string]$vm.State
            $uptimeSeconds = [int64]$vm.Uptime.TotalSeconds
            $fileSizeGiB = [double]$osDisk.fileSizeGiB
            $deltaGiB = [math]::Abs($fileSizeGiB - [double]$rt.LastFileSizeGiB)

            if ($deltaGiB -le 0.02) {
                $rt.StableDiskSeconds += $pollSeconds
            }
            else {
                $rt.StableDiskSeconds = 0
            }
            if ($state -ne 'Running') {
                $rt.SeenNotRunning = $true
            }

            if (-not $rt.BootTransitionCompleted -and $dvdPaths.Count -gt 0) {
                $reason = $null
                if (
                    $state -eq 'Off' -and
                    $fileSizeGiB -ge $minimumInstalledDiskFileGiB
                ) {
                    $reason = 'installer-powered-off-with-populated-os-disk'
                }
                elseif (
                    $rt.SeenNotRunning -and
                    $state -eq 'Running' -and
                    $fileSizeGiB -ge $minimumInstalledDiskFileGiB
                ) {
                    $reason = 'observed-reboot-state-transition'
                }
                elseif (
                    [int64]$rt.LastUptimeSeconds -gt 180 -and
                    $uptimeSeconds + 45 -lt [int64]$rt.LastUptimeSeconds -and
                    $fileSizeGiB -ge $minimumInstalledDiskFileGiB
                ) {
                    $reason = 'observed-uptime-reset'
                }
                else {
                    $address = [string]$nodeIpMap[$vmName]
                    $installedServiceCount = @(
                        (Test-TcpAddress -Address $address -Port 22),
                        (Test-TcpAddress -Address $address -Port 9345),
                        (Test-TcpAddress -Address $address -Port 10250) |
                            Where-Object { $_ }
                    ).Count
                    if (
                        $elapsedSeconds -ge 60 -and
                        $installedServiceCount -ge 2 -and
                        $fileSizeGiB -ge $minimumInstalledDiskFileGiB
                    ) {
                        $reason = 'installed-node-services-already-reachable'
                    }
                    elseif (
                        $elapsedSeconds -ge ($minimumObservationMinutes * 60) -and
                        [int]$rt.StableDiskSeconds -ge $diskStableSeconds -and
                        $fileSizeGiB -ge $minimumInstalledDiskFileGiB
                    ) {
                        $reason = 'populated-os-disk-stable-after-observation-window'
                    }
                }

                if ($null -ne $reason) {
                    Set-InstalledDiskBoot -VmName $vmName -Reason $reason
                    $rt.BootTransitionCompleted = $true
                    $rt.BootTransitionReason = $reason
                    $rt.BootTransitionAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    Start-Sleep -Seconds 5
                }
            }
            elseif (-not $rt.BootTransitionCompleted -and $dvdPaths.Count -eq 0) {
                $rt.BootTransitionCompleted = $true
                $rt.BootTransitionReason = 'installation-media-already-ejected'
                $rt.BootTransitionAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            }

            $nodes[$vmName] = Get-NodeProbe `
                -VmName $vmName `
                -Address ([string]$nodeIpMap[$vmName]) `
                -Runtime $rt

            $currentVm = Get-VM -Name $vmName -ErrorAction Stop
            $currentOsDisk = Get-DiskMetrics -Drive (Get-DriveBySuffix -VmName $vmName -Kind 'os')
            $rt.LastState = [string]$currentVm.State
            $rt.LastUptimeSeconds = [int64]$currentVm.Uptime.TotalSeconds
            $rt.LastFileSizeGiB = [double]$currentOsDisk.fileSizeGiB
        }

        $vipPing = Test-IcmpAddress -Address $vipAddress
        $vip443 = Test-TcpAddress -Address $vipAddress -Port 443 -TimeoutMilliseconds 1800
        $vip6443 = Test-TcpAddress -Address $vipAddress -Port 6443 -TimeoutMilliseconds 1800
        $httpsCode = if ($vip443) { Get-HttpsCode -Address $vipAddress } else { $null }
        $vipReady = $vip443 -and $vip6443
        $vip = [ordered]@{
            address = $vipAddress
            ping = $vipPing
            tcp443 = $vip443
            tcp6443 = $vip6443
            httpsStatusCode = $httpsCode
            ready = $vipReady
        }

        $allNodesOnline = $true
        foreach ($vmName in $script:VmNames) {
            if (-not [bool]$nodes[$vmName].online) {
                $allNodesOnline = $false
                break
            }
        }
        if ($allNodesOnline -and $vipReady) {
            $stableClusterPolls++
        }
        else {
            $stableClusterPolls = 0
        }

        $lastNodes = $nodes
        $lastVip = $vip
        $message = "Waiting for three installed nodes and VIP readiness; stable=$stableClusterPolls/$script:RequiredStablePolls."
        Write-RunLog $message

        if (($now - $lastPublishAt).TotalSeconds -ge $publishSeconds) {
            $capture = (($now - $lastConsoleCaptureAt).TotalSeconds -ge 300)
            Publish-Status `
                -Status 'waiting' `
                -Message $message `
                -Nodes $nodes `
                -Vip $vip `
                -StablePolls $stableClusterPolls `
                -CaptureConsoles:$capture
            $lastPublishAt = Get-Date
            if ($capture) {
                $lastConsoleCaptureAt = Get-Date
            }
        }

        if ($stableClusterPolls -ge $script:RequiredStablePolls) {
            $terminalStatus = 'success'
            $terminalMessage = 'All three VMs satisfy the hardware contract, boot from installed OS disks with no ISO attached, expose node services, and the LayerSentry VIP exposes HTTPS and Kubernetes API services.'
            break
        }

        Start-Sleep -Seconds $pollSeconds
    }

    if ($terminalStatus -ne 'success') {
        $terminalStatus = 'timeout'
        $terminalMessage = "Finalization reached its $maxWaitMinutes-minute timeout before every readiness gate passed."
    }
}
catch {
    $terminalStatus = 'failure'
    $terminalMessage = "Finalization failed: $($_.Exception.Message)"
    Write-RunLog $terminalMessage
}

Publish-Status `
    -Status $terminalStatus `
    -Message $terminalMessage `
    -Nodes $lastNodes `
    -Vip $lastVip `
    -StablePolls $stableClusterPolls `
    -CaptureConsoles

Write-RunLog $terminalMessage
if ($terminalStatus -ne 'success') {
    throw $terminalMessage
}
