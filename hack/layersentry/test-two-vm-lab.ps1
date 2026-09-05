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
$request.isoPath = 'D:\ISO\active-cloudstack.vhdx'
Expect-Rejection { Assert-LabRequest $request }
$request.isoPath = 'D:\ISO\..\Rocky-9.iso'
Expect-Rejection { Assert-LabRequest $request }
$request.isoPath = '\\server\share\Rocky-9.iso'
Expect-Rejection { Assert-LabRequest $request }
$request.isoPath = 'D:\ISO\Rocky-9.iso'; $request.existingVmId = '*'
Expect-Rejection { Assert-LabRequest $request }
$capacity = @{ TotalGiB = 108; FreeGiB = 10; ExistingAssignedGiB = 94; OtherReservedGiB = 0; LogicalProcessors = 24; OtherCpu = 0; DiskFreeGiB = 400; DiskGrowthGiB = 200 }
Assert-LabCapacity @capacity; $count++
$capacity.TotalGiB = 95
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.TotalGiB = 108; $capacity.FreeGiB = 1
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.FreeGiB = 10; $capacity.OtherReservedGiB = 20
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.OtherReservedGiB = 0; $capacity.LogicalProcessors = 8
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.LogicalProcessors = 12; $capacity.OtherCpu = 1
Expect-Rejection { Assert-LabCapacity @capacity }
$capacity.LogicalProcessors = 24; $capacity.OtherCpu = 0; $capacity.DiskFreeGiB = 290
Expect-Rejection { Assert-LabCapacity @capacity }

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
    $script:state = 'Saved'
    $blocked = $false
    try { Stop-LabVmGracefully '00000000-0000-0000-0000-000000000001' } catch { $blocked = $true }
    if (-not $blocked -or $script:stops -ne 1) { throw 'Unstable VM state guard failed.' }
}
$count += 4
Write-Output "Two-VM lab parser and behavior checks passed: $count"
