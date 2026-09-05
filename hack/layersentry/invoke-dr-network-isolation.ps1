[CmdletBinding()]param([Parameter(Mandatory)][string]$RequestPath,[ValidateSet('Preflight','Apply','Rollback')][string]$Phase='Preflight',[string]$Authorization='',[Parameter(Mandatory)][string]$EvidenceDirectory)
Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DrNetworkIsolation.psm1') -Force; Import-Module Hyper-V -ErrorAction Stop
$request=Get-Content -LiteralPath $RequestPath -Raw|ConvertFrom-Json; Assert-DrNetworkRequest $request
if($Phase -ne 'Preflight' -and $Authorization -cne "$($request.requestId):$Phase"){throw 'Explicit phase authorization required.'}
$hash=(Get-FileHash -LiteralPath $RequestPath -Algorithm SHA256).Hash
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'An administrator runner is required.'}
$root=Join-Path $env:ProgramData 'LayerSentry\dr-network-isolation';New-Item -ItemType Directory -Path $root -Force|Out-Null
$acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))};Set-Acl $root $acl
$lock=[IO.File]::Open((Join-Path $root 'host.lock'),'OpenOrCreate','ReadWrite','None');$journalPath=Join-Path $root "$($request.requestId).json"
$report=[ordered]@{status='PENDING';phase=$Phase;requestId=$request.requestId;requestSha256=$hash;sourceCommit=$env:GITHUB_SHA;mutationAttempted=$false;guestConfiguration='PENDING';errorType=$null}
function Save-Journal{$tmp="$journalPath.$([guid]::NewGuid().ToString('N')).tmp";[IO.File]::WriteAllText($tmp,($script:journal|ConvertTo-Json -Depth 8));if(Test-Path $journalPath){$bak="$journalPath.bak";[IO.File]::Replace($tmp,$journalPath,$bak,$true);[IO.File]::Delete($bak)}else{[IO.File]::Move($tmp,$journalPath)}}
try{
 $journal=if(Test-Path $journalPath){Get-Content $journalPath -Raw|ConvertFrom-Json}else{$null}
 if($journal -and ($journal.requestSha256 -cne $hash -or $journal.host -ine $env:COMPUTERNAME)){throw 'Journal/request mismatch.'}
 if($Phase -eq 'Preflight'){
  if($journal){throw 'Request already journaled.'};$p=Get-DrNetworkPreflight $request $hash
  $journal=[pscustomobject]@{requestSha256=$hash;host=$env:COMPUTERNAME;phase='ReadyToApply';vmId=$p.vmId;nicId=$p.nicId;originalSwitchId=$p.originalSwitchId;createdSwitchId='';createdAddress=$false;createdUtc=[DateTime]::UtcNow.ToString('o')};Save-Journal;$report.preflight=$p;$report.status='DESIGN_DEFINED'
 }elseif($Phase -eq 'Apply'){
  if(-not $journal -or $journal.phase -notin @('ReadyToApply','ApplyStarted','Applied')){throw 'Apply requires preflight journal.'};$owned=Get-OwnedDrVm $request
  if([string]$owned.VM.State -ne 'Off'){throw 'DR VM must be off before network reconnection.'}
  $journal.phase='ApplyStarted';Save-Journal;$report.mutationAttempted=$true
  $switch=@(Get-VMSwitch -Name $request.switchName -ErrorAction SilentlyContinue)
  if(-not $switch){$switch=New-VMSwitch -Name $request.switchName -SwitchType Internal -Notes "LayerSentry DR network $hash";$journal.createdSwitchId=[string]$switch.Id;Save-Journal}else{$switch=$switch[0];if([string]$switch.Notes -cne "LayerSentry DR network $hash"){throw 'Target switch ownership mismatch.'};if(-not $journal.createdSwitchId){$journal.createdSwitchId=[string]$switch.Id;Save-Journal}}
  if([string]$switch.SwitchType -cne 'Internal'){throw 'Target switch drifted.'}
  $alias="vEthernet ($($request.switchName))";$address=@(Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object IPAddress -eq $request.gateway)
  if(-not $address){New-NetIPAddress -InterfaceAlias $alias -IPAddress $request.gateway -PrefixLength 24|Out-Null;$journal.createdAddress=$true;Save-Journal}elseif($journal.createdSwitchId -and -not $journal.createdAddress){$journal.createdAddress=$true;Save-Journal}
  $owned.NIC|Connect-VMNetworkAdapter -VMSwitch $switch;$owned.NIC|Set-VMNetworkAdapter -MacAddressSpoofing On
  $p=Get-DrNetworkPreflight $request $hash;if($p.state -cne 'Applied'){throw 'Post-apply verification failed.'};$journal.phase='Applied';Save-Journal;$report.verification=$p;$report.status='PARTIAL'
 }else{
  if(-not $journal -or $journal.phase -notin @('ApplyStarted','Applied','RollbackStarted')){throw 'Rollback requires an applied journal.'};$owned=Get-OwnedDrVm $request
  if([string]$owned.VM.State -ne 'Off'){throw 'DR VM must be off before rollback.'};$journal.phase='RollbackStarted';Save-Journal;$report.mutationAttempted=$true
  $original=Get-VMSwitch -Id ([guid]$journal.originalSwitchId) -ErrorAction Stop;$owned.NIC|Connect-VMNetworkAdapter -VMSwitch $original
  if($journal.createdAddress){Get-NetIPAddress -InterfaceAlias "vEthernet ($($request.switchName))" -IPAddress $request.gateway -AddressFamily IPv4 -ErrorAction Stop|Remove-NetIPAddress -Confirm:$false}
  if($journal.createdSwitchId){$s=Get-VMSwitch -Id ([guid]$journal.createdSwitchId);if(@(Get-VMNetworkAdapter -All|Where-Object SwitchId -eq $s.Id).Count){throw 'Owned switch still has attached VM adapters.'};Remove-VMSwitch -VMSwitch $s -Force}
  $journal.phase='RolledBack';Save-Journal;$report.status='PARTIAL'
 }
}catch{$report.status='BLOCKED';$report.errorType=$_.Exception.GetType().FullName;throw}finally{$lock.Dispose();if(Test-Path $EvidenceDirectory){throw 'Evidence directory must be unique.'};New-Item -ItemType Directory $EvidenceDirectory|Out-Null;$report|ConvertTo-Json -Depth 10|Set-Content (Join-Path $EvidenceDirectory 'result.json') -Encoding UTF8}
