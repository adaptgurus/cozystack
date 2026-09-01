[CmdletBinding()]
param(
    [string]$VmRoot = 'C:\Hyper-V\LayerSentry',
    [UInt64]$RequiredOsDiskBytes = 250GB,
    [string]$EvidenceDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-resize-os-disks')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$vmNames = @('sen1', 'sen2', 'sen3')

if (Test-Path -LiteralPath $EvidenceDirectory) {
    Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force
}
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).ProviderPath

$before = @()
$after = @()
$stopped = @()
$started = @()
$fatalError = $null

try {
    foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction Stop
        if ([int]$vm.Generation -ne 2) {
            throw "VM $name is not Generation 2."
        }

        $expectedOsDisk = Join-Path (Join-Path (Join-Path $VmRoot $name) 'Virtual Hard Disks') "$name-os.vhdx"
        $drive = Get-VMHardDiskDrive -VMName $name -ErrorAction Stop |
            Where-Object { $_.Path -eq $expectedOsDisk } |
            Select-Object -First 1
        if ($null -eq $drive) {
            throw "Expected OS disk is not attached to $name: $expectedOsDisk"
        }
        $vhd = Get-VHD -Path $expectedOsDisk -ErrorAction Stop
        $before += [pscustomobject]@{
            VM = $name
            State = [string]$vm.State
            Path = $expectedOsDisk
            VhdType = [string]$vhd.VhdType
            VirtualSizeGiB = [math]::Round(($vhd.Size / 1GB), 2)
            FileSizeGiB = [math]::Round(($vhd.FileSize / 1GB), 4)
        }
    }

    foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction Stop
        if ($vm.State -ne 'Off') {
            Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop
            $deadline = (Get-Date).AddMinutes(2)
            do {
                Start-Sleep -Seconds 2
                $state = (Get-VM -Name $name -ErrorAction Stop).State
            } while ($state -ne 'Off' -and (Get-Date) -lt $deadline)
            if ($state -ne 'Off') {
                throw "VM $name did not stop. Current state: $state"
            }
        }
        $stopped += $name
    }

    foreach ($name in $vmNames) {
        $expectedOsDisk = Join-Path (Join-Path (Join-Path $VmRoot $name) 'Virtual Hard Disks') "$name-os.vhdx"
        $vhd = Get-VHD -Path $expectedOsDisk -ErrorAction Stop
        if ([UInt64]$vhd.Size -lt $RequiredOsDiskBytes) {
            Resize-VHD -Path $expectedOsDisk -SizeBytes $RequiredOsDiskBytes -ErrorAction Stop
        }
        $verified = Get-VHD -Path $expectedOsDisk -ErrorAction Stop
        if ([UInt64]$verified.Size -lt $RequiredOsDiskBytes) {
            throw "OS disk resize failed for $name. Size is $($verified.Size) bytes."
        }
        $after += [pscustomobject]@{
            VM = $name
            Path = $expectedOsDisk
            VhdType = [string]$verified.VhdType
            VirtualSizeGiB = [math]::Round(($verified.Size / 1GB), 2)
            FileSizeGiB = [math]::Round(($verified.FileSize / 1GB), 4)
        }
    }

    foreach ($name in $vmNames) {
        $dvd = Get-VMDvdDrive -VMName $name -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $dvd -or [string]::IsNullOrWhiteSpace([string]$dvd.Path)) {
            throw "VM $name has no installer ISO attached."
        }
        Set-VMFirmware -VMName $name -FirstBootDevice $dvd
        Start-VM -Name $name -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 3
            $state = (Get-VM -Name $name -ErrorAction Stop).State
        } while ($state -ne 'Running' -and (Get-Date) -lt $deadline)
        if ($state -ne 'Running') {
            throw "VM $name did not return to Running state. Current state: $state"
        }
        $started += $name
        Start-Sleep -Seconds 8
    }

    Start-Sleep -Seconds 45
}
catch {
    $fatalError = $_.Exception.Message
}
finally {
    $states = foreach ($name in $vmNames) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        [pscustomobject]@{
            VM = $name
            Exists = ($null -ne $vm)
            State = if ($null -ne $vm) { [string]$vm.State } else { 'Absent' }
            UptimeSeconds = if ($null -ne $vm) { [int64]$vm.Uptime.TotalSeconds } else { $null }
        }
    }

    $report = [pscustomobject]@{
        SchemaVersion = '1.0'
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Operation = 'increase-harvester-installation-disks-to-250-gib'
        Reason = 'Harvester installer rejected 100 GiB installation disks and requires at least 250 GiB.'
        RequiredOsDiskGiB = [math]::Round(($RequiredOsDiskBytes / 1GB), 2)
        Before = $before
        After = $after
        StoppedVMs = $stopped
        StartedVMs = $started
        States = $states
        FatalError = $fatalError
        InstallationCompleted = $false
        ProductionQualified = $false
    }
    $jsonPath = Join-Path $EvidenceDirectory 'resize-os-disks.json'
    $summaryPath = Join-Path $EvidenceDirectory 'resize-os-disks.txt'
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    @(
        'LayerSentry Harvester OS disk correction'
        "Reason: $($report.Reason)"
        "Required size: $($report.RequiredOsDiskGiB) GiB"
        "Stopped VMs: $($stopped -join ', ')"
        "Started VMs: $($started -join ', ')"
        "Fatal error: $fatalError"
        ''
        'Before:'
        ($before | Format-Table -AutoSize | Out-String -Width 300)
        'After:'
        ($after | Format-Table -AutoSize | Out-String -Width 300)
        'Current states:'
        ($states | Format-Table -AutoSize | Out-String -Width 300)
    ) | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Get-Content -LiteralPath $summaryPath
}

if ($null -ne $fatalError) {
    throw $fatalError
}
if (@($states | Where-Object { -not $_.Exists -or $_.State -ne 'Running' }).Count -ne 0) {
    throw 'Not all three VMs are running after the disk correction.'
}

Write-Host 'LAYERSENTRY OS DISK CORRECTION: PASS'
