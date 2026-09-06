param(
  [ValidateSet('Plan','Apply','Observe')][string]$Mode='Plan',
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
  [string]$RequestId,
  [string]$ReviewedPlanPath,
  [string]$ReviewedPlanSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$private=$null
$exitCode=1
function Set-PrivateDirectory([string]$Directory,[bool]$Create) {
  if($Create) {New-Item -ItemType Directory -Path $Directory -ErrorAction Stop|Out-Null}
  $item=Get-Item -LiteralPath $Directory -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Private directory link rejected.'}
  $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
  $allowed=@($identity.User.Value,'S-1-5-18','S-1-5-32-544')
  if($Create) {
    $acl=Get-Acl -LiteralPath $Directory
    $acl.SetAccessRuleProtection($true,$false)
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity.User,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Directory -AclObject $acl
  }
  $acl=Get-Acl -LiteralPath $Directory
  $owner=New-Object Security.Principal.NTAccount($acl.Owner)
  if($owner.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {throw 'Private owner mismatch.'}
  foreach($access in $acl.Access) {
    if($access.AccessControlType -eq 'Allow' -and $access.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {throw 'Private ACL mismatch.'}
  }
}
try {
  if($env:ROCKY_HOST -cne '10.10.10.14' -or $env:ROCKY_USERNAME -cne 'root') {throw 'Exact DC secret binding required.'}
  foreach($name in @('ROCKY_PASSWORD','DC_KNOWN_HOSTS','CLOUDSTACK_API_KEY','CLOUDSTACK_SECRET_KEY','LAYERSENTRY_CLOUDSTACK_USERNAME')) {
    if([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name))) {throw 'Existing DC credentials unavailable.'}
  }
  if($Mode -eq 'Plan') {
    if([string]::IsNullOrEmpty($RequestId)) {$RequestId=[Guid]::NewGuid().ToString()}
    if($RequestId -cnotmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {throw 'Fixture request ID invalid.'}
  } elseif($ReviewedPlanSha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrEmpty($ReviewedPlanPath)) {throw 'Reviewed exact Plan required.'}
  Set-PrivateDirectory $EvidenceDirectory $true
  $private=Join-Path $env:RUNNER_TEMP ('layersentry-dc-gui-private-'+[Guid]::NewGuid().ToString('N'))
  Set-PrivateDirectory $private $true
  $utf8=New-Object Text.UTF8Encoding($false)
  $known=Join-Path $private 'known_hosts'
  $askpass=Join-Path $private 'askpass.cmd'
  $password=Join-Path $private 'ssh-password.json'
  $credentials=Join-Path $private 'api-credentials.json'
  $binding=Join-Path $private 'binding.json'
  [IO.File]::WriteAllText($known,($env:DC_KNOWN_HOSTS.Trim()+"`n"),$utf8)
  $helper='@echo off'+"`r`n"+'powershell.exe -NoProfile -NonInteractive -Command "[Console]::Write([Environment]::GetEnvironmentVariable(''ROCKY_PASSWORD''))"'+"`r`n"
  [IO.File]::WriteAllText($askpass,$helper,[Text.Encoding]::ASCII)
  [IO.File]::WriteAllText($password,(@{password=$env:ROCKY_PASSWORD}|ConvertTo-Json -Compress),$utf8)
  [IO.File]::WriteAllText($credentials,(@{apiKey=$env:CLOUDSTACK_API_KEY;apiSecret=$env:CLOUDSTACK_SECRET_KEY;username=$env:LAYERSENTRY_CLOUDSTACK_USERNAME}|ConvertTo-Json -Compress),$utf8)
  [IO.File]::WriteAllText($binding,(@{target='dc';host='10.10.10.14';user='root';knownHostsFile=$known;askPassFile=$askpass;passwordFile=$password}|ConvertTo-Json -Compress),$utf8)
  $journal=Join-Path $env:ProgramData 'LayerSentry\gui-fixtures\dc'
  if($Mode -ne 'Plan') {
    $plan=Join-Path $private 'reviewed-plan.json'
    $item=Get-Item -LiteralPath $ReviewedPlanPath -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt 32768) {throw 'Reviewed Plan file invalid.'}
    Copy-Item -LiteralPath $ReviewedPlanPath -Destination $plan
    if((Get-FileHash -LiteralPath $plan -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ReviewedPlanSha256) {throw 'Reviewed Plan hash differs.'}
    if(Test-Path -LiteralPath $journal) {Set-PrivateDirectory $journal $false}
    elseif($Mode -eq 'Apply') {Set-PrivateDirectory $journal $true}
    else {throw 'No durable DC fixture journal exists.'}
    $requestOrPlan=$plan
  } else {$requestOrPlan=$RequestId}
  $hashArgument=if($Mode -eq 'Plan') {'NOT_APPLICABLE'} else {$ReviewedPlanSha256}
  $journalArgument=if($Mode -eq 'Plan') {'NOT_APPLICABLE'} else {$journal}
  # Only the protected files now carry credentials. Browser/other children never inherit them.
  foreach($name in @('ROCKY_PASSWORD','DC_KNOWN_HOSTS','CLOUDSTACK_API_KEY','CLOUDSTACK_SECRET_KEY','LAYERSENTRY_CLOUDSTACK_USERNAME')) {Remove-Item ('Env:'+ $name) -ErrorAction SilentlyContinue}
  $env:LAYERSENTRY_GUI_ACL_VERIFIED='1'
  $env:DEBUG=$null
  $env:PWDEBUG=$null
  # Argument arrays contain only fixed mode/public paths/hash. No remote shell command or nested quoting.
  & node (Join-Path $PSScriptRoot 'dc-fixture.mjs') $Mode $binding $credentials (Join-Path $EvidenceDirectory 'dc-fixture.json') $requestOrPlan $hashArgument $journalArgument
  $exitCode=$LASTEXITCODE
} catch {
  Write-Output 'DC_GUI_FIXTURE_RUNNER_FAILED'
  $exitCode=1
} finally {
  foreach($name in @('ROCKY_PASSWORD','DC_KNOWN_HOSTS','CLOUDSTACK_API_KEY','CLOUDSTACK_SECRET_KEY','LAYERSENTRY_CLOUDSTACK_USERNAME','LAYERSENTRY_GUI_ACL_VERIFIED')) {Remove-Item ('Env:'+ $name) -ErrorAction SilentlyContinue}
  if($private -and (Test-Path -LiteralPath $private)) {Remove-Item -LiteralPath $private -Recurse -Force}
}
exit $exitCode
