[CmdletBinding()]
param(
  [string]$VmName='LS-SINGLEOS-R9-2G',
  [string]$VmRoot='C:\ProgramData\LayerSentry\hyperv\single-os-2gb',
  [string]$EvidenceRoot='C:\ProgramData\LayerSentry\evidence\single-os-2gb',
  [string]$RockyIso='C:\LayerSentry\iso\Rocky-9.8-x86_64-minimal.iso',
  [string]$CloudStackCommit='edca51d6d2b144da1bbb571e7bf63665df046de4'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

$Cpu=2; $Ram=2GB; $OsDiskSize=32GB; $SeedSize=64MB; $GuestUser='layersentry'
$IsoUrl='https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.8-x86_64-minimal.iso'
$ChecksumUrl="$IsoUrl.CHECKSUM"
$HardeningUrl="https://raw.githubusercontent.com/adaptgurus/cloudstack/$CloudStackCommit/tools/layersentry/single-os/rocky9-hardening"

function Assert-Admin {
  $p=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator token required'}
}
function Save-Json($o,$p){$o|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $p -Encoding UTF8}
function Select-Switch {
  foreach($n in @('ExternalNAT','Default Switch')){$s=Get-VMSwitch -Name $n -ErrorAction SilentlyContinue;if($s){return $s}}
  $s=Get-VMSwitch|Where-Object SwitchType -eq External|Select-Object -First 1
  if($s){return $s}; throw 'No usable Hyper-V switch found'
}
function Guest-IPv4($name){
  foreach($a in @((Get-VMNetworkAdapter -VMName $name).IPAddresses)){
    $ip=$null
    if([Net.IPAddress]::TryParse([string]$a,[ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and -not $a.StartsWith('169.254.') -and $a -ne '127.0.0.1'){return [string]$a}
  }
  return $null
}
function Run-Ssh($ip,$key,$cmd,[bool]$allow=$false){
  $args=@('-i',$key,'-o','BatchMode=yes','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','ConnectTimeout=8',"$GuestUser@$ip",$cmd)
  $out=& ssh.exe @args 2>&1; $code=$LASTEXITCODE
  if(-not $allow -and $code -ne 0){throw "ssh exit=$code cmd=$cmd output=$($out -join ' ')"}
  [pscustomobject]@{Code=$code;Output=@($out)}
}
function Wait-Ssh($name,$key,[int]$seconds){
  $end=(Get-Date).AddSeconds($seconds)
  while((Get-Date)-lt $end){
    if((Get-VM -Name $name).State -eq 'Running'){
      $ip=Guest-IPv4 $name
      if($ip){$r=Run-Ssh $ip $key 'true' $true;if($r.Code -eq 0){return $ip}}
    }
    Start-Sleep 15
  }
  throw 'Guest SSH did not become ready'
}
function Runner-SourceIp($guest){
  $c=New-Object Net.Sockets.TcpClient
  try{$c.Connect($guest,22);return $c.Client.LocalEndPoint.Address.ToString()}finally{$c.Dispose()}
}
function Vm-State($name){
  $v=Get-VM -Name $name; $m=Get-VMMemory -VMName $name; $p=Get-VMProcessor -VMName $name; $f=Get-VMFirmware -VMName $name
  [pscustomobject]@{Name=$v.Name;Generation=$v.Generation;State=[string]$v.State;Cpu=$p.Count;StartupMemoryBytes=[int64]$m.Startup;DynamicMemory=[bool]$m.DynamicMemoryEnabled;SecureBoot=[string]$f.SecureBoot;IPv4=Guest-IPv4 $name;Switch=@((Get-VMNetworkAdapter -VMName $name).SwitchName);Disks=@((Get-VMHardDiskDrive -VMName $name).Path)}
}
function Ensure-Iso($path){
  New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent)|Out-Null
  $text=(Invoke-WebRequest -UseBasicParsing -Uri $ChecksumUrl).Content
  $m=[regex]::Match($text,'(?i)\b[0-9a-f]{64}\b'); if(-not $m.Success){throw 'Cannot parse Rocky checksum'}
  if(-not(Test-Path $path)){
    if(Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue){Start-BitsTransfer -Source $IsoUrl -Destination $path}else{Invoke-WebRequest -UseBasicParsing -Uri $IsoUrl -OutFile $path}
  }
  $sha=(Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant(); if($sha -ne $m.Value.ToLowerInvariant()){throw 'Rocky ISO checksum mismatch'}
  [pscustomobject]@{Path=$path;Sha256=$sha;Source=$IsoUrl}
}
function New-OemDrv($path,$ks){
  if(Test-Path $path){throw "Refusing orphaned seed overwrite: $path"}
  New-VHD -Path $path -Dynamic -SizeBytes $SeedSize|Out-Null
  $mounted=$null
  try{
    $mounted=Mount-VHD -Path $path -PassThru; $d=$mounted|Get-Disk
    Initialize-Disk -Number $d.Number -PartitionStyle MBR|Out-Null
    $part=New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter
    $vol=Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel OEMDRV -Confirm:$false
    $ks|Set-Content -LiteralPath "$($vol.DriveLetter):\ks.cfg" -Encoding ASCII
  }finally{if($mounted){Dismount-VHD -Path $path -ErrorAction SilentlyContinue}}
}

Assert-Admin; Import-Module Hyper-V -ErrorAction Stop
if((Get-Service vmms).Status -ne 'Running'){throw 'VMMS not running'}
foreach($c in @('ssh.exe','scp.exe','ssh-keygen.exe')){if(-not(Get-Command $c -ErrorAction SilentlyContinue)){throw "$c missing"}}

$stamp=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$eDir=Join-Path $EvidenceRoot $stamp; $tmp=Join-Path $env:RUNNER_TEMP "ls-singleos-$stamp"
New-Item -ItemType Directory -Force -Path $eDir,$tmp,$VmRoot|Out-Null
$ev=[ordered]@{Status='STARTED';StartedAt=(Get-Date).ToUniversalTime().ToString('o');Workstream='VM-native Single-OS DBaaS/APaaS';ArchitectureIsolation='separate-from-RKE2-CAPI';VmCreateLimit=1;RequiredCpu=2;RequiredMemoryBytes=[int64]$Ram;RequiredDynamicMemory=$false;CloudStackHardeningCommit=$CloudStackCommit;VmName=$VmName;Runner=$env:RUNNER_NAME;Host=$env:COMPUTERNAME}
try{
  $existing=Get-VM -Name $VmName -ErrorAction SilentlyContinue
  if($existing){
    $s=Vm-State $VmName
    if($s.Generation-ne 2 -or $s.Cpu-ne 2 -or $s.StartupMemoryBytes-ne $Ram -or $s.DynamicMemory){throw 'Existing acceptance VM has wrong resources; refusing replacement or second VM'}
    throw 'Exact acceptance VM already exists. Credentials are intentionally not persisted; refusing to create or invent a second VM.'
  }

  $sw=Select-Switch; $ev.Switch=$sw.Name; $iso=Ensure-Iso $RockyIso; $ev.RockyIso=$iso
  $key=Join-Path $tmp 'id_ed25519'; & ssh-keygen.exe -q -t ed25519 -N '""' -f $key
  if($LASTEXITCODE-ne 0){throw 'ssh-keygen failed'}
  $parts=((Get-Content -Raw "$key.pub").Trim()-split '\s+'); $pub="$($parts[0]) $($parts[1])"
  $ev.SshFingerprint=(& ssh-keygen.exe -lf "$key.pub")-join ' '

  $ks=@"
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
sshkey --username=$GuestUser $pub
services --enabled="sshd,firewalld,auditd,chronyd"
ignoredisk --only-use=sda
zerombr
clearpart --all --initlabel --disklabel=gpt --drives=sda
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
  $os=Join-Path $VmRoot "$VmName-os.vhdx"; $seed=Join-Path $VmRoot "$VmName-oemdrv.vhdx"
  if(Test-Path $os){throw "Orphaned OS disk exists: $os"}; New-OemDrv $seed $ks
  New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $Ram -NewVHDPath $os -NewVHDSizeBytes $OsDiskSize -SwitchName $sw.Name|Out-Null
  Set-VMProcessor -VMName $VmName -Count $Cpu; Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $Ram
  Set-VM -VMName $VmName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
  Add-VMHardDiskDrive -VMName $VmName -ControllerType SCSI -Path $seed|Out-Null
  $dvd=Add-VMDvdDrive -VMName $VmName -Path $iso.Path -Passthru
  Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice $dvd
  $pre=Vm-State $VmName; if($pre.Generation-ne 2 -or $pre.Cpu-ne 2 -or $pre.StartupMemoryBytes-ne $Ram -or $pre.DynamicMemory){throw 'Preboot resource guard failed'}
  $ev.CreatedThisRun=$true; $ev.PreBootVm=$pre
  Start-VM $VmName|Out-Null; Start-Sleep 45
  $boot=Get-VMHardDiskDrive -VMName $VmName|Where-Object Path -eq $os|Select-Object -First 1; Set-VMFirmware -VMName $VmName -FirstBootDevice $boot

  $ip=Wait-Ssh $VmName $key 1800; $ev.GuestIp=$ip
  $src=Runner-SourceIp $ip; $cidr="$src/32"; $ev.ManagementCidr=$cidr
  $hard=Join-Path $tmp 'rocky9-hardening'; Invoke-WebRequest -UseBasicParsing -Uri $HardeningUrl -OutFile $hard
  $ev.HardeningSha256=(Get-FileHash -Algorithm SHA256 $hard).Hash.ToLowerInvariant()
  & scp.exe -i $key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $hard "$GuestUser@$ip`:/tmp/rocky9-hardening"; if($LASTEXITCODE-ne 0){throw 'scp hardening failed'}
  $r=Run-Ssh $ip $key "sudo install -o root -g root -m 0750 /tmp/rocky9-hardening /usr/local/sbin/layersentry-single-os-hardening && sudo /usr/local/sbin/layersentry-single-os-hardening apply --management-cidr '$cidr' --allow-lab-sudo-user '$GuestUser'"; $r.Output|Set-Content "$eDir\hardening-apply.txt"
  $r=Run-Ssh $ip $key "sudo /usr/local/sbin/layersentry-single-os-hardening verify --management-cidr '$cidr' --allow-lab-sudo-user '$GuestUser'"; $r.Output|Set-Content "$eDir\hardening-verify-before-reboot.txt"
  $audit="cat /etc/os-release; echo ===SELINUX===; getenforce; echo ===FIREWALL===; sudo firewall-cmd --get-default-zone; sudo firewall-cmd --zone=layersentry-management --list-all; echo ===LISTENERS===; sudo ss -lntup; echo ===MEMORY===; free -m; echo ===DISK===; df -hT; echo ===FAILED===; systemctl --failed --no-pager || true; echo ===AVC===; sudo ausearch -m AVC,USER_AVC -ts boot 2>/dev/null || true"
  (Run-Ssh $ip $key $audit).Output|Set-Content "$eDir\guest-audit-before-reboot.txt"
  $ev.BeforeRebootVm=Vm-State $VmName
  Run-Ssh $ip $key 'sudo systemctl reboot' $true|Out-Null; Start-Sleep 20
  $ip2=Wait-Ssh $VmName $key 600; $ev.GuestIpAfterReboot=$ip2
  (Run-Ssh $ip2 $key "sudo /usr/local/sbin/layersentry-single-os-hardening verify --management-cidr '$cidr' --allow-lab-sudo-user '$GuestUser'").Output|Set-Content "$eDir\hardening-verify-after-reboot.txt"
  (Run-Ssh $ip2 $key $audit).Output|Set-Content "$eDir\guest-audit-after-reboot.txt"
  $post=Vm-State $VmName; if($post.Cpu-ne 2 -or $post.StartupMemoryBytes-ne $Ram -or $post.DynamicMemory){throw 'Post-reboot resource guard failed'}; $ev.AfterRebootVm=$post
  $ev.Status='LIVE_VERIFIED_BASE_OS_HARDENING';$ev.EngineStatus='PENDING_NOT_IMPLEMENTED';$ev.ClusterHaStatus='NOT_TESTED_ONE_VM_RESTRICTION';$ev.LabOnlySudoException=$true;$ev.ProductionCertified=$false;$ev.CompletedAt=(Get-Date).ToUniversalTime().ToString('o');Save-Json $ev "$eDir\summary.json"
  Write-Host "SUCCESS evidence=$eDir"
}catch{$ev.Status='FAILED_OR_BLOCKED';$ev.Error=$_.Exception.Message;$ev.CompletedAt=(Get-Date).ToUniversalTime().ToString('o');Save-Json $ev "$eDir\summary.json";throw}
finally{Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue}
