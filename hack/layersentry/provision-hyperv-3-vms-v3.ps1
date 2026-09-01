[CmdletBinding()]
param(
    [string]$IsoPath = 'C:\Users\opc\Downloads\final iso\layersentry-v1.0-amd64.iso',
    [string]$SwitchName = 'Cozystack-NAT',
    [string]$NatName = 'Cozystack-NAT',
    [string]$VmRoot = 'C:\Hyper-V\LayerSentry',
    [string]$EvidenceDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-create-3-vms-v3')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

$ExpectedSha256 = 'bc1ca4540faa79ebf6c26f185ebd99247b222077c5310541e06a3acbc2bbda1e'
$ExpectedSha512 = '886872ab84a93e0aa314d8f38cd2f455488e604574e4cd0f05dbbf3dd1601fed23657b2fbcc6b342d11215fbaac9b65d549c08e8386a916b5c23e6c7742e10fe'
$Gateway = '10.10.10.1'
$ClusterVip = '10.10.10.10'
$NatPrefix = '10.10.10.0/24'
$Nodes = @(
    [pscustomobject]@{ Name = 'sen1'; Address = '10.10.10.11/24'; StartDelay = 0 },
    [pscustomobject]@{ Name = 'sen2'; Address = '10.10.10.12/24'; StartDelay = 45 },
    [pscustomobject]@{ Name = 'sen3'; Address = '10.10.10.13/24'; StartDelay = 90 }
)

function Convert-ToGiB {
    param([AllowNull()][object]$Bytes)
    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 4)
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NodeEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Address
    )

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        return [pscustomobject]@{ Name = $Name; Exists = $false; State = 'Absent' }
    }

    $processor = Get-VMProcessor -VMName $Name -ErrorAction Stop
    $memory = Get-VMMemory -VMName $Name -ErrorAction Stop
    $firmware = Get-VMFirmware -VMName $Name -ErrorAction Stop
    $adapter = Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop | Select-Object -First 1
    $dvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $diskEvidence = foreach ($drive in @(Get-VMHardDiskDrive -VMName $Name -ErrorAction Stop)) {
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
        StartupMemoryGiB = Convert-ToGiB $memory.Startup
        AssignedMemoryGiB = Convert-ToGiB $vm.MemoryAssigned
        DynamicMemoryEnabled = $memory.DynamicMemoryEnabled
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
        ReportedIPAddresses = @($adapter.IPAddresses)
        PlannedAddress = $Address
        PlannedClusterVip = $ClusterVip
        HardDisks = @($diskEvidence)
        DvdPath = if ($null -ne $dvd) { $dvd.Path } else { $null }
        Notes = $vm.Notes
    }
}

if (Test-Path -LiteralPath $EvidenceDirectory) {
    Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force
}
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).ProviderPath

$CreatedNames = New-Object System.Collections.Generic.List[string]
$ReusedNames = New-Object System.Collections.Generic.List[string]
$StartedNames = New-Object System.Collections.Generic.List[string]
$FatalError = $null
$ActualSha256 = $null
$ActualSha512 = $null
$FreeMemoryBeforeGiB = $null
$FreeMemoryAfterGiB = $null
$FreeStorageBeforeGiB = $null
$FreeStorageAfterGiB = $null

try {
    if (-not (Test-Administrator)) {
        throw 'The self-hosted runner identity is not a local administrator.'
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
        throw "ISO SHA-256 mismatch. Found $ActualSha256"
    }

    $sidecarText = [System.IO.File]::ReadAllText($sha512Path).Trim()
    if ($sidecarText -notmatch '^(?<hash>[0-9A-Fa-f]{128})\s+.+$') {
        throw 'The ISO SHA-512 sidecar is not in sha512sum format.'
    }
    $sidecarHash = $Matches['hash'].ToLowerInvariant()
    $ActualSha512 = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($sidecarHash -ne $ExpectedSha512 -or $ActualSha512 -ne $ExpectedSha512) {
        throw 'ISO SHA-512 verification failed.'
    }

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    if ([string]$switch.SwitchType -ne 'Internal') {
        throw "Hyper-V switch $SwitchName is not Internal."
    }
    $nat = Get-NetNat -Name $NatName -ErrorAction Stop
    if ($nat.InternalIPInterfaceAddressPrefix -ne $NatPrefix) {
        throw "NAT $NatName does not use $NatPrefix."
    }
    $gatewayAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Gateway -ErrorAction Stop
    if ($gatewayAddress.PrefixLength -ne 24) {
        throw "Gateway $Gateway does not use prefix length 24."
    }

    $FreeMemoryBeforeGiB = [math]::Round(((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB), 4)
    $FreeStorageBeforeGiB = Convert-ToGiB ((Get-Volume -DriveLetter C).SizeRemaining)
    if ($FreeMemoryBeforeGiB -lt 96) {
        throw "The host has only $FreeMemoryBeforeGiB GiB free RAM; 96 GiB is required to start all nodes."
    }
    if ($FreeStorageBeforeGiB -lt 100) {
        throw "The host has only $FreeStorageBeforeGiB GiB free storage for sparse VHDX files."
    }

    New-Item -Path $VmRoot -ItemType Directory -Force | Out-Null

    foreach ($node in $Nodes) {
        $name = [string]$node.Name
        $vmBase = Join-Path $VmRoot $name
        $vhdDirectory = Join-Path $vmBase 'Virtual Hard Disks'
        $osDiskPath = Join-Path $vhdDirectory "$name-os.vhdx"
        $dataDiskPath = Join-Path $vhdDirectory "$name-data.vhdx"
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue

        if ($null -eq $vm) {
            New-Item -Path $vhdDirectory -ItemType Directory -Force | Out-Null
            if (Test-Path -LiteralPath $osDiskPath) {
                throw "OS disk exists without its expected VM. Path: $osDiskPath"
            }
            New-VM -Name $name -Generation 2 -Path $vmBase `
                -MemoryStartupBytes 32GB `
                -NewVHDPath $osDiskPath `
                -NewVHDSizeBytes 100GB `
                -SwitchName $SwitchName | Out-Null
            $CreatedNames.Add($name)
        }
        else {
            if ([int]$vm.Generation -ne 2) {
                throw "Existing VM $name is not Generation 2."
            }
            $attachedPaths = @(Get-VMHardDiskDrive -VMName $name -ErrorAction Stop | Select-Object -ExpandProperty Path)
            if ($attachedPaths -notcontains $osDiskPath) {
                throw "Existing VM $name does not use expected OS disk $osDiskPath."
            }
            if ($vm.State -ne 'Off') {
                Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop
            }
            $ReusedNames.Add($name)
        }

        Set-VMProcessor -VMName $name -Count 10 -ExposeVirtualizationExtensions $true
        Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes 32GB
        Set-VM -Name $name `
            -AutomaticCheckpointsEnabled $false `
            -CheckpointType Disabled `
            -AutomaticStartAction Start `
            -AutomaticStartDelay ([int]$node.StartDelay) `
            -AutomaticStopAction ShutDown
        Set-VMFirmware -VMName $name -EnableSecureBoot Off

        $adapter = Get-VMNetworkAdapter -VMName $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $adapter) {
            Add-VMNetworkAdapter -VMName $name -SwitchName $SwitchName -Name 'Network Adapter'
        }
        else {
            Connect-VMNetworkAdapter -VMName $name -Name $adapter.Name -SwitchName $SwitchName
        }
        $adapter = Get-VMNetworkAdapter -VMName $name -ErrorAction Stop | Select-Object -First 1
        Set-VMNetworkAdapter -VMName $name -Name $adapter.Name `
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
            "Planned node IP: $($node.Address)"
            "Cluster VIP: $ClusterVip"
            "Gateway: $Gateway"
            "ISO SHA-256: $ExpectedSha256"
            "Provisioned by GitHub Actions run $env:GITHUB_RUN_ID"
        ) -join [Environment]::NewLine
        Set-VM -Name $name -Notes $notes
    }

    foreach ($node in $Nodes) {
        $name = [string]$node.Name
        Start-VM -Name $name -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        do {
            Start-Sleep -Seconds 3
            $state = (Get-VM -Name $name -ErrorAction Stop).State
        } while ($state -ne 'Running' -and (Get-Date) -lt $deadline)
        if ($state -ne 'Running') {
            throw "VM $name did not reach Running state. Current state: $state"
        }
        $StartedNames.Add($name)
        Start-Sleep -Seconds 12
    }
}
catch {
    $FatalError = $_.Exception.Message
}
finally {
    try {
        $FreeMemoryAfterGiB = [math]::Round(((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB), 4)
        $FreeStorageAfterGiB = Convert-ToGiB ((Get-Volume -DriveLetter C).SizeRemaining)
    }
    catch {
        # Leave unavailable host telemetry fields empty.
    }

    $NodeEvidence = foreach ($node in $Nodes) {
        try {
            Get-NodeEvidence -Name ([string]$node.Name) -Address ([string]$node.Address)
        }
        catch {
            [pscustomobject]@{
                Name = [string]$node.Name
                Exists = [bool](Get-VM -Name ([string]$node.Name) -ErrorAction SilentlyContinue)
                State = 'EvidenceError'
                Error = $_.Exception.Message
            }
        }
    }
    $AllRunning = @($NodeEvidence | Where-Object { -not $_.Exists -or $_.State -ne 'Running' }).Count -eq 0

    $Report = [pscustomobject]@{
        SchemaVersion = '3.0'
        CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Operation = 'create-configure-start-three-layer-sentry-vms'
        AuthorizedByUser = $true
        Host = [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            FreeMemoryBeforeGiB = $FreeMemoryBeforeGiB
            FreeMemoryAfterGiB = $FreeMemoryAfterGiB
            FreeStorageBeforeGiB = $FreeStorageBeforeGiB
            FreeStorageAfterGiB = $FreeStorageAfterGiB
        }
        CapacityRiskAccepted = [pscustomobject]@{
            StaticVmMemoryTotalGiB = 96
            MaximumVirtualDiskCapacityGiB = 1200
            LowHostMemoryReserve = $true
            SparseVhdxFullGrowthCanExceedCurrentFreeStorage = $true
        }
        NetworkPlan = [pscustomobject]@{
            Switch = $SwitchName
            Nat = $NatName
            Prefix = $NatPrefix
            Gateway = $Gateway
            ClusterVip = $ClusterVip
            Nodes = @($Nodes)
        }
        ISO = [pscustomobject]@{
            Path = $IsoPath
            LengthBytes = if (Test-Path -LiteralPath $IsoPath -PathType Leaf) { (Get-Item -LiteralPath $IsoPath).Length } else { $null }
            Sha256 = $ActualSha256
            Sha512 = $ActualSha512
            IntegrityVerified = ($ActualSha256 -eq $ExpectedSha256 -and $ActualSha512 -eq $ExpectedSha512)
            Classification = 'POC_CANDIDATE_NOT_PRODUCTION_APPROVED'
        }
        CreatedVMs = @($CreatedNames)
        ReusedVMs = @($ReusedNames)
        StartedVMs = @($StartedNames)
        VirtualMachines = @($NodeEvidence)
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
        'LayerSentry three-node Hyper-V provisioning V3'
        "Host: $env:COMPUTERNAME"
        "ISO: $IsoPath"
        "ISO SHA-256: $ActualSha256"
        "Created VMs: $($CreatedNames -join ', ')"
        "Reused VMs: $($ReusedNames -join ', ')"
        "Started VMs: $($StartedNames -join ', ')"
        "All running: $AllRunning"
        "Free RAM before and after: $FreeMemoryBeforeGiB / $FreeMemoryAfterGiB GiB"
        "Free storage before and after: $FreeStorageBeforeGiB / $FreeStorageAfterGiB GiB"
        "Fatal error: $FatalError"
        ''
        ($NodeEvidence | Select-Object Name, Exists, State, Generation, VCPU, StartupMemoryGiB, DynamicMemoryEnabled, NestedVirtualization, SecureBoot, SwitchName, PlannedAddress |
            Format-Table -AutoSize | Out-String -Width 300)
        'The verified candidate ISO was selected as first boot device.'
        'Installation and production qualification remain pending.'
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

Write-Host 'LAYERSENTRY THREE-VM PROVISIONING V3: PASS'
