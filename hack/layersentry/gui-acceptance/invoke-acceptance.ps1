param(
  [Parameter(Mandatory=$true)][string]$RequestPath,
  [Parameter(Mandatory=$true)][string]$ArtifactDirectory,
  [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
  [ValidateSet('existing-operator','protected-personas')][string]$CredentialSource='protected-personas',
  [string]$ProtectedCredentialPath='C:\ProgramData\LayerSentry\gui-acceptance-credentials.json'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$privateDirectory=$null
$exitCode=1
try {
  if([string]::IsNullOrEmpty($env:DR_KEY) -or [string]::IsNullOrEmpty($env:DR_KNOWN_HOSTS) -or $env:DR_HOST -cne '10.10.10.20' -or $env:DR_USER -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') {throw 'Verified DR SSH credentials unavailable.'}
  $request=Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8|ConvertFrom-Json
  $currentSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $allowed=@($currentSid,'S-1-5-18','S-1-5-32-544')
  $privateDirectory=Join-Path $env:RUNNER_TEMP ('layersentry-gui-private-'+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $privateDirectory|Out-Null
  $acl=Get-Acl -LiteralPath $privateDirectory
  $acl.SetAccessRuleProtection($true,$false)
  $rule=New-Object System.Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
  $acl.AddAccessRule($rule)
  Set-Acl -LiteralPath $privateDirectory -AclObject $acl
  $keyFile=Join-Path $privateDirectory 'id_ed25519'
  $knownHostsFile=Join-Path $privateDirectory 'known_hosts'
  [IO.File]::WriteAllText($keyFile,($env:DR_KEY.Trim()+"`n"),(New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($knownHostsFile,($env:DR_KNOWN_HOSTS.Trim()+"`n"),(New-Object Text.UTF8Encoding($false)))
  $tunnelBinding=Join-Path $privateDirectory 'tunnel.json'
  $transport=@{target='dr';host=$env:DR_HOST;user=$env:DR_USER;keyFile=$keyFile;knownHostsFile=$knownHostsFile}
  [IO.File]::WriteAllText($tunnelBinding,($transport|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
  $env:DR_KEY=$null
  $env:DR_KNOWN_HOSTS=$null
  $credential=Join-Path $privateDirectory 'credentials.json'
  if($CredentialSource -eq 'existing-operator') {
    if($request.target -cne 'dr' -or @($request.personas).Count -ne 1 -or $request.personas[0].id -cne 'platform-admin') {throw 'Existing credential scope mismatch.'}
    if([string]::IsNullOrEmpty($env:LAYERSENTRY_CLOUDSTACK_USERNAME) -or [string]::IsNullOrEmpty($env:LAYERSENTRY_CLOUDSTACK_PASSWORD)) {throw 'Existing credentials unavailable.'}
    $body=@{'platform-admin'=@{username=$env:LAYERSENTRY_CLOUDSTACK_USERNAME;password=$env:LAYERSENTRY_CLOUDSTACK_PASSWORD;domain='/'}}
    [IO.File]::WriteAllText($credential,($body|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))
    $body=$null
  } else {
    $item=Get-Item -LiteralPath $ProtectedCredentialPath -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt 32768) {throw 'Unsafe credential input.'}
    $inputAcl=Get-Acl -LiteralPath $ProtectedCredentialPath
    $owner=New-Object Security.Principal.NTAccount($inputAcl.Owner)
    if($owner.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {throw 'Credential owner mismatch.'}
    foreach($access in $inputAcl.Access) {
      if($access.AccessControlType -eq 'Allow' -and $access.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {throw 'Credential ACL mismatch.'}
    }
    # Node verifies every path component, regular type and link count before read.
    $credential=$ProtectedCredentialPath
  }
  $env:LAYERSENTRY_CLOUDSTACK_USERNAME=$null
  $env:LAYERSENTRY_CLOUDSTACK_PASSWORD=$null
  $env:DEBUG=$null
  $env:PWDEBUG=$null
  $env:LAYERSENTRY_GUI_ACL_VERIFIED='1'
  $inventory=Join-Path $privateDirectory 'asset-inventory.json'
  & python (Join-Path $PSScriptRoot 'prepare_artifact.py') $ArtifactDirectory $request.cloudstackUiCommit $request.artifactSha256 $inventory
  if($LASTEXITCODE -ne 0) {throw 'Artifact preparation failed.'}
  & node (Join-Path $PSScriptRoot 'accept.mjs') $RequestPath $inventory $credential $EvidenceDirectory $tunnelBinding
  $exitCode=$LASTEXITCODE
} catch {
  # Never print raw PowerShell exceptions that may include credential objects.
  Write-Output 'GUI_ACCEPTANCE_RUNNER_FAILED'
  $exitCode=1
} finally {
  $env:DR_KEY=$null
  $env:DR_KNOWN_HOSTS=$null
  $env:LAYERSENTRY_GUI_ACL_VERIFIED=$null
  $env:LAYERSENTRY_CLOUDSTACK_USERNAME=$null
  $env:LAYERSENTRY_CLOUDSTACK_PASSWORD=$null
  if($privateDirectory -and (Test-Path -LiteralPath $privateDirectory)) {Remove-Item -LiteralPath $privateDirectory -Recurse -Force}
}
exit $exitCode
