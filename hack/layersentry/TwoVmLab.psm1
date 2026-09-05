Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LabRequest {
    param([object]$Request)
    $fields = @('requestId', 'mode', 'host', 'existingVmId', 'secondVmName', 'switchId', 'isoPath', 'isoSha256', 'vmRoot')
    if (@($Request.PSObject.Properties.Name).Count -ne $fields.Count) { throw 'Invalid request fields.' }
    foreach ($field in $fields) {
        if ($Request.PSObject.Properties.Name -notcontains $field -or $Request.$field -isnot [string]) { throw 'Invalid request field type.' }
    }
    if ($Request.requestId -cnotmatch '^[a-z0-9][a-z0-9-]{5,63}$') { throw 'Invalid request ID.' }
    if ($Request.mode -cnotin @('resize-only', 'two-vm')) { throw 'Invalid request mode.' }
    if ($Request.host -notmatch '^[a-zA-Z0-9-]{1,63}$') { throw 'Invalid host name.' }
    if ($Request.secondVmName -notmatch '^layersentry-dr-[a-zA-Z0-9-]{1,40}$') { throw 'Invalid second VM name.' }
    foreach ($field in @('existingVmId', 'switchId')) {
        if ($Request.$field -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Invalid resource ID.' }
    }
    if ($Request.mode -eq 'resize-only') {
        if ($Request.isoPath -or $Request.isoSha256 -or $Request.vmRoot) { throw 'Resize-only requests must omit media and VM paths.' }
        return
    }
    if ($Request.isoSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid ISO SHA-256.' }
    foreach ($field in @('isoPath', 'vmRoot')) {
        if ($Request.$field -notmatch '^[a-zA-Z]:\\[^:*?"<>|]+$' -or $Request.$field -match '(^|\\)\.\.?($|\\)') { throw 'Use an absolute local path without traversal.' }
    }
    if ([IO.Path]::GetExtension($Request.isoPath) -ine '.iso') { throw 'Only fresh ISO installations are supported; cloned VHD identities are not accepted.' }
    if ($Request.vmRoot.TrimEnd('\') -notmatch '^[a-zA-Z]:\\.+\\.+') { throw 'VM root must be a dedicated directory below a parent folder.' }
}

function Assert-LabCapacity {
    param([double]$TotalGiB, [double]$FreeGiB, [double]$ExistingAssignedGiB,
        [double]$OtherReservedGiB, [int]$LogicalProcessors, [int]$OtherCpu,
        [double]$DiskFreeGiB, [double]$DiskGrowthGiB, [double]$NewDiskGiB = 80)
    # 40 GiB per node plus 16 GiB host reserve; respect other VMs' full reservations.
    if ($TotalGiB -lt (96 + $OtherReservedGiB) -or ($FreeGiB + $ExistingAssignedGiB) -lt 96) { throw 'Insufficient measured memory headroom for two 40 GiB nodes and 16 GiB reserve.' }
    if ($LogicalProcessors -lt 12 -or (24 + $OtherCpu) -gt (2 * $LogicalProcessors)) { throw 'CPU allocation exceeds the lab 2:1 ceiling.' }
    if (($DiskFreeGiB - $DiskGrowthGiB - $NewDiskGiB) -lt 20) { throw 'Insufficient storage at full VHD growth plus 20 GiB reserve.' }
}

function Assert-PlainLocalPath {
    param([string]$Path)
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are not accepted.' }
        }
        $cursor = Split-Path -Path $cursor -Parent
    }
}

function Get-LabVm {
    param([string]$Id)
    $vm = Get-VM -Id ([guid]$Id) -ErrorAction Stop
    if ([string]$vm.State -notin @('Off', 'Running')) { throw 'VM is not in a stable Off or Running state.' }
    return $vm
}

function Stop-LabVmGracefully {
    param([string]$Id)
    $vm = Get-LabVm $Id
    if ([string]$vm.State -eq 'Off') { return }
    # Default Stop-VM asks the guest OS to shut down. Never force or turn off.
    Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(4)
    while ([string](Get-VM -Id ([guid]$Id)).State -ne 'Off') {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Graceful shutdown timeout; use guest/console recovery.' }
        Start-Sleep -Seconds 3
    }
}

function Start-LabVm {
    param([string]$Id, [switch]$RequireHeartbeat)
    $vm = Get-LabVm $Id
    if ([string]$vm.State -eq 'Off') {
        $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
        $required = (Get-VMMemory -VM $vm).Startup / 1GB
        if ($free -lt ($required + 16)) { throw 'Insufficient current memory to start VM and retain host reserve.' }
        Start-VM -VM $vm -ErrorAction Stop | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(4)
    do {
        $vm = Get-VM -Id ([guid]$Id)
        if ([string]$vm.State -eq 'Running' -and (-not $RequireHeartbeat -or [string]$vm.Heartbeat -in @('OkApplicationsHealthy', 'OkApplicationsUnknown'))) { return }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'VM start/heartbeat verification timed out; Rocky service acceptance is separate.'
}

function Get-LabPreflight {
    param([object]$Request)
    Assert-LabRequest $Request
    if ($env:COMPUTERNAME -ine $Request.host) { throw 'Runner host does not match request.' }
    if ((Get-Service vmms).Status -ne 'Running') { throw 'VMMS is unavailable.' }
    $existing = Get-LabVm $Request.existingVmId
    if (@(Get-VM | Where-Object Name -eq $Request.secondVmName).Count) { throw 'Second VM name already exists; use journal recovery.' }
    if (@(Get-VMSnapshot -VM $existing).Count) { throw 'Resolve existing checkpoint chains before resizing.' }
    $switch = Get-VMSwitch -Id ([guid]$Request.switchId) -ErrorAction Stop
    $adapters = @(Get-VMNetworkAdapter -VM $existing)
    if ($adapters.Count -ne 1 -or [string]$adapters[0].SwitchId -ne $Request.switchId) { throw 'Existing VM must have exactly one NIC on the requested switch.' }
    if ([string]$switch.SwitchType -notin @('Internal', 'External')) { throw 'Unsupported switch type.' }
    $processor = Get-VMProcessor -VM $existing
    $memory = Get-VMMemory -VM $existing
    $diskIdentity = @(Get-VMHardDiskDrive -VM $existing | Sort-Object ControllerType, ControllerNumber, ControllerLocation | Select-Object Path, ControllerType, ControllerNumber, ControllerLocation)
    if ($processor.Count -lt 12 -or $memory.Startup -lt 40GB) { throw 'Request would increase current VM; this path only scales down.' }
    if ($Request.mode -eq 'two-vm') {
        Assert-PlainLocalPath $Request.isoPath
        Assert-PlainLocalPath $Request.vmRoot
        if (-not (Test-Path -LiteralPath $Request.isoPath -PathType Leaf)) { throw 'ISO is missing.' }
        if ((Get-FileHash -LiteralPath $Request.isoPath -Algorithm SHA256).Hash -ine $Request.isoSha256) { throw 'ISO digest mismatch.' }
        if (Test-Path -LiteralPath $Request.vmRoot) { throw 'Dedicated second VM directory must not already exist.' }
    }
    $otherMemory = 0.0; $otherCpu = 0; $growth = 0.0
    $drive = if ($Request.mode -eq 'two-vm') { $Request.vmRoot.Substring(0, 1) } else { '' }
    $paths = @{}
    foreach ($vm in @(Get-VM)) {
        if ([string]$vm.Id -ne $Request.existingVmId) {
            $mem = Get-VMMemory -VM $vm
            $otherMemory += $(if ($mem.DynamicMemoryEnabled) { $mem.Maximum / 1GB } else { $mem.Startup / 1GB })
            $otherCpu += (Get-VMProcessor -VM $vm).Count
        }
        foreach ($disk in @(Get-VMHardDiskDrive -VM $vm)) {
            if (-not $disk.Path) { throw 'Pass-through disks require manual capacity review.' }
            if ($disk.Path.Substring(0, 1) -ine $drive -or $paths.ContainsKey($disk.Path)) { continue }
            $paths[$disk.Path] = $true
            $vhd = Get-VHD -Path $disk.Path
            if ($vhd.ParentPath) { throw 'Differencing VHD requires manual storage review.' }
            $growth += [math]::Max(0, ($vhd.Size - $vhd.FileSize) / 1GB)
        }
    }
    $computer = Get-CimInstance Win32_ComputerSystem
    $total = $computer.TotalPhysicalMemory / 1GB
    $free = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
    $diskFree = if ($drive) { (Get-Volume -DriveLetter $drive).SizeRemaining / 1GB } else { 100 }
    Assert-LabCapacity -TotalGiB $total -FreeGiB $free -ExistingAssignedGiB ($existing.MemoryAssigned / 1GB) -OtherReservedGiB $otherMemory -LogicalProcessors $computer.NumberOfLogicalProcessors -OtherCpu $otherCpu -DiskFreeGiB $diskFree -DiskGrowthGiB $growth
    return [ordered]@{
        status = 'DESIGN_DEFINED'; totalGiB = $total; freeGiB = $free; otherReservedGiB = $otherMemory
        diskFreeGiB = $diskFree; diskGrowthGiB = $growth; targetCpu = 12; targetMemoryGiB = 40
        existing = [ordered]@{ id = [string]$existing.Id; state = [string]$existing.State; cpu = $processor.Count
            nested = [bool]$processor.ExposeVirtualizationExtensions; startup = $memory.Startup
            minimum = $memory.Minimum; maximum = $memory.Maximum; dynamic = [bool]$memory.DynamicMemoryEnabled
            nicId = [string]$adapters[0].Id; spoofing = [string]$adapters[0].MacAddressSpoofing; disks = $diskIdentity }
    }
}

Export-ModuleMember -Function *-Lab*, Assert-PlainLocalPath
