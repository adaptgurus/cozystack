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

function Write-MonitorLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Test-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Object.PSObject.Properties[$Name]) {
        throw "Required request property is missing: $Name"
    }
}

function Test-IpAddress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    $parsed = $null
    return [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)
}

function Test-Icmp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

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

function Test-TcpPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 1000
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

function Get-HttpsStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address
    )

    $curl = Get-Command -Name 'curl.exe' -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        return $null
    }

    try {
        $code = & $curl.Source `
            '--insecure' `
            '--silent' `
            '--show-error' `
            '--output' 'NUL' `
            '--write-out' '%{http_code}' `
            '--connect-timeout' '2' `
            '--max-time' '6' `
            "https://$Address/" 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        $text = ([string]$code).Trim()
        if ($text -match '^\d{3}$') {
            return [int]$text
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-OsDiskDrive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $drives = @(
        Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
                ([string]$_.Path -match '(?i)-os\.vhdx$')
            }
    )

    if ($drives.Count -ne 1) {
        throw "Expected exactly one OS disk ending in -os.vhdx for $VmName; found $($drives.Count)."
    }
    return $drives[0]
}

function Get-OsDiskMetrics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $drive = Get-OsDiskDrive -VmName $VmName
    $vhd = Get-VHD -Path $drive.Path -ErrorAction Stop
    return [ordered]@{
        path = [string]$drive.Path
        virtualSizeGiB = [math]::Round(([double]$vhd.Size / 1GB), 2)
        fileSizeGiB = [math]::Round(([double]$vhd.FileSize / 1GB), 2)
        vhdType = [string]$vhd.VhdType
    }
}

function Prepare-InstalledDiskBoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    Write-MonitorLog "Preparing installed-disk-first boot for $VmName."
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ([string]$vm.State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            Start-Sleep -Seconds 1
            $vm = Get-VM -Name $VmName -ErrorAction Stop
            if ([string]$vm.State -eq 'Off') {
                break
            }
        }
        if ([string]$vm.State -ne 'Off') {
            throw "VM $VmName did not reach Off state while changing boot media."
        }
    }

    $dvdDrives = @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)
    foreach ($dvd in $dvdDrives) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dvd.Path)) {
            Set-VMDvdDrive -VMName $VmName `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $null `
                -ErrorAction Stop
        }
    }

    $osDrive = Get-OsDiskDrive -VmName $VmName
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDrive -ErrorAction Stop
    Start-VM -Name $VmName -ErrorAction Stop | Out-Null
    Write-MonitorLog "ISO ejected, OS disk selected first, and $VmName restarted."
}

function Save-ConsoleScreens {
    $captureScript = Join-Path $RepositoryRoot 'hack/layersentry/capture-hyperv-console.ps1'
    if (-not (Test-Path -LiteralPath $captureScript -PathType Leaf)) {
        Write-MonitorLog "Console capture script is missing; skipping screenshots."
        return
    }

    $captureDirectory = Join-Path $OutputDirectory '_capture'
    if (Test-Path -LiteralPath $captureDirectory) {
        Remove-Item -LiteralPath $captureDirectory -Recurse -Force
    }

    try {
        & $captureScript `
            -VmNames $script:VmNames `
            -OutputDirectory $captureDirectory
        foreach ($vmName in $script:VmNames) {
            $source = Join-Path $captureDirectory "$vmName-console.png"
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                Copy-Item -LiteralPath $source `
                    -Destination (Join-Path $OutputDirectory "$vmName-console.png") `
                    -Force
            }
        }
    }
    catch {
        Write-MonitorLog "Console capture warning: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $captureDirectory) {
            Remove-Item -LiteralPath $captureDirectory -Recurse -Force
        }
    }
}

function Publish-Checkpoint {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('waiting', 'success', 'timeout', 'failure')]
        [string]$OverallStatus,

        [Parameter(Mandatory = $true)]
        [hashtable]$StatusDocument
    )

    foreach ($marker in @('WAITING', 'SUCCESS', 'TIMEOUT', 'FAILURE')) {
        $markerPath = Join-Path $OutputDirectory $marker
        if (Test-Path -LiteralPath $markerPath) {
            Remove-Item -LiteralPath $markerPath -Force
        }
    }
    New-Item -Path (Join-Path $OutputDirectory $OverallStatus.ToUpperInvariant()) `
        -ItemType File -Force | Out-Null

    $StatusDocument.overallStatus = $OverallStatus
    $StatusDocument.publishedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $StatusDocument | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'status.json') -Encoding UTF8

    Save-ConsoleScreens

    $relativeOutput = $OutputDirectory.Substring($RepositoryRoot.Length).TrimStart('\', '/')
    & git -C $RepositoryRoot add -- $relativeOutput
    if ($LASTEXITCODE -ne 0) {
        throw "git add failed with exit code $LASTEXITCODE"
    }

    if (-not $script:StatusCommitCreated) {
        & git -C $RepositoryRoot commit -m "ops(status): monitor LayerSentry installation [$OverallStatus] [skip ci]"
        if ($LASTEXITCODE -ne 0) {
            throw "initial status commit failed with exit code $LASTEXITCODE"
        }
        $script:StatusCommitCreated = $true
    }
    else {
        & git -C $RepositoryRoot diff --cached --quiet -- $relativeOutput
        $diffExitCode = $LASTEXITCODE
        if ($diffExitCode -eq 1) {
            & git -C $RepositoryRoot commit --amend --no-edit
            if ($LASTEXITCODE -ne 0) {
                throw "status commit amend failed with exit code $LASTEXITCODE"
            }
        }
        elseif ($diffExitCode -ne 0) {
            throw "git diff failed with exit code $diffExitCode"
        }
    }

    & git -C $RepositoryRoot push --force origin "HEAD:$PublishBranch"
    if ($LASTEXITCODE -ne 0) {
        throw "status branch push failed with exit code $LASTEXITCODE"
    }
}

function New-StatusDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverallStatus,

        [Parameter(Mandatory = $true)]
        [hashtable]$NodeResults,

        [Parameter(Mandatory = $true)]
        [hashtable]$VipResult,

        [int]$StablePollCount,

        [string]$Message
    )

    return [ordered]@{
        schemaVersion = '1.0'
        requestId = [string]$script:Request.requestId
        requestPath = [string]$RequestPath
        sourceCommit = [string]$env:GITHUB_SHA
        monitorStartedAtUtc = $script:MonitorStartedAt.ToUniversalTime().ToString('o')
        elapsedMinutes = [math]::Round(((Get-Date) - $script:MonitorStartedAt).TotalMinutes, 2)
        maxWaitMinutes = $script:MaxWaitMinutes
        overallStatus = $OverallStatus
        message = $Message
        stablePollCount = $StablePollCount
        requiredStablePolls = $script:RequiredStablePolls
        vip = $VipResult
        nodes = $NodeResults
        credentialsRead = $false
        containsCredentialValues = $false
    }
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Monitor request file does not exist: $RequestPath"
}
if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root does not exist: $RepositoryRoot"
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not $OutputDirectory.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be inside RepositoryRoot.'
}

$script:Request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($propertyName in @(
    'requestId',
    'vmNames',
    'expectedNodeIPs',
    'vip',
    'maxWaitMinutes',
    'pollSeconds',
    'publishSeconds',
    'requiredStablePolls',
    'detachIsoAfterInstallerReboot'
)) {
    Test-RequiredProperty -Object $script:Request -Name $propertyName
}

if ([string]::IsNullOrWhiteSpace([string]$script:Request.requestId)) {
    throw 'requestId must not be empty.'
}

$script:VmNames = @($script:Request.vmNames | ForEach-Object { [string]$_ })
if ($script:VmNames.Count -ne 3 -or @($script:VmNames | Select-Object -Unique).Count -ne 3) {
    throw 'vmNames must contain exactly three unique VM names.'
}
foreach ($expectedName in @('sen1', 'sen2', 'sen3')) {
    if ($script:VmNames -notcontains $expectedName) {
        throw "vmNames must include $expectedName."
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
        throw "Invalid expected IP address for ${vmName}: $address"
    }
    $nodeIpMap[$vmName] = $address
}

$vipAddress = [string]$script:Request.vip
if (-not (Test-IpAddress -Address $vipAddress)) {
    throw "Invalid VIP address: $vipAddress"
}

$script:MaxWaitMinutes = [int]$script:Request.maxWaitMinutes
$pollSeconds = [int]$script:Request.pollSeconds
$publishSeconds = [int]$script:Request.publishSeconds
$script:RequiredStablePolls = [int]$script:Request.requiredStablePolls
$detachIso = [bool]$script:Request.detachIsoAfterInstallerReboot

if ($script:MaxWaitMinutes -lt 10 -or $script:MaxWaitMinutes -gt 120) {
    throw 'maxWaitMinutes must be between 10 and 120.'
}
if ($pollSeconds -lt 5 -or $pollSeconds -gt 60) {
    throw 'pollSeconds must be between 5 and 60.'
}
if ($publishSeconds -lt 30 -or $publishSeconds -gt 600) {
    throw 'publishSeconds must be between 30 and 600.'
}
if ($script:RequiredStablePolls -lt 1 -or $script:RequiredStablePolls -gt 10) {
    throw 'requiredStablePolls must be between 1 and 10.'
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$script:LogPath = Join-Path $OutputDirectory 'monitor.log'
New-Item -Path $script:LogPath -ItemType File -Force | Out-Null

& git -C $RepositoryRoot config user.name 'github-actions[bot]'
& git -C $RepositoryRoot config user.email '41898282+github-actions[bot]@users.noreply.github.com'
& git -C $RepositoryRoot switch -C 'layersentry-install-status-work' $env:GITHUB_SHA
if ($LASTEXITCODE -ne 0) {
    throw "Unable to create local status branch from $env:GITHUB_SHA."
}

$script:StatusCommitCreated = $false
$script:MonitorStartedAt = Get-Date
$lastPublishAt = [datetime]::MinValue
$stablePollCount = 0
$runtime = @{}

foreach ($vmName in $script:VmNames) {
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    $runtime[$vmName] = [pscustomobject]@{
        LastState = [string]$vm.State
        LastUptimeSeconds = [int64]$vm.Uptime.TotalSeconds
        SeenNotRunning = ([string]$vm.State -ne 'Running')
        InstallerRebootDetected = $false
        BootPrepared = $false
        BootPreparedAtUtc = $null
        DetectionReason = $null
    }
    Write-MonitorLog "Baseline $vmName state=$([string]$vm.State) uptimeSeconds=$([int64]$vm.Uptime.TotalSeconds)."
}

$finalStatus = 'failure'
$finalMessage = 'Monitor ended unexpectedly.'
$lastNodeResults = @{}
$lastVipResult = @{}

try {
    while (((Get-Date) - $script:MonitorStartedAt).TotalMinutes -lt $script:MaxWaitMinutes) {
        $now = Get-Date
        $elapsedSeconds = ($now - $script:MonitorStartedAt).TotalSeconds
        $nodeResults = @{}

        foreach ($vmName in $script:VmNames) {
            $rt = $runtime[$vmName]
            $vm = Get-VM -Name $vmName -ErrorAction Stop
            $state = [string]$vm.State
            $uptimeSeconds = [int64]$vm.Uptime.TotalSeconds
            $osDisk = Get-OsDiskMetrics -VmName $vmName
            $dvdPaths = @(
                Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue |
                    ForEach-Object { [string]$_.Path } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            if ($state -ne 'Running') {
                $rt.SeenNotRunning = $true
            }

            if (-not $rt.InstallerRebootDetected) {
                if ($rt.SeenNotRunning -and $state -eq 'Running') {
                    $rt.InstallerRebootDetected = $true
                    $rt.DetectionReason = 'observed-not-running-then-running'
                }
                elseif (
                    $rt.LastUptimeSeconds -gt 180 -and
                    $uptimeSeconds + 45 -lt $rt.LastUptimeSeconds
                ) {
                    $rt.InstallerRebootDetected = $true
                    $rt.DetectionReason = 'uptime-reset'
                }
                elseif (
                    $state -eq 'Off' -and
                    $elapsedSeconds -gt 180 -and
                    [double]$osDisk.fileSizeGiB -gt 2.0
                ) {
                    $rt.InstallerRebootDetected = $true
                    $rt.DetectionReason = 'installer-powered-off-with-populated-os-disk'
                }
            }

            if (
                $detachIso -and
                $rt.InstallerRebootDetected -and
                -not $rt.BootPrepared
            ) {
                $rt.BootPrepared = $true
                Prepare-InstalledDiskBoot -VmName $vmName
                $rt.BootPreparedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                $vm = Get-VM -Name $vmName -ErrorAction Stop
                $state = [string]$vm.State
                $uptimeSeconds = [int64]$vm.Uptime.TotalSeconds
                $dvdPaths = @(
                    Get-VMDvdDrive -VMName $vmName -ErrorAction SilentlyContinue |
                        ForEach-Object { [string]$_.Path } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }

            $address = [string]$nodeIpMap[$vmName]
            $pingOk = Test-Icmp -Address $address -TimeoutMilliseconds 1000
            $sshOk = Test-TcpPort -Address $address -Port 22 -TimeoutMilliseconds 1000
            $supervisorOk = Test-TcpPort -Address $address -Port 9345 -TimeoutMilliseconds 1000
            $kubeletOk = Test-TcpPort -Address $address -Port 10250 -TimeoutMilliseconds 1000
            $nodeOnline = (
                $state -eq 'Running' -and
                $rt.BootPrepared -and
                ($pingOk -or $sshOk) -and
                $supervisorOk -and
                $kubeletOk
            )

            $nodeResults[$vmName] = [ordered]@{
                expectedIPAddress = $address
                vmState = $state
                uptimeSeconds = $uptimeSeconds
                cpuUsagePercent = [int]$vm.CPUUsage
                assignedMemoryGiB = [math]::Round(([double]$vm.MemoryAssigned / 1GB), 2)
                installerRebootDetected = [bool]$rt.InstallerRebootDetected
                rebootDetectionReason = $rt.DetectionReason
                bootPrepared = [bool]$rt.BootPrepared
                bootPreparedAtUtc = $rt.BootPreparedAtUtc
                dvdAttached = ($dvdPaths.Count -gt 0)
                dvdPaths = $dvdPaths
                osDisk = $osDisk
                network = [ordered]@{
                    ping = $pingOk
                    tcp22 = $sshOk
                    tcp9345 = $supervisorOk
                    tcp10250 = $kubeletOk
                }
                online = $nodeOnline
            }

            $rt.LastState = $state
            $rt.LastUptimeSeconds = $uptimeSeconds
        }

        $vipPing = Test-Icmp -Address $vipAddress -TimeoutMilliseconds 1000
        $vip443 = Test-TcpPort -Address $vipAddress -Port 443 -TimeoutMilliseconds 1500
        $vip6443 = Test-TcpPort -Address $vipAddress -Port 6443 -TimeoutMilliseconds 1500
        $httpsStatus = if ($vip443) { Get-HttpsStatusCode -Address $vipAddress } else { $null }
        $vipReady = $vip443 -and $vip6443 -and $null -ne $httpsStatus -and $httpsStatus -ne 0
        $vipResult = [ordered]@{
            address = $vipAddress
            ping = $vipPing
            tcp443 = $vip443
            tcp6443 = $vip6443
            httpsStatusCode = $httpsStatus
            ready = $vipReady
        }

        $allNodesOnline = $true
        foreach ($vmName in $script:VmNames) {
            if (-not [bool]$nodeResults[$vmName].online) {
                $allNodesOnline = $false
                break
            }
        }

        if ($allNodesOnline -and $vipReady) {
            $stablePollCount++
        }
        else {
            $stablePollCount = 0
        }

        $lastNodeResults = $nodeResults
        $lastVipResult = $vipResult
        $waitingMessage = "Waiting for installed nodes and cluster services; stablePollCount=$stablePollCount/$script:RequiredStablePolls."
        Write-MonitorLog $waitingMessage

        if (($now - $lastPublishAt).TotalSeconds -ge $publishSeconds) {
            $document = New-StatusDocument `
                -OverallStatus 'waiting' `
                -NodeResults $nodeResults `
                -VipResult $vipResult `
                -StablePollCount $stablePollCount `
                -Message $waitingMessage
            Publish-Checkpoint -OverallStatus 'waiting' -StatusDocument $document
            $lastPublishAt = Get-Date
        }

        if ($stablePollCount -ge $script:RequiredStablePolls) {
            $finalStatus = 'success'
            $finalMessage = 'All three nodes are running from their OS disks and the LayerSentry VIP is serving HTTPS and Kubernetes API traffic.'
            break
        }

        Start-Sleep -Seconds $pollSeconds
    }

    if ($finalStatus -ne 'success') {
        $finalStatus = 'timeout'
        $finalMessage = "Installation monitor reached its $script:MaxWaitMinutes-minute timeout before all readiness gates passed."
    }
}
catch {
    $finalStatus = 'failure'
    $finalMessage = "Installation monitor failed: $($_.Exception.Message)"
    Write-MonitorLog $finalMessage
}
finally {
    $finalDocument = New-StatusDocument `
        -OverallStatus $finalStatus `
        -NodeResults $lastNodeResults `
        -VipResult $lastVipResult `
        -StablePollCount $stablePollCount `
        -Message $finalMessage
    Publish-Checkpoint -OverallStatus $finalStatus -StatusDocument $finalDocument
}

Write-MonitorLog $finalMessage
if ($finalStatus -ne 'success') {
    throw $finalMessage
}
