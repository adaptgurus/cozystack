[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen1', 'sen2', 'sen3'),
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-console-capture')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

$vmms = Get-WmiObject `
    -Namespace 'root\virtualization\v2' `
    -Class 'Msvm_VirtualSystemManagementService' `
    -ErrorAction Stop

$results = foreach ($name in $VmNames) {
    $vm = Get-VM -Name $name -ErrorAction Stop
    $adapter = Get-VMNetworkAdapter -VMName $name -ErrorAction Stop | Select-Object -First 1
    $heartbeats = @(
        Get-VMIntegrationService -VMName $name -ErrorAction SilentlyContinue |
            Select-Object Name, Enabled, PrimaryStatusDescription, SecondaryStatusDescription
    )
    $pngPath = Join-Path $OutputDirectory "$name-console.png"
    $captureStatus = 'NotAttempted'
    $captureError = $null
    $width = $null
    $height = $null

    try {
        $escapedName = $name.Replace("'", "''")
        $vmcs = Get-WmiObject `
            -Namespace 'root\virtualization\v2' `
            -Class 'Msvm_ComputerSystem' `
            -Filter "ElementName='$escapedName'" `
            -ErrorAction Stop
        if ($null -eq $vmcs) {
            throw "Msvm_ComputerSystem was not found for $name"
        }

        $video = @($vmcs.GetRelated('Msvm_VideoHead')) | Select-Object -First 1
        if ($null -eq $video) {
            throw "Msvm_VideoHead was not found for $name"
        }
        $width = [int](@($video.CurrentHorizontalResolution)[0])
        $height = [int](@($video.CurrentVerticalResolution)[0])
        if ($width -le 0 -or $height -le 0) {
            throw "Invalid current console resolution ${width}x${height}"
        }

        $response = $vmms.GetVirtualSystemThumbnailImage($vmcs, $width, $height)
        if ([int]$response.ReturnValue -ne 0) {
            throw "GetVirtualSystemThumbnailImage returned $($response.ReturnValue)"
        }
        [byte[]]$imageBytes = $response.ImageData
        if ($null -eq $imageBytes -or $imageBytes.Length -eq 0) {
            throw 'Hyper-V returned empty console image data.'
        }

        $bitmap = New-Object System.Drawing.Bitmap(
            $width,
            $height,
            [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565
        )
        try {
            $rectangle = New-Object System.Drawing.Rectangle(0, 0, $width, $height)
            $bitmapData = $bitmap.LockBits(
                $rectangle,
                [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565
            )
            try {
                $targetBytes = [math]::Abs($bitmapData.Stride) * $bitmapData.Height
                $copyBytes = [math]::Min($targetBytes, $imageBytes.Length)
                [System.Runtime.InteropServices.Marshal]::Copy(
                    $imageBytes,
                    0,
                    $bitmapData.Scan0,
                    $copyBytes
                )
            }
            finally {
                $bitmap.UnlockBits($bitmapData)
            }
            $bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $bitmap.Dispose()
        }
        $captureStatus = 'Success'
    }
    catch {
        $captureStatus = 'Failed'
        $captureError = $_.Exception.Message
    }

    [pscustomobject]@{
        Name = $name
        State = [string]$vm.State
        Status = $vm.Status
        UptimeSeconds = [int64]$vm.Uptime.TotalSeconds
        CPUUsagePercent = $vm.CPUUsage
        AssignedMemoryGiB = [math]::Round(($vm.MemoryAssigned / 1GB), 2)
        SwitchName = $adapter.SwitchName
        NetworkStatus = [string]$adapter.Status
        ReportedIPAddresses = @($adapter.IPAddresses)
        IntegrationServices = $heartbeats
        ConsoleCaptureStatus = $captureStatus
        ConsoleCaptureError = $captureError
        ConsoleWidth = $width
        ConsoleHeight = $height
        ConsoleImage = if ($captureStatus -eq 'Success') { "$name-console.png" } else { $null }
    }
}

$report = [pscustomobject]@{
    SchemaVersion = '1.0'
    CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    CollectionMode = 'read-only-hyperv-console-thumbnail'
    Host = $env:COMPUTERNAME
    VirtualMachines = @($results)
}
$report | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'console-capture.json') -Encoding UTF8

@(
    'LayerSentry Hyper-V console capture'
    "Host: $env:COMPUTERNAME"
    "Collected UTC: $($report.CollectedAtUtc)"
    ''
    ($results | Select-Object Name, State, UptimeSeconds, CPUUsagePercent, AssignedMemoryGiB, NetworkStatus, ConsoleCaptureStatus, ConsoleWidth, ConsoleHeight, ConsoleCaptureError |
        Format-Table -AutoSize | Out-String -Width 300)
) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'console-capture.txt') -Encoding UTF8

$hashLines = foreach ($file in @(Get-ChildItem -LiteralPath $OutputDirectory -File)) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
}
$hashLines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ASCII
Get-Content -LiteralPath (Join-Path $OutputDirectory 'console-capture.txt')
