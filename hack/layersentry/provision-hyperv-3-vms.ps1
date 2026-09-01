[CmdletBinding()]
param(
    [string]$IsoPath = 'C:\Users\opc\Downloads\final iso\layersentry-v1.0-amd64.iso',
    [string]$SwitchName = 'Cozystack-NAT',
    [string]$NatName = 'Cozystack-NAT',
    [string]$VmRoot = 'C:\Hyper-V\LayerSentry',
    [string]$EvidenceDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-create-3-vms')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$ExpectedSha256 = 'bc1ca4540faa79ebf6c26f185ebd99247b222077c5310541e06a3acbc2bbda1e'
$ExpectedSha512 = '886872ab84a93e0aa314d8f38cd2f455488e604574e4cd0f05dbbf3dd1601fed23657b2fbcc6b342d11215fbaac9b65d549c08e8386a916b5c23e6c7742e10fe'
$NatPrefix = '10.10.10.0/24'
$Gateway = '10.10.10.1'
$ClusterVip = '10.10.10.10'
$VmNames = @('sen1', 'sen2', 'sen3')
$NodeAddresses = @{
    sen1 = '10.10.10.11/24'
    sen2 = '10.10.10.12/24'
    sen3 = '10.10.10.13/24'
}
$StartDelays = @{
    sen1 = 0
    sen2 = 45
    sen3 = 90
}

function Convert-ToGiB {
    param([AllowNull()][object]$Bytes)
    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 4)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NodeEvidence {
    param([Parameter(Mandatory = $true)][string]$Name)

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        return [pscustomobject]@{
            Name = $Name
            Exists = $false
            State = 'Absent'
        }
    }

    $processor = Get-VMProcessor -VMName $Name -ErrorAction Stop
    $memory = Get-VMMemory -VMName $Name -ErrorAction Stop
    $firmware = Get-VMFirmware -VMName $Name -ErrorAction Stop
    $adapter = Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop | Select-Object -First 1
    $dvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $hardDisks = foreach ($drive in @(Get-VMHardDiskDrive -VMName $Name -ErrorAction Stop)) {
        $vhd = Get-VHD -Path $drive.Path -ErrorAction Stop
        [pscustomobject]@{
            Path = $drive.Path
            ControllerType = [string]$drive.ControllerType
            ControllerNumber = $drive.ControllerNumber
            ControllerLocation = $drive.ControllerLocation
            VhdType = [string]$vhd.VhdType
            VirtualSizeGiB = Convert-ToGiB $vhd.Size
            FileSizeGiB = Convert-ToGiB $vhd.FileSize
        }
    }

    return [pscustomobject]@{
        Name = $Name
        Exists = $true
        State = [string]$vm.State
        Status = $vm.Status
        Generation = [int]$vm.Generation
        VCPU = $processor.Count
        StaticMemory = (-not $memory.DynamicMemoryEnabled)
        StartupMemoryGiB = Convert-ToGiB $memory.Startup
        AssignedMemoryGiB = Convert-ToGiB $vm.MemoryAssigned
        NestedVirtualization = $processor.ExposeVirtualizationExtensions
        SecureBoot = [string]$firmware.SecureBoot
        CheckpointType = [string]$vm.CheckpointType
        AutomaticStartAction = [string]$vm.AutomaticStartAction
        AutomaticStartDelaySeconds = $vm.AutomaticStartDelay
        AutomaticStopAction = [string]$vm.AutomaticStopAction
        SwitchName = $adapter.SwitchName
        NetworkStatus = [string]$adapter.Status
        MacAddress = $adapter.MacAddress
        MacAddressSpoofing = [string]$adapter.MacAddressSpoofing
        PlannedAddress = $NodeAddresses[$Name]
        PlannedVip = $ClusterVip
        HardDisks = @($hardDisks)
        DvdPath = if ($null -ne $dvd) { $dvd.Path } else { $null }
        Notes = $vm.Notes
    }
}

if (Test-Path -LiteralPath $EvidenceDirectory) {
    Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force
}
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).ProviderPath

$Created = New-Object System.Collections.Generic.List[string]
$Reused = New-Object System.Collections.Generic.List[string]
$Started = New-Object System.Collections.Generic.List[string]
$FatalError = $null
$ActualSha256 = $null
$ActualSha512 = $null
$FreeMemoryBefore = $null
$FreeMemoryAfter = $null
$FreeStorageBefore = $null
$FreeStorageAfter = $null

try {
    if (-not (Test-IsAdministrator)) {
        throw 'The GitHub runner identity is not a local administrator.'
    }

    $vmms = Get-Service -Name vmms -ErrorAction Stop
    if ($vmms.Status -ne 'Running') {
        throw "Hyper-V VMMS is $($vmms.Status), not Running."
    }

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "LayerSentry ISO not found: $IsoPath"
    }
    $sha512Path = "$IsoPath.sha512"
    if (-not (Test-Path -LiteralPath $sha512Path -PathType Leaf)) {
        throw "LayerSentry SHA-512 sidecar not found: $sha512Path"
    }

    $ActualSha256 = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "ISO SHA-256 mismatch: $ActualSha256"
    }

    $sidecarText = [System.IO.File]::ReadAllText($sha512Path).Trim()
    if ($sidecarText -notmatch '^(?<hash>[0-9A-Fa-f]{128})\s+.+$') {
        throw 'The SHA-512 sidecar is not in sha512sum format.'
    }
    $sidecarHash = $Matches['hash'].ToLowerInvariant()
    $ActualSha512 = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($sidecarHash -ne $ExpectedSha512 -or $ActualSha512 -ne $ExpectedSha512) {
        throw 'ISO SHA-512 verification failed.'
    }

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    if ([string]$switch.SwitchType -ne 'Internal') {
        throw "$SwitchName is not an Internal Hyper-V switch."
    }
    $nat = Get-NetNat -Name $NatName -ErrorAction Stop
    if ($nat.InternalIPInterfaceAddressPrefix -ne $NatPrefix) {
        throw "$NatName uses $($nat.InternalIPInterfaceAddressPrefix), expected $NatPrefix."
    }
    $gatewayAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Gateway -ErrorAction Stop
    if ($gatewayAddress.PrefixLength -ne 24) {
        throw "$Gateway does not use prefix length 24."
    }

    $FreeMemoryBefore = [math]::Round(((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB), 4)
    $FreeStorageBefore = Convert-ToGiB ((Get-Volume -DriveLetter C).SizeRemaining)
    if ($FreeMemoryBefore -lt 96) {
        throw "Less than 96 GiB free RAM is available: $FreeMemoryBefore GiB"
    }
    if ($FreeStorageBefore -lt 100) {
        throw "Less than 100 GiB physical storage is free: $FreeStorageBefore GiB"
    }

    New-Item -Path $VmRoot -ItemType Directory -Force | Out-Null

    foreach ($name in $VmNames) {
        $vmBase = Join-Path $VmRoot $name
        $vhdDirectory = Join-Path $vmBase 'Virtual Hard Disks'
        $osDiskPath = Join-Path $vhdDirectory "$name-os.vhdx"
        $dataDiskPath = Join-Path $vhdDirectory "$name-data.vhdx"
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue

        if ($null -eq $vm) {
            New-Item -Path $vhdDirectory -ItemType Directory -Force | Out-Null
            if (Test-Path -LiteralPath $osDiskPath) {
                throw "OS disk exists without VM $name: $osDiskPath"
            }
            New-VM -Name $name -Generation 2 -Path $vmBase `
                -MemoryStartupBytes 32GB `
                -NewVHDPath $osDiskPath `
                -NewVHDSizeBytes 100GB `
                -SwitchName $SwitchName | Out-Null
            $Created.Add($name)
        }
        else {
            if ([int]$vm.Generation -ne 2) {
                throw "Existing VM $name is not Generation 2."
            }
            $attachedOsDisks = @(Get-VMHardDiskDrive -VMName $name -ErrorAction Stop | Select-Object -ExpandProperty Path)
            if ($attachedOsDisks -notcontains $osDiskPath) {
                throw "Existing VM $name does not use expected OS disk $osDiskPath."
            }
            if ($vm.State -ne 'Off') {
                Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop
            }
            $Reused.Add($name)
        }

        Set-VMProcessor -VMName $name -Count 10 -ExposeVirtualizationExtensions $true
        Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 32GB
        Set-VM -Name $name `
            -AutomaticCheckpointsEnabled $false `
            -CheckpointType Disabled `
            -AutomaticStartAction Start `
            -AutomaticStartDelay $StartDelays[$name] `
            -AutomaticStopAction ShutDown
        Set-VMFirmware -VMName $name -EnableSecureBoot Off

        $adapter = Get-VMNetworkAdapter -VMName $name -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $adapter) {
            Add-VMNetworkAdapter -VMName $name -SwitchName $SwitchName -Name 'Network Adapter'
            $adapter = Get-VMNetworkAdapter -VMName $name -ErrorAction Stop | Select-Object -First 1
        }
        if ($adapter.SwitchName -ne $SwitchName) {
            $adapter | Connect-VMNetworkAdapter -SwitchName $SwitchName
        }
        $adapter = Get-VMNetworkAdapter -VMName $name -ErrorAction Stop | Select-Object -First 1
        $adapter | Set-VMNetworkAdapter `
            -MacAddressSpoofing On `
            -DhcpGuard Off `
            -RouterGuard Off

        $attachedPaths = @(Get-VMHardDiskDrive -VMName $name -ErrorAction Stop | Select-Object -ExpandProperty Path)
        if ($attachedPaths -notcontains $dataDiskPath) {
            if (-not (Test-Path -LiteralPath $dataDiskPath)) {
                New-VHD -Path $dataDiskPath -Dynamic -SizeBytes 300GB | Out-Null
            }
            Add-VMHardDiskDrive -VMName $name -ControllerType SCSI -Path $dataDiskPath
        }

        $dvd = Get-VMDvdDrive -VMName $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $dvd) {
            $dvd = Add-VMDvdDrive -VMName $name -Path $IsoPath -Passthru
        }
        else {
            Set-VMDvdDrive -VMName $name `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $IsoPath
            $dvd = Get-VMDvdDrive -VMName $name -ErrorAction Stop | Select-Object -First 1
        }
        Set-VMFirmware -VMName $name -FirstBootDevice $dvd

        $notes = @(
            'LayerSentry v1.0 POC node'
            'Embedded platform target: Harvester v1.8.2'
            "Planned node IP: $($NodeAddresses[$name])"
            "Cluster VIP: $ClusterVip"
            "Gateway: $Gateway"
            "ISO SHA-256: $ExpectedSha256"
            "Provisioned by GitHub Actions run $env:GITHUB_RUN_ID"
        ) -join [Environment]::NewLine
        Set-VM -Name $name -Notes $notes
    }

    foreach ($name in $VmNames) {
        Start-VM -Name $name -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 3
            $state = (Get-VM -Name $name -ErrorAction Stop).State
        } while ($state -ne 'Running' -and (Get-Date) -lt $deadline)
        if ($state -ne 'Running') {
            throw "$name did not reach Running state; current state: $state"
        }
        $Started.Add($name)
        Start-Sleep -Seconds 12
    }
}
catch {
    $FatalError = $_.Exception.Message
}
finally {
    try {
        $FreeMemoryAfter = [math]::Round(((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB), 4)
        $FreeStorageAfter = Convert-ToGiB ((Get-Volume -DriveLetter C).SizeRemaining)
    }
    catch {
        # Leave unavailable telemetry fields null.
    }

    $Nodes = foreach ($name in $VmNames) {
        try { Get-NodeEvidence -Name $name }
        catch {
            [pscustomobject]@{
                Name = $name
                Exists = [bool](Get-VM -Name $name -ErrorAction SilentlyContinue)
                State = 'EvidenceError'
                Error = $_.Exception.Message
            }
        }
    }
    $AllRunning = @($Nodes | Where-Object { -not $_.Exists -or $_.State -ne 'Running' }).Count -eq 0

    $Report = [pscustomobject]@{
        SchemaVersion = '2.0'
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Operation = 'create-configure-start-three-layer-sentry-vms'
        AuthorizedByUser = $true
        Runner = [pscustomobject]@{
            Repository = $env:GITHUB_REPOSITORY
            Workflow = $env:GITHUB_WORKFLOW
            RunId = $env:GITHUB_RUN_ID
            RunnerName = $env:RUNNER_NAME
            Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        Host = [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            FreeMemoryBeforeGiB = $FreeMemoryBefore
            FreeMemoryAfterGiB = $FreeMemoryAfter
            FreeStorageBeforeGiB = $FreeStorageBefore
            FreeStorageAfterGiB = $FreeStorageAfter
        }
        AcceptedCapacityRisk = [pscustomobject]@{
            StaticVmMemoryTotalGiB = 96
            MaximumVirtualDiskCapacityGiB = 1200
            LowHostMemoryReserve = $true
            DynamicVhdxMayExceedCurrentFreeStorageAtFullGrowth = $true
        }
        NetworkPlan = [pscustomobject]@{
            Switch = $SwitchName
            Nat = $NatName
            Prefix = $NatPrefix
            Gateway = $Gateway
            ClusterVip = $ClusterVip
            Nodes = $NodeAddresses
        }
        ISO = [pscustomobject]@{
            Path = $IsoPath
            LengthBytes = if (Test-Path -LiteralPath $IsoPath -PathType Leaf) { (Get-Item -LiteralPath $IsoPath).Length } else { $null }
            Sha256 = $ActualSha256
            Sha512 = $ActualSha512
            IntegrityVerified = ($ActualSha256 -eq $ExpectedSha256 -and $ActualSha512 -eq $ExpectedSha512)
            Classification = 'POC_CANDIDATE_NOT_PRODUCTION_APPROVED'
        }
        CreatedVMs = @($Created)
        ReusedVMs = @($Reused)
        StartedVMs = @($Started)
        VirtualMachines = @($Nodes)
        AllRunning = $AllRunning
        FatalError = $FatalError
        InstallerBootRequested = $true
        InstallationCompleted = $false
        RuntimeQualified = $false
        ProductionIsoApproved = $false
    }

    $jsonPath = Join-Path $EvidenceDirectory 'layersentry-three-vm-provisioning.json'
    $summaryPath = Join-Path $EvidenceDirectory 'layersentry-three-vm-provisioning.txt'
    $Report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    @(
        'LayerSentry three-node Hyper-V provisioning'
        "Host: $env:COMPUTERNAME"
        "ISO: $IsoPath"
        "ISO SHA-256: $ActualSha256"
        "Created VMs: $($Created -join ', ')"
        "Reused VMs: $($Reused -join ', ')"
        "Started VMs: $($Started -join ', ')"
        "All running: $AllRunning"
        "Free RAM before / after: $FreeMemoryBefore / $FreeMemoryAfter GiB"
        "Free storage before / after: $FreeStorageBefore / $FreeStorageAfter GiB"
        "Fatal error: $FatalError"
        ''
        ($Nodes | Select-Object Name, Exists, State, Generation, VCPU, StaticMemory, StartupMemoryGiB, NestedVirtualization, SecureBoot, SwitchName, PlannedAddress |
            Format-Table -AutoSize | Out-String -Width 300)
        'Installer boot was requested. Installation and production qualification remain pending.'
    ) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    $HashLines = foreach ($file in @(Get-ChildItem -LiteralPath $EvidenceDirectory -File)) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
    }
    $HashLines | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'SHA256SUMS.txt') -Encoding ASCII
    Get-Content -LiteralPath $summaryPath
}

if ($null -ne $FatalError) { throw $FatalError }
if (-not $AllRunning) { throw 'Not all three LayerSentry VMs are Running.' }

Write-Host 'LAYERSENTRY THREE-VM PROVISIONING: PASS'
