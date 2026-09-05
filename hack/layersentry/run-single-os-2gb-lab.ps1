[CmdletBinding()]
param(
    [string]$VmName = 'LS-SINGLEOS-R9-2G',
    [string]$VmRoot = 'C:\ProgramData\LayerSentry\hyperv\single-os-2gb',
    [string]$EvidenceRoot = 'C:\ProgramData\LayerSentry\evidence\single-os-2gb',
    [string]$PreferredSwitch = 'ExternalNAT',
    [string]$RockyIso = 'C:\LayerSentry\iso\Rocky-9.8-x86_64-minimal.iso',
    [string]$CloudStackCommit = 'edca51d6d2b144da1bbb571e7bf63665df046de4'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$CpuCount = 2
$MemoryBytes = 2GB
$DiskBytes = 32GB
$SeedBytes = 64MB
$GuestUser = 'layersentry'
$RockyIsoUrl = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.8-x86_64-minimal.iso'
$RockyChecksumUrl = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.8-x86_64-minimal.iso.CHECKSUM'
$HardeningUrl = "https://raw.githubusercontent.com/adaptgurus/cloudstack/$CloudStackCommit/tools/layersentry/single-os/rocky9-hardening"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Hyper-V lab runner requires an elevated Administrator token.'
    }
}

function Write-JsonEvidence {
    param([Parameter(Mandatory=$true)]$Object, [Parameter(Mandatory=$true)][string]$Path)
    $Object | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-UsableSwitch {
    param([string]$Preferred)
    $preferredObj = Get-VMSwitch -Name $Preferred -ErrorAction SilentlyContinue
    if ($preferredObj) { return $preferredObj }
    $default = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($default) { return $default }
    $external = Get-VMSwitch | Where-Object SwitchType -eq 'External' | Select-Object -First 1
    if ($external) { return $external }
    throw 'No usable Hyper-V switch found. Expected ExternalNAT, Default Switch, or another External switch.'
}

function Get-GuestIPv4 {
    param([string]$Name)
    $addresses = @(Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop | Select-Object -ExpandProperty IPAddresses)
    foreach ($address in $addresses) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse([string]$address, [ref]$parsed) -and
            $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            -not $address.StartsWith('169.254.') -and $address -ne '127.0.0.1') {
            return [string]$address
        }
    }
    return $null
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory=$true)][string]$Ip,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Command,
        [switch]$AllowFailure
    )
    $args = @(
        '-i', $Key,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'ConnectTimeout=8',
        "$GuestUser@$Ip",
        $Command
    )
    $output = & ssh.exe @args 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "SSH command failed exit=$exitCode command=$Command output=$($output -join ' ')"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Wait-SshReady {
    param([string]$Name, [string]$Key, [int]$TimeoutSeconds = 1800)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = (Get-VM -Name $Name -ErrorAction Stop).State
        if ($state -eq 'Running') {
            $ip = Get-GuestIPv4 -Name $Name
            if ($ip) {
                $probe = Invoke-Ssh -Ip $ip -Key $Key -Command 'true' -AllowFailure
                if ($probe.ExitCode -eq 0) { return $ip }
            }
        }
        Start-Sleep -Seconds 15
    }
    throw "Guest SSH did not become ready within the acceptance window for VM $Name."
}

function Get-RunnerSourceIp {
    param([string]$GuestIp)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $client.Connect($GuestIp, 22)
        return $client.Client.LocalEndPoint.Address.ToString()
    }
    finally {
        $client.Dispose()
    }
}

function Ensure-RockyIso {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null

    $checksumText = (Invoke-WebRequest -UseBasicParsing -Uri $RockyChecksumUrl).Content
    $matches = [regex]::Matches($checksumText, '(?i)\b[0-9a-f]{64}\b')
    if ($matches.Count -lt 1) { throw 'Could not parse Rocky Linux official SHA256 checksum.' }
    $expected = $matches[0].Value.ToLowerInvariant()

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Rocky ISO not found locally; downloading official pinned Rocky 9.8 minimal ISO."
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $RockyIsoUrl -Destination $Path
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri $RockyIsoUrl -OutFile $Path
        }
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Rocky ISO checksum mismatch expected=$expected actual=$actual"
    }
    return [pscustomobject]@{ Path = $Path; Sha256 = $actual; Source = $RockyIsoUrl }
}

function New-OemDrvSeed {
    param([string]$Path, [string]$Kickstart)
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite existing OEMDRV seed: $Path" }
    New-VHD -Path $Path -Dynamic -SizeBytes $SeedBytes | Out-Null
    $mounted = $null
    try {
        $mounted = Mount-VHD -Path $Path -PassThru
        $disk = $mounted | Get-Disk
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR -PassThru | Out-Null
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        $volume = Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel 'OEMDRV' -Confirm:$false
        $ksPath = "$($volume.DriveLetter):\ks.cfg"
        $Kickstart | Set-Content -LiteralPath $ksPath -Encoding ASCII
        if (-not (Test-Path -LiteralPath $ksPath)) { throw 'Failed to write ks.cfg to OEMDRV.' }
    }
    finally {
        if ($mounted) { Dismount-VHD -Path $Path -ErrorAction SilentlyContinue }
    }
}

function Get-VmAcceptanceState {
    param([string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $memory = Get-VMMemory -VMName $Name -ErrorAction Stop
    $processor = Get-VMProcessor -VMName $Name -ErrorAction Stop
    $firmware = Get-VMFirmware -VMName $Name -ErrorAction Stop
    [pscustomobject]@{
        Name = $vm.Name
        Generation = $vm.Generation
        State = [string]$vm.State
        ProcessorCount = $processor.Count
        StartupMemoryBytes = [int64]$memory.Startup
        DynamicMemoryEnabled = [bool]$memory.DynamicMemoryEnabled
        SecureBoot = [string]$firmware.SecureBoot
        Switches = @((Get-VMNetworkAdapter -VMName $Name).SwitchName)
        DiskPaths = @((Get-VMHardDiskDrive -VMName $Name).Path)
        DvdPaths = @((Get-VMDvdDrive -VMName $Name).Path)
        IPv4 = Get-GuestIPv4 -Name $Name
    }
}

Assert-Administrator
Import-Module Hyper-V -ErrorAction Stop
if ((Get-Service vmms -ErrorAction Stop).Status -ne 'Running') { throw 'Hyper-V VMMS service is not running.' }
foreach ($command in 'ssh.exe','scp.exe','ssh-keygen.exe') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required Windows OpenSSH command is missing: $command" }
}

$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidenceDir = Join-Path $EvidenceRoot $runId
$tempDir = Join-Path $env:RUNNER_TEMP "layersentry-single-os-$runId"
New-Item -ItemType Directory -Force -Path $evidenceDir, $tempDir, $VmRoot | Out-Null

$evidence = [ordered]@{
    Status = 'STARTED'
    StartedAt = (Get-Date).ToUniversalTime().ToString('o')
    Workstream = 'LayerSentry VM-native Single-OS DBaaS/APaaS'
    ArchitectureIsolation = 'separate-from-RKE2-CAPI-DBaaS-APaaS'
    CloudStackHardeningCommit = $CloudStackCommit
    VmLimit = 1
    RequiredCpu = $CpuCount
    RequiredMemoryBytes = [int64]$MemoryBytes
    RequiredDynamicMemory = $false
    VmName = $VmName
    Host = $env:COMPUTERNAME
    Runner = $env:RUNNER_NAME
}

try {
    $switch = Get-UsableSwitch -Preferred $PreferredSwitch
    $evidence.Switch = $switch.Name

    $iso = Ensure-RockyIso -Path $RockyIso
    $evidence.RockyIso = $iso

    $existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($existing) {
        $current = Get-VmAcceptanceState -Name $VmName
        if ($current.Generation -ne 2 -or $current.ProcessorCount -ne 2 -or
            $current.StartupMemoryBytes -ne $MemoryBytes -or $current.DynamicMemoryEnabled) {
            throw 'An existing VM with the acceptance name does not match the exact 2-vCPU/2-GB/static-memory envelope. Refusing to mutate or replace it.'
        }
        $evidence.CreatedThisRun = $false
    }
    else {
        $keyPath = Join-Path $tempDir 'id_ed25519'
        & ssh-keygen.exe -q -t ed25519 -N '""' -f $keyPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$keyPath.pub")) { throw 'Failed to generate ephemeral SSH key.' }
        $publicParts = ((Get-Content -Raw -LiteralPath "$keyPath.pub").Trim() -split '\s+')
        if ($publicParts.Count -lt 2) { throw 'Generated SSH public key is invalid.' }
        $publicKey = "$($publicParts[0]) $($publicParts[1])"
        $evidence.EphemeralSshKeyFingerprint = (& ssh-keygen.exe -lf "$keyPath.pub" 2>$null) -join ' '

        $kickstart = @"
text
cdrom
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate --onboot=on --hostname=layersentry-singleos-r9
selinux --enforcing
firewall --enabled --service=ssh
firstboot --disable
rootpw --lock
user --name=$GuestUser --groups=wheel --lock
sshkey --username=$GuestUser $publicKey
services --enabled="sshd,firewalld,auditd,chronyd"
zerombr
clearpart --all --initlabel --disklabel=gpt
autopart --type=lvm
bootloader --timeout=1
reboot --eject

%packages --excludedocs
@^minimal-environment
sudo
openssh-server
firewalld
audit
policycoreutils
chrony
python3
%end

%post --erroronfail
install -d -m 0750 /etc/sudoers.d
printf '%s\n' '$GuestUser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-layersentry-disposable-lab
chmod 0440 /etc/sudoers.d/90-layersentry-disposable-lab
restorecon -RF /etc/sudoers.d /home/$GuestUser/.ssh || true
printf '%s\n' 'LayerSentry disposable one-VM acceptance image' > /etc/layersentry-single-os-lab
%end
"@

        $osDisk = Join-Path $VmRoot "$VmName-os.vhdx"
        $seedDisk = Join-Path $VmRoot "$VmName-oemdrv.vhdx"
        if (Test-Path $osDisk) { throw "Refusing to overwrite orphaned OS disk: $osDisk" }
        if (Test-Path $seedDisk) { throw "Refusing to overwrite orphaned seed disk: $seedDisk" }
        New-OemDrvSeed -Path $seedDisk -Kickstart $kickstart

        $vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $MemoryBytes -NewVHDPath $osDisk -NewVHDSizeBytes $DiskBytes -SwitchName $switch.Name
        Set-VMProcessor -VMName $VmName -Count $CpuCount
        Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $MemoryBytes
        Set-VM -VMName $VmName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
        Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $seedDisk | Out-Null
        $dvd = Add-VMDvdDrive -VMName $VmName -Path $iso.Path -Passthru
        Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' -FirstBootDevice $dvd

        $preStart = Get-VmAcceptanceState -Name $VmName
        if ($preStart.Generation -ne 2 -or $preStart.ProcessorCount -ne 2 -or
            $preStart.StartupMemoryBytes -ne $MemoryBytes -or $preStart.DynamicMemoryEnabled) {
            throw 'VM configuration failed the exact resource guard before first boot.'
        }
        $evidence.CreatedThisRun = $true
        $evidence.PreStartVm = $preStart
        Start-VM -Name $VmName | Out-Null

        # Future boots must prefer the installed OS disk, preventing an ISO reinstall loop.
        Start-Sleep -Seconds 45
        $bootDisk = Get-VMHardDiskDrive -VMName $VmName | Where-Object Path -eq $osDisk | Select-Object -First 1
        if (-not $bootDisk) { throw 'Could not identify the OS disk for firmware boot order.' }
        Set-VMFirmware -VMName $VmName -FirstBootDevice $bootDisk
    }

    # If reusing an exact pre-existing VM, generate a fresh ephemeral key only if one
    # exists from this run; otherwise we truthfully stop because no credential is persisted.
    if (-not (Get-Variable keyPath -ErrorAction SilentlyContinue)) {
        throw 'Exact acceptance VM already existed but no reusable credential is persisted by design. Refusing to invent credentials or create another VM.'
    }

    $guestIp = Wait-SshReady -Name $VmName -Key $keyPath
    $evidence.GuestIpInitial = $guestIp
    $runnerSource = Get-RunnerSourceIp -GuestIp $guestIp
    if (-not $runnerSource) { throw 'Could not determine runner source IP for management allowlist.' }
    $managementCidr = "$runnerSource/32"
    $evidence.ManagementCidr = $managementCidr

    $hardeningLocal = Join-Path $tempDir 'rocky9-hardening'
    Invoke-WebRequest -UseBasicParsing -Uri $HardeningUrl -OutFile $hardeningLocal
    $evidence.HardeningSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $hardeningLocal).Hash.ToLowerInvariant()

    & scp.exe -i $keyPath -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $hardeningLocal "$GuestUser@$guestIp`:/tmp/rocky9-hardening"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to copy hardening implementation into the guest.' }

    $apply = Invoke-Ssh -Ip $guestIp -Key $keyPath -Command "sudo install -o root -g root -m 0750 /tmp/rocky9-hardening /usr/local/sbin/layersentry-single-os-hardening && sudo /usr/local/sbin/layersentry-single-os-hardening apply --management-cidr '$managementCidr' --allow-lab-sudo-user '$GuestUser'"
    $apply.Output | Set-Content -LiteralPath (Join-Path $evidenceDir 'hardening-apply.txt') -Encoding UTF8

    $verify = Invoke-Ssh -Ip $guestIp -Key $keyPath -Command "sudo /usr/local/sbin/layersentry-single-os-hardening verify --management-cidr '$managementCidr' --allow-lab-sudo-user '$GuestUser'"
    $verify.Output | Set-Content -LiteralPath (Join-Path $evidenceDir 'hardening-verify-before-reboot.txt') -Encoding UTF8

    $guestAuditCommand = @'
set -eu
printf '%s\n' '=== os-release ==='
cat /etc/os-release
printf '%s\n' '=== selinux ==='
getenforce
printf '%s\n' '=== firewalld ==='
sudo firewall-cmd --state
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --zone=layersentry-management --list-all
printf '%s\n' '=== listeners ==='
sudo ss -lntup
printf '%s\n' '=== memory ==='
free -m
printf '%s\n' '=== disk ==='
df -hT
printf '%s\n' '=== failed-units ==='
systemctl --failed --no-pager || true
printf '%s\n' '=== avc-denials ==='
sudo ausearch -m AVC,USER_AVC -ts boot 2>/dev/null || true
'@
    $guestAudit = Invoke-Ssh -Ip $guestIp -Key $keyPath -Command $guestAuditCommand
    $guestAudit.Output | Set-Content -LiteralPath (Join-Path $evidenceDir 'guest-audit-before-reboot.txt') -Encoding UTF8

    $beforeReboot = Get-VmAcceptanceState -Name $VmName
    $evidence.BeforeRebootVm = $beforeReboot
    if ($beforeReboot.ProcessorCount -ne 2 -or $beforeReboot.StartupMemoryBytes -ne $MemoryBytes -or $beforeReboot.DynamicMemoryEnabled) {
        throw 'Runtime VM resource assertion failed before reboot.'
    }

    Invoke-Ssh -Ip $guestIp -Key $keyPath -Command 'sudo systemctl reboot' -AllowFailure | Out-Null
    Start-Sleep -Seconds 20
    $guestIpAfter = Wait-SshReady -Name $VmName -Key $keyPath -TimeoutSeconds 600
    $evidence.GuestIpAfterReboot = $guestIpAfter

    $verifyAfter = Invoke-Ssh -Ip $guestIpAfter -Key $keyPath -Command "sudo /usr/local/sbin/layersentry-single-os-hardening verify --management-cidr '$managementCidr' --allow-lab-sudo-user '$GuestUser'"
    $verifyAfter.Output | Set-Content -LiteralPath (Join-Path $evidenceDir 'hardening-verify-after-reboot.txt') -Encoding UTF8

    $afterReboot = Get-VmAcceptanceState -Name $VmName
    $evidence.AfterRebootVm = $afterReboot
    if ($afterReboot.ProcessorCount -ne 2 -or $afterReboot.StartupMemoryBytes -ne $MemoryBytes -or $afterReboot.DynamicMemoryEnabled) {
        throw 'Runtime VM resource assertion failed after reboot.'
    }

    $finalAudit = Invoke-Ssh -Ip $guestIpAfter -Key $keyPath -Command $guestAuditCommand
    $finalAudit.Output | Set-Content -LiteralPath (Join-Path $evidenceDir 'guest-audit-after-reboot.txt') -Encoding UTF8

    $evidence.Status = 'LIVE_VERIFIED_BASE_OS_HARDENING'
    $evidence.EngineStatus = 'PENDING_NOT_IMPLEMENTED'
    $evidence.ClusterHaStatus = 'NOT_TESTED_ONE_VM_RESTRICTION'
    $evidence.LabOnlySudoException = $true
    $evidence.ProductionCertified = $false
    $evidence.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonEvidence -Object $evidence -Path (Join-Path $evidenceDir 'summary.json')
    Write-Host "LayerSentry one-VM Rocky 9 hardening acceptance succeeded. Evidence: $evidenceDir"
}
catch {
    $evidence.Status = 'FAILED_OR_BLOCKED'
    $evidence.Error = $_.Exception.Message
    $evidence.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonEvidence -Object $evidence -Path (Join-Path $evidenceDir 'summary.json')
    throw
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
