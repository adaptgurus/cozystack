[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [ValidateSet('Preflight', 'Resize', 'Create', 'Start', 'Rollback')][string]$Phase = 'Preflight',
    [string]$Authorization = '',
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TwoVmLab.psm1') -Force
Import-Module Hyper-V -ErrorAction Stop

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
Assert-LabRequest $request
if ($env:COMPUTERNAME -ine $request.host) { throw 'Wrong runner host.' }
if ($request.mode -eq 'resize-only' -and $Phase -in @('Create', 'Start')) { throw 'Resize-only request cannot create or start a second VM.' }
if ($Phase -ne 'Preflight' -and $Authorization -cne "$($request.requestId):$Phase") { throw 'Explicit request/phase authorization is required.' }
$hash = (Get-FileHash -LiteralPath $RequestPath -Algorithm SHA256).Hash
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'An administrator runner is required.' }

# Persistent host journal survives Actions checkout/runner-temp cleanup. No secrets are stored.
$stateRoot = Join-Path $env:ProgramData 'LayerSentry\two-vm-lab'
Assert-PlainLocalPath $stateRoot
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
# Local administrators own the host and are the trust boundary for requests and journals.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
    $identity = New-Object Security.Principal.SecurityIdentifier($sid)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $stateRoot -AclObject $acl
$lockPath = Join-Path $stateRoot 'host.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$journalPath = Join-Path $stateRoot "$($request.requestId).json"
$report = [ordered]@{ status = 'PENDING'; phase = $Phase; requestId = $request.requestId; requestSha256 = $hash; sourceCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; mutationAttempted = $false; guestAcceptance = 'NOT_TESTED'; errorType = $null }
$journal = $null

function Save-Journal {
    # Write/flush a new temporary file, then atomic replace. Never silently replace a request baseline.
    $temporary = "$journalPath.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($script:journal | ConvertTo-Json -Depth 12))
    if ([IO.File]::Exists($journalPath)) {
        $backup = "$journalPath.replace-backup"
        [IO.File]::Replace($temporary, $journalPath, $backup, $true)
        [IO.File]::Delete($backup)
    }
    else { [IO.File]::Move($temporary, $journalPath) }
}
function Get-OwnedSecondVm {
    if (-not $script:journal.secondVmId) { throw 'No recorded second VM ID; inspect retained files and orphaned VM manually.' }
    $vm = Get-LabVm $script:journal.secondVmId
    if ($vm.Name -cne $request.secondVmName -or $vm.Notes -cne "LayerSentry two-vm-lab $hash") { throw 'Second VM ownership mismatch.' }
    return $vm
}
function Assert-ResizedExisting {
    $vm = Get-LabVm $request.existingVmId
    $cpu = Get-VMProcessor -VM $vm
    $mem = Get-VMMemory -VM $vm
    if ($cpu.Count -ne 12 -or -not $cpu.ExposeVirtualizationExtensions -or $mem.Startup -ne 40GB -or $mem.DynamicMemoryEnabled) { throw 'Existing VM is not in the expected resized configuration.' }
    $nic = @(Get-VMNetworkAdapter -VM $vm)
    if ($nic.Count -ne 1 -or [string]$nic[0].Id -ne $script:journal.original.nicId -or [string]$nic[0].SwitchId -ne $request.switchId -or [string]$nic[0].MacAddressSpoofing -ne 'On') { throw 'Existing NIC verification failed.' }
    $disks = @(Get-VMHardDiskDrive -VM $vm | Sort-Object ControllerType, ControllerNumber, ControllerLocation | Select-Object Path, ControllerType, ControllerNumber, ControllerLocation)
    if ((ConvertTo-Json -InputObject $disks -Compress) -cne (ConvertTo-Json -InputObject @($script:journal.original.disks) -Compress)) { throw 'Existing disk attachments changed.' }
}
try {
    if (Test-Path -LiteralPath $journalPath) {
        Assert-PlainLocalPath $journalPath
        $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        if ($journal.requestSha256 -cne $hash -or $journal.host -ine $env:COMPUTERNAME) { throw 'Journal/request mismatch; preserve the original request.' }
    }
    if ($Phase -eq 'Preflight') {
        if ($journal) { throw 'Request already journaled; use a new request ID for a fresh plan.' }
        $preflight = Get-LabPreflight $request
        $journal = [pscustomobject]@{ requestSha256 = $hash; host = $env:COMPUTERNAME; phase = 'Preflight'; original = $preflight.existing; originalReserveGiB = [math]::Min(16, $preflight.freeGiB); secondVmId = ''; createdUtc = [DateTime]::UtcNow.ToString('o') }
        Save-Journal
        $report.preflight = $preflight
        $report.status = 'DESIGN_DEFINED'
    }
    else {
        if (-not $journal) { throw 'Successful preflight journal is required.' }
        if ($Phase -eq 'Resize') {
            if ($journal.phase -cne 'Preflight') { throw 'Resize requires an untouched Preflight journal; recover interrupted runs first.' }
            $preflight = Get-LabPreflight $request
            if (($preflight.existing | ConvertTo-Json -Depth 10 -Compress) -cne ($journal.original | ConvertTo-Json -Depth 10 -Compress)) { throw 'Existing VM configuration drifted since preflight.' }
            $journal.phase = 'ResizeStarted'; Save-Journal
            $report.mutationAttempted = $true
            Stop-LabVmGracefully $request.existingVmId
            $vm = Get-LabVm $request.existingVmId
            Set-VMProcessor -VM $vm -Count 12 -ExposeVirtualizationExtensions $true
            Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes 40GB
            Get-VMNetworkAdapter -VM $vm | Set-VMNetworkAdapter -MacAddressSpoofing On
            Assert-ResizedExisting
            if ($journal.original.state -eq 'Running') { Start-LabVm $request.existingVmId -RequireHeartbeat }
            Assert-ResizedExisting
            $journal.phase = 'Resized'; Save-Journal
        }
        elseif ($Phase -eq 'Create') {
            if ($journal.phase -cne 'Resized') { throw 'Create requires a verified resize.' }
            Assert-ResizedExisting
            $null = Get-LabPreflight $request
            $journal.phase = 'CreateStarted'; Save-Journal
            $report.mutationAttempted = $true
            New-Item -ItemType Directory -Path $request.vmRoot -ErrorAction Stop | Out-Null
            $disk = Join-Path $request.vmRoot 'rocky9-os.vhdx'
            # New-VM creates a fresh generation-2 identity and an empty disk. No existing VHD is copied.
            $vm = New-VM -Name $request.secondVmName -Generation 2 -Path $request.vmRoot -MemoryStartupBytes 40GB -NewVHDPath $disk -NewVHDSizeBytes 80GB
            $journal.secondVmId = [string]$vm.Id; Save-Journal
            Set-VM -VM $vm -Notes "LayerSentry two-vm-lab $hash" -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -AutomaticCheckpointsEnabled $false
            Set-VMProcessor -VM $vm -Count 12 -ExposeVirtualizationExtensions $true
            Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes 40GB
            $switch = Get-VMSwitch -Id ([guid]$request.switchId)
            Get-VMNetworkAdapter -VM $vm | Connect-VMNetworkAdapter -VMSwitch $switch
            Get-VMNetworkAdapter -VM $vm | Set-VMNetworkAdapter -MacAddressSpoofing On
            Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
            $dvd = Add-VMDvdDrive -VM $vm -Path $request.isoPath -Passthru
            Set-VMFirmware -VM $vm -FirstBootDevice $dvd
            $journal.phase = 'Created'; Save-Journal
        }
        elseif ($Phase -eq 'Start') {
            if ($journal.phase -notin @('Created', 'StartStarted', 'Started')) { throw 'Start requires fully configured second VM.' }
            Assert-ResizedExisting
            $vm = Get-OwnedSecondVm
            if ((Get-FileHash -LiteralPath $request.isoPath -Algorithm SHA256).Hash -ine $request.isoSha256) { throw 'ISO digest changed.' }
            $journal.phase = 'StartStarted'; Save-Journal
            $report.mutationAttempted = $true
            Start-LabVm ([string]$vm.Id)
            $journal.phase = 'Started'; Save-Journal
            $report.installation = 'PENDING'
        }
        elseif ($Phase -eq 'Rollback') {
            if ($journal.phase -eq 'Preflight') { throw 'There is no mutation to roll back.' }
            # Retain second VM and disk for inspection; never remove or overwrite a disk.
            $report.mutationAttempted = $true
            if ($journal.secondVmId) {
                $vm = Get-OwnedSecondVm
                Stop-LabVmGracefully ([string]$vm.Id)
                Set-VM -VM $vm -AutomaticStartAction Nothing
            }
            elseif ($journal.phase -eq 'CreateStarted') { throw 'Creation was interrupted before VM ID was journaled; inspect orphan resources before rollback.' }
            $journal.phase = 'RollbackStarted'; Save-Journal
            Stop-LabVmGracefully $request.existingVmId
            $vm = Get-LabVm $request.existingVmId
            $original = $journal.original
            Set-VMProcessor -VM $vm -Count $original.cpu -ExposeVirtualizationExtensions $original.nested
            Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes $original.startup
            if ($original.dynamic) { Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $original.minimum -MaximumBytes $original.maximum }
            $nic = @(Get-VMNetworkAdapter -VM $vm | Where-Object { [string]$_.Id -eq $original.nicId })
            if ($nic.Count -ne 1) { throw 'Original NIC changed; inspect before restoring spoofing.' }
            $nic[0] | Set-VMNetworkAdapter -MacAddressSpoofing $original.spoofing
            if ($original.state -eq 'Running') { Start-LabVm $request.existingVmId -RequireHeartbeat -ReserveGiB $journal.originalReserveGiB }
            $journal.phase = 'RolledBack'; Save-Journal
        }
        $report.status = 'PARTIAL'
    }
}
catch {
    $report.status = 'BLOCKED'
    $report.errorType = $_.Exception.GetType().FullName
    # Fixed helper errors contain no credentials. Do not upload raw Hyper-V exception bodies.
    throw
}
finally {
    if ($journal) { $report.journalPhase = $journal.phase }
    try {
        $current = Get-VM -Id ([guid]$request.existingVmId)
        $cpu = Get-VMProcessor -VM $current
        $memory = Get-VMMemory -VM $current
        $report.existingVm = [ordered]@{ id = [string]$current.Id; state = [string]$current.State; heartbeat = [string]$current.Heartbeat; cpu = $cpu.Count; nested = [bool]$cpu.ExposeVirtualizationExtensions; startupGiB = $memory.Startup / 1GB; dynamic = [bool]$memory.DynamicMemoryEnabled }
    }
    catch { $report.existingVmEvidence = 'UNKNOWN' }
    $lock.Dispose()
    if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Evidence directory must be unique per invocation.' }
    New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8
}
