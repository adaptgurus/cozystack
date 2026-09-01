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
    if ($null -eq $Bytes) {
        return $null
    }
    return [math]::Round(([double]$Bytes / 1GB), 4)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VMProvisioningEvidence {
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
    $network = Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop
    $firmware = Get-VMFirmware -VMName $Name -ErrorAction Stop
    $dvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue

    $hardDisks = foreach ($drive in @(Get-VMHardDiskDrive -VMName $Name -ErrorAction Stop)) {
        $vhd = $null
        $inspectionError = $null
        try {
            $vhd = Get-VHD -Path $drive.Path -ErrorAction Stop
        }
        catch {
            $inspectionError = $_.Exception.Message
        }

        [pscustomobject]@{
            Path = $drive.Path
            ControllerType = [string]$drive.ControllerType
            ControllerNumber = $drive.ControllerNumber
            ControllerLocation = $drive.ControllerLocation
            VhdType = if ($null -ne $vhd) { [string]$vhd.VhdType } else { $null }
            VirtualSizeGiB = if ($null -ne $vhd) { Convert-ToGiB $vhd.Size } else { $null }
            FileSizeGiB = if ($null -ne $vhd) { Convert-ToGiB $vhd.FileSize } else { $null }
            InspectionError = $inspectionError
        }
    }

    return [pscustomobject]@{
        Name = $Name
        Exists = $true
        State = [string]$vm.State
        Status = $vm.Status
        Generation = [int]$vm.Generation
        Version = [string]$vm.Version
        ConfigurationPath = $vm.Path
        Uptime = [string]$vm.Uptime
        VCPU = $processor.Count
        ExposeVirtualizationExtensions = $processor.ExposeVirtualizationExtensions
        DynamicMemoryEnabled = $memory.DynamicMemoryEnabled
        StartupMemoryGiB = Convert-ToGiB $memory.Startup
        AssignedMemoryGiB = Convert-ToGiB $vm.MemoryAssigned
        SecureBoot = [string]$firmware.SecureBoot
        CheckpointType = [string]$vm.CheckpointType
        AutomaticStartAction = [string]$vm.AutomaticStartAction
        AutomaticStartDelaySeconds = $vm.AutomaticStartDelay
        AutomaticStopAction = [string]$vm.AutomaticStopAction
        PlannedNodeAddress = $NodeAddresses[$Name]
        PlannedClusterVip = $ClusterVip
        Network = [pscustomobject]@{
            SwitchName = $network.SwitchName
            Status = [string]$network.Status
            Connected = $network.Connected
            MacAddress = $network.MacAddress
            MacAddressSpoofing = [string]$network.MacAddressSpoofing
            DhcpGuard = [string]$network.DhcpGuard
            RouterGuard = [string]$network.RouterGuard
            IPAddresses = @($network.IPAddresses)
        }
        HardDisks = @($hardDisks)
        DVD = if ($null -ne $dvd) {
            [pscustomobject]@{
                Path = $dvd.Path
                ControllerNumber = $dvd.ControllerNumber
                ControllerLocation = $dvd.ControllerLocation
            }
        }
        else {
            $null
        }
        Notes = $vm.Notes
    }
}

if (Test-Path -LiteralPath $EvidenceDirectory) {
    Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force
}
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$EvidenceDirectory = (Resolve-Path -LiteralPath $EvidenceDirectory).ProviderPath

$CreatedNames = New-Object System.Collections.Generic.List[string]
$ExistingExpectedNames = New-Object System.Collections.Generic.List[string]
$StartFailures = New-Object System.Collections.Generic.List[string]
$FatalError = $null
$ActualSha256 = $null
$ActualSha512 = $null
$TotalMemoryGiB = $null
$FreeMemoryBeforeGiB = $null
$FreeMemoryAfterGiB = $null
$FreeStorageBeforeGiB = $null
$FreeStorageAfterGiB = $null

try {
    if (-not (Test-IsAdministrator)) {
        throw 'The runner identity is not a local administrator.'
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
        throw "LayerSentry ISO SHA-512 sidecar not found: $sha512Path"
    }

    $ActualSha256 = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha256 -ne $ExpectedSha256) {
        throw "ISO SHA-256 mismatch. Expected $ExpectedSha256 but found $ActualSha256"
    }

    $sidecarText = [System.IO.File]::ReadAllText($sha512Path).Trim()
    if ($sidecarText -notmatch '^(?<hash>[0-9A-Fa-f]{128})\s+.+$') {
        throw 'The ISO SHA-512 sidecar is not in sha512sum format.'
    }
    $sidecarSha512 = $Matches['hash'].ToLowerInvariant()
    $ActualSha512 = (Get-FileHash -LiteralPath $IsoPath -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($sidecarSha512 -ne $ExpectedSha512 -or $ActualSha512 -ne $ExpectedSha512) {
        throw 'ISO SHA-512 verification failed.'
    }

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
    if ([string]$switch.SwitchType -ne 'Internal') {
        throw "Hyper-V switch $SwitchName is not Internal."
    }

    $nat = Get-NetNat -Name $NatName -ErrorAction Stop
    if ($nat.InternalIPInterfaceAddressPrefix -ne $NatPrefix) {
        throw "NAT $NatName uses $($nat.InternalIPInterfaceAddressPrefix); expected $NatPrefix."
    }

    $gatewayAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Gateway -ErrorAction Stop
    if ($gatewayAddress.PrefixLength -ne 24) {
        throw "NAT gateway $Gateway does not use prefix length 24."
    }

    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $volumeC = Get-Volume -DriveLetter C -ErrorAction Stop
    $TotalMemoryGiB = Convert-ToGiB $computer.TotalPhysicalMemory
    $FreeMemoryBeforeGiB = [math]::Round(([double]$operatingSystem.FreePhysicalMemory / 1MB), 4)
    $FreeStorageBeforeGiB = Convert-ToGiB $volumeC.SizeRemaining

    if ($FreeMemoryBeforeGiB -lt 96) {
        throw "Less than the required 96 GiB free RAM is available: $FreeMemoryBeforeGiB GiB"
    }
    if ($FreeStorageBeforeGiB -lt 100) {
        throw "Less than 100 GiB physical storage is free for sparse VHDX creation: $FreeStorageBeforeGiB GiB"
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
            if ((Test-Path -LiteralPath $osDiskPath) -or (Test-Path -LiteralPath $dataDiskPath)) {
                throw "VHDX files exist without VM $name in $vhdDirectory. Manual review is required."
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
                throw "Existing VM $name is not Generation 2. Refusing to modify it."
            }
            $attachedPaths = @(Get-VMHardDiskDrive -VMName $name -ErrorAction Stop | Select-Object -ExpandProperty Path)
            if ($attachedPaths -notcontains $osDiskPath) {
                throw "Existing VM $name is not attached to expected OS disk $osDiskPath."
            }
            $ExistingExpectedNames.Add($name)
            if ($vm.State -ne 'Off') {
                Stop-VM -Name $name -TurnOff -Force -ErrorAction Stop
            }
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
        Set-VMNetworkAdapter -VMName $name `
            -SwitchName $SwitchName `
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

        $dvd = Get-VMDvdDrive -VMName $name -ErrorAction SilentlyContinue
        if ($null -eq $dvd) {
            $dvd = Add-VMDvdDrive -VMName $name -Path $IsoPath -Passthru
        }
        else {
            Set-VMDvdDrive -VMName $name `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $IsoPath
            $dvd = Get-VMDvdDrive -VMName $name -ErrorAction Stop
        }
        Set-VMFirmware -VMName $name -FirstBootDevice $dvd

        $notes = @(
            'LayerSentry v1.0 POC node'
            'Embedded platform target: Harvester v1.8.2'
            "Planned node IP: $($NodeAddresses[$name])"
            "Cluster VIP plan: $ClusterVip"
            "Gateway: $Gateway"
            "ISO SHA-256: $ExpectedSha256"
            "Provisioned by GitHub Actions run $env:GITHUB_RUN_ID"
        ) -join [Environment]::NewLine
        Set-VM -Name $name -Notes $notes
    }

    foreach ($name in $VmNames) {
        try {
            Start-VM -Name $name -ErrorAction Stop | Out-Null
            $deadline = (Get-Date).AddMinutes(3)
            do {
                Start-Sleep -Seconds 3
                $state = (Get-VM -Name $name -ErrorAction Stop).State
            } while ($state -ne 'Running' -and (Get-Date) -lt $deadline)

            if ($state -ne 'Running') {
                throw "VM did not reach Running state; current state is $state"
            }
            Start-Sleep -Seconds 15
        }
        catch {
            $StartFailures.Add("${name}: $($_.Exception.Message)")
        }
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
        # Evidence fields remain null when host telemetry is unavailable.
    }

    $vmEvidence = foreach ($name in $VmNames) {
        try {
            Get-VMProvisioningEvidence -Name $name
        }
        catch {
            [pscustomobject]@{
                Name = $name
                Exists = [bool](Get-VM -Name $name -ErrorAction SilentlyContinue)
                State = 'EvidenceError'
                Error = $_.Exception.Message
            }
        }
    }

    $allRunning = @($vmEvidence | Where-Object { -not $_.Exists -or $_.State -ne 'Running' }).Count -eq 0
    $report = [pscustomobject]@{
        SchemaVersion = '1.0'
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
            TotalMemoryGiB = $TotalMemoryGiB
            FreeMemoryBeforeGiB = $FreeMemoryBeforeGiB
            FreeMemoryAfterGiB = $FreeMemoryAfterGiB
            FreeStorageBeforeGiB = $FreeStorageBeforeGiB
            FreeStorageAfterGiB = $FreeStorageAfterGiB
        }
        CapacityRisk = [pscustomobject]@{
            RequestedStaticVmMemoryGiB = 96
            RequestedMaximumVirtualDiskGiB = 1200
            MemoryReserveRiskAcceptedByUser = $true
            DynamicVhdxFullGrowthRiskAcceptedByUser = $true
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
        CreatedVMs = @($CreatedNames)
        ReusedExpectedVMs = @($ExistingExpectedNames)
        VirtualMachines = @($vmEvidence)
        StartFailures = @($StartFailures)
        FatalError = $FatalError
        AllRunning = $allRunning
        InstallationPerformed = $false
        RuntimeQualified = $false
        ReleaseApproved = $false
    }

    $jsonPath = Join-Path $EvidenceDirectory 'layersentry-three-vm-provisioning.json'
    $summaryPath = Join-Path $EvidenceDirectory 'layersentry-three-vm-provisioning.txt'
    $report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    @(
        'LayerSentry three-VM Hyper-V provisioning'
        "Collected UTC: $($report.CollectedAtUtc)"
        "Host: $env:COMPUTERNAME"
        "ISO: $IsoPath"
        "ISO SHA-256: $ActualSha256"
        "Created VMs: $($CreatedNames -join ', ')"
        "Reused expected VMs: $($ExistingExpectedNames -join ', ')"
        "All VMs running: $allRunning"
        "Free RAM before and after: $FreeMemoryBeforeGiB / $FreeMemoryAfterGiB GiB"
        "Free C drive before and after: $FreeStorageBeforeGiB / $FreeStorageAfterGiB GiB"
        "Fatal error: $FatalError"
        "Start failures: $($StartFailures -join '; ')"
        ''
        ($vmEvidence | Select-Object Name, Exists, State, Generation, VCPU, StartupMemoryGiB, DynamicMemoryEnabled, ExposeVirtualizationExtensions, SecureBoot, PlannedNodeAddress |
            Format-Table -AutoSize | Out-String -Width 300)
        'The VMs boot the verified candidate ISO. Installation is not yet confirmed.'
        'Production approval remains false.'
    ) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    $hashLines = foreach ($file in @(Get-ChildItem -LiteralPath $EvidenceDirectory -File)) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        "$($hash.Hash.ToLowerInvariant())  $($file.Name)"
    }
    $hashLines | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'SHA256SUMS.txt') -Encoding ASCII
    Get-Content -LiteralPath $summaryPath
}

if ($null -ne $FatalError) {
    throw $FatalError
}
if ($StartFailures.Count -gt 0) {
    throw "One or more VMs failed to start: $($StartFailures -join '; ')"
}
if (-not $allRunning) {
    throw 'Not all three VMs are Running.'
}

Write-Host 'LAYERSENTRY THREE-VM PROVISIONING: PASS'
