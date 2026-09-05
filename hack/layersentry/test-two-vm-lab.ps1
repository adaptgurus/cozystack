$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TwoVmLab.psm1') -Force
$count = 0
function Expect-Rejection([scriptblock]$Action) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Expected guard rejection.' }
    $script:count++
}

foreach ($name in @('TwoVmLab.psm1', 'invoke-two-vm-lab.ps1', 'test-two-vm-lab.ps1')) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Parser rejected $name" }
    $count++
}
$request = [pscustomobject]@{
    requestId = 'lab-test-001'; mode = 'resize-only'; host = 'TESTSER'; existingVmId = '00000000-0000-0000-0000-000000000001'
    secondVmName = 'layersentry-dr-test'; switchId = '00000000-0000-0000-0000-000000000002'; isoPath = ''; isoSha256 = ''; vmRoot = ''
}
Assert-LabRequest $request; $count++
$request.mode = 'two-vm'
$request.isoPath = 'D:\ISO\Rocky-9.iso'; $request.isoSha256 = 'a' * 64; $request.vmRoot = 'D:\LayerSentry\dr-test'
Assert-LabRequest $request; $count++
$request.mode = 'create-only'
Assert-LabRequest $request; $count++
$request.isoPath = 'D:\ISO\active-cloudstack.vhdx'
Expect-Rejection { Assert-LabRequest $request }
$request.isoPath = 'D:\ISO\..\Rocky-9.iso'
Expect-Rejection { Assert-LabRequest $request }
$request.isoPath = '\\server\share\Rocky-9.iso'
Expect-Rejection { Assert-LabRequest $request }
$request.isoPath = 'D:\ISO\Rocky-9.iso'; $request.existingVmId = '*'
Expect-Rejection { Assert-LabRequest $request }
$capacity = @{ TotalGiB = 108; FreeGiB = 10; ExistingAssignedGiB = 94; OtherReservedGiB = 0; LogicalProcessors = 44; OtherCpu = 0; DiskFreeGiB = 820; DiskGrowthGiB = 200 }
Assert-LabCapacity @capacity; $count++
$capacity.TotalGiB = 95
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.TotalGiB = 108; $capacity.FreeGiB = 1
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.FreeGiB = 10; $capacity.OtherReservedGiB = 20
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.OtherReservedGiB = 0; $capacity.LogicalProcessors = 8
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.LogicalProcessors = 16; $capacity.OtherCpu = 5
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.LogicalProcessors = 44; $capacity.OtherCpu = 0; $capacity.DiskFreeGiB = 819
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.DiskFreeGiB = 600; $capacity.DiskGrowthGiB = 0
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.DiskFreeGiB = 620
Assert-LabCapacity @capacity; $count++

# Execute the actual shutdown/start functions with in-memory Hyper-V mocks.
# No Hyper-V module is imported by this test, even on the runner host.
& (Get-Module TwoVmLab) {
    $script:state = 'Running'; $script:stops = 0; $script:starts = 0
    function script:Get-VM { param($Id, $ErrorAction) [pscustomobject]@{ State = $script:state; Heartbeat = 'OkApplicationsUnknown' } }
    function script:Stop-VM { param($VM, $Confirm, $ErrorAction) $script:stops++; $script:state = 'Off' }
    function script:Start-VM { param($VM, $ErrorAction) $script:starts++; $script:state = 'Running' }
    function script:Get-CimInstance { param($ClassName) [pscustomobject]@{ FreePhysicalMemory = 60 * 1MB } }
    function script:Get-VMMemory { param($VM) [pscustomobject]@{ Startup = 40GB } }
    Stop-LabVmGracefully '00000000-0000-0000-0000-000000000001'
    Stop-LabVmGracefully '00000000-0000-0000-0000-000000000001'
    if ($script:stops -ne 1) { throw 'Already-off shutdown was not idempotent.' }
    Start-LabVm '00000000-0000-0000-0000-000000000001' -RequireHeartbeat
    if ($script:starts -ne 1) { throw 'Start was not called.' }
    $script:state = 'Off'
    function script:Get-CimInstance { param($ClassName) [pscustomobject]@{ FreePhysicalMemory = 45 * 1MB } }
    $blocked = $false
    try { Start-LabVm '00000000-0000-0000-0000-000000000001' } catch { $blocked = $true }
    if (-not $blocked -or $script:starts -ne 1) { throw 'Low-memory start guard failed.' }
    # Recovery may restore the measured old headroom; forward starts still require 16 GiB.
    Start-LabVm '00000000-0000-0000-0000-000000000001' -ReserveGiB 5
    if ($script:starts -ne 2) { throw 'Original-headroom recovery failed.' }
    $script:state = 'Saved'
    $blocked = $false
    try { Stop-LabVmGracefully '00000000-0000-0000-0000-000000000001' } catch { $blocked = $true }
    if (-not $blocked -or $script:stops -ne 1) { throw 'Unstable VM state guard failed.' }
}
$count += 5

# Exercise the creation helpers using in-memory disks, then reject drift before Start.
& (Get-Module TwoVmLab) {
    $script:created = @(); $script:attached = @(); $script:collision = $false
    function script:Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
    function script:Assert-PlainLocalPath { param($Path) }
    function script:Test-Path { param($LiteralPath) $script:collision -and $LiteralPath -like '*data.vhdx' }
    function script:New-VHD { param($Path, $SizeBytes, [switch]$Dynamic, $ErrorAction) $script:created += [pscustomobject]@{ Path = $Path; Size = $SizeBytes; Dynamic = [bool]$Dynamic } }
    function script:Add-VMHardDiskDrive { param($VM, $Path, $ControllerType, $ControllerNumber, $ControllerLocation, $ErrorAction) $script:attached += [pscustomobject]@{ Path = $Path; ControllerType = $ControllerType; ControllerNumber = $ControllerNumber; ControllerLocation = $ControllerLocation } }
    $vm = [pscustomobject]@{ Generation = 2 }
    $request = [pscustomobject]@{ vmRoot = 'C:\LayerSentry\dr-test'; isoPath = 'C:\Users\operator\Downloads\Rocky-9.8-x86_64-minimal.iso'; switchId = '00000000-0000-0000-0000-000000000002' }
    $script:collision = $true
    $blocked = $false
    try { Add-LabFreshDisks -VM $vm -VmRoot $request.vmRoot } catch { $blocked = $true }
    if (-not $blocked -or $script:created.Count) { throw 'Existing data disk did not prevent all writes.' }
    $script:collision = $false
    Add-LabFreshDisks -VM $vm -VmRoot $request.vmRoot
    if ($script:created.Count -ne 2 -or $script:attached.Count -ne 2 -or $script:created[0].Size -ne 100GB -or $script:created[1].Size -ne 500GB -or @($script:created | Where-Object { -not $_.Dynamic }).Count) { throw 'Fresh dynamic disk creation failed.' }
    $script:cpuCount = 16; $script:switchId = $request.switchId; $script:diskType = 'Dynamic'
    function script:Get-VMProcessor { param($VM) [pscustomobject]@{ Count = $script:cpuCount; ExposeVirtualizationExtensions = $true } }
    function script:Get-VMMemory { param($VM) [pscustomobject]@{ Startup = 40GB; DynamicMemoryEnabled = $false } }
    function script:Get-VMNetworkAdapter { param($VM) [pscustomobject]@{ SwitchId = $script:switchId; MacAddressSpoofing = 'On' } }
    function script:Get-VMHardDiskDrive { param($VM) $script:attached }
    function script:Get-VHD { param($Path) [pscustomobject]@{ Size = @($script:created | Where-Object Path -eq $Path)[0].Size; FileSize = 0; VhdType = $script:diskType; ParentPath = '' } }
    function script:Get-VMDvdDrive { param($VM) [pscustomobject]@{ Path = 'C:\Users\operator\Downloads\Rocky-9.8-x86_64-minimal.iso' } }
    Assert-LabSecondVm -VM $vm -Request $request
    foreach ($drift in @('cpu', 'switch', 'disk-type', 'disk-path')) {
        $script:cpuCount = 16; $script:switchId = $request.switchId; $script:diskType = 'Dynamic'; $script:attached[1].Path = 'C:\LayerSentry\dr-test\rocky9-data.vhdx'
        switch ($drift) {
            cpu { $script:cpuCount = 12 }
            switch { $script:switchId = '00000000-0000-0000-0000-000000000003' }
            disk-type { $script:diskType = 'Differencing' }
            disk-path { $script:attached[1].Path = 'C:\another-data.vhdx' }
        }
        $blocked = $false
        try { Assert-LabSecondVm -VM $vm -Request $request } catch { $blocked = $true }
        if (-not $blocked) { throw "Second VM $drift drift was accepted." }
    }
    $script:cpuCount = 16; $script:switchId = $request.switchId; $script:diskType = 'Dynamic'; $script:attached[1].Path = 'C:\LayerSentry\dr-test\rocky9-data.vhdx'
    $script:diskFree = 620; $script:total = 108; $script:logical = 44
    function script:Get-VM { @([pscustomobject]@{ Name = 'new' }) }
    function script:Get-CimInstance { param($ClassName) [pscustomobject]@{ TotalPhysicalMemory = $script:total * 1GB; NumberOfLogicalProcessors = $script:logical } }
    function script:Get-Volume { param($DriveLetter) [pscustomobject]@{ SizeRemaining = $script:diskFree * 1GB } }
    Assert-LabStartCapacity -VM $vm -Request $request
    $script:diskFree = 619
    $blocked = $false
    try { Assert-LabStartCapacity -VM $vm -Request $request } catch { $blocked = $true }
    if (-not $blocked) { throw 'Post-create disk exhaustion was accepted.' }
    $script:diskFree = 620; $script:total = 55
    $blocked = $false
    try { Assert-LabStartCapacity -VM $vm -Request $request } catch { $blocked = $true }
    if (-not $blocked) { throw 'Post-create host memory reservation drift was accepted.' }
}
$count += 10

# Filename discovery yields candidate request values only, never publisher trust.
& (Get-Module TwoVmLab) {
    $script:matchMode = 'one'; $script:reparse = $false
    function script:Assert-PlainLocalPath { param($Path) if ($script:reparse -and $Path -like '*Downloads*') { throw 'Reparse points are not accepted.' } }
    function script:Get-ChildItem { param($LiteralPath, [switch]$Directory, [switch]$Force) @([pscustomobject]@{ FullName = 'C:\Users\operator'; Attributes = [IO.FileAttributes]::Directory }, [pscustomobject]@{ FullName = 'C:\Users\other'; Attributes = [IO.FileAttributes]::Directory }) }
    function script:Test-Path { param($LiteralPath, $PathType) $script:matchMode -eq 'two' -or ($script:matchMode -eq 'one' -and $LiteralPath -like '*\operator\*') }
    function script:Get-Item { param($LiteralPath) [pscustomobject]@{ FullName = $LiteralPath; Length = 1234 } }
    function script:Get-FileHash { param($LiteralPath, $Algorithm) [pscustomobject]@{ Hash = 'A' * 64 } }
    $media = Get-LabRockyMedia -UsersRoot 'C:\Users'
    if ($media.isoPath -ne 'C:\Users\operator\Downloads\Rocky-9.8-x86_64-minimal.iso' -or $media.isoSha256 -cne ('a' * 64) -or $media.sizeBytes -ne 1234 -or $media.publisherVerification -ne 'PENDING') { throw 'Media discovery evidence mismatch.' }
    foreach ($mode in @('zero', 'two')) {
        $script:matchMode = $mode; $blocked = $false
        try { Get-LabRockyMedia -UsersRoot 'C:\Users' } catch { $blocked = $true }
        if (-not $blocked) { throw 'Ambiguous/missing ISO discovery was accepted.' }
    }
    $script:matchMode = 'one'; $script:reparse = $true; $blocked = $false
    try { Get-LabRockyMedia -UsersRoot 'C:\Users' } catch { $blocked = $true }
    if (-not $blocked) { throw 'Reparse media discovery was accepted.' }
    $blocked = $false
    try { Get-LabRockyMedia -UsersRoot '\\server\Users' } catch { $blocked = $true }
    if (-not $blocked) { throw 'Remote media discovery root was accepted.' }
}
$count += 5
Write-Output "Two-VM lab parser and behavior checks passed: $count"
