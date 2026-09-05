Set-StrictMode -Version Latest;$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DrNetworkIsolation.psm1') -Force
function Assert-Throws([scriptblock]$Body){$threw=$false;try{&$Body}catch{$threw=$true};if(-not $threw){throw 'Expected rejection.'}}
$valid=[pscustomobject]@{requestId='20260905-dr-network-v1';host='TESTSER';vmId='00000000-0000-0000-0000-000000000001';vmName='layersentry-dr-rocky9';nicId='00000000-0000-0000-0000-000000000002';currentSwitchId='00000000-0000-0000-0000-000000000003';ownerRequestSha256=('a'*64);switchName='LayerSentry-DR-Internal';subnet='10.10.20.0/24';gateway='10.10.20.1'}
Assert-DrNetworkRequest $valid
if(-not (Test-CidrOverlap '10.10.20.128/25' '10.10.20.0/24')){throw 'Overlap missed.'}
if(Test-CidrOverlap '10.10.10.0/24' '10.10.20.0/24'){throw 'Disjoint prefixes reported overlapping.'}
$bad=$valid.PSObject.Copy();$bad.subnet='10.10.10.0/24';Assert-Throws {Assert-DrNetworkRequest $bad}
$bad=$valid.PSObject.Copy();$bad|Add-Member unexpected x;Assert-Throws {Assert-DrNetworkRequest $bad}
$module=Get-Content (Join-Path $PSScriptRoot 'DrNetworkIsolation.psm1') -Raw
$invoke=Get-Content (Join-Path $PSScriptRoot 'invoke-dr-network-isolation.ps1') -Raw
foreach($forbidden in @('New-NetNat','Remove-NetNat')){if($module.Contains($forbidden)-or$invoke.Contains($forbidden)){throw "Forbidden WinNAT mutation: $forbidden"}}
foreach($required in @("VM must be off","ownership mismatch","Explicit phase authorization","Remove-VMSwitch")){if(-not ($module.Contains($required)-or$invoke.Contains($required))){throw "Missing guard: $required"}}
'DR network isolation tests passed.'
