param([Parameter(Mandatory=$true)][string]$ArtifactDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ui='dc58f76f67dac13aa886c8d45475944f31b0c039'
$archiveSha='131717933f8c7fbe4a4385dfa313abd700ffd016926164d825b6bde86aa90edf'
if($env:ROCKY_HOST -cne '10.10.10.14' -or $env:ROCKY_USERNAME -cne 'root' -or -not $env:ROCKY_PASSWORD) {throw 'Exact DC runtime credential binding required.'}
if($env:GITHUB_RUN_ID -cnotmatch '^[0-9]{1,20}$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[0-9]{1,6}$') {throw 'Run identity required.'}
$runIdentity="$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$private=Join-Path $env:RUNNER_TEMP "layersentry-dc-ui-private-$runIdentity"
$evidence=Join-Path $env:RUNNER_TEMP "layersentry-dc-ui-evidence-$runIdentity"
$remote="/run/layersentry-dr-ui-$runIdentity"
$state=[ordered]@{schema=1;target='10.10.10.14';source=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;runAttempt=$env:GITHUB_RUN_ATTEMPT;uiCommit=$ui;archiveSha256=$archiveSha;status='PENDING';phase='Preflight';deploymentInvoked=$false;productionCertified=$false;guiVerified=$false;remoteStaging=$remote;stagingRetained=$false}
New-Item -ItemType Directory -Path $evidence -ErrorAction Stop|Out-Null
try {
    $archive=Join-Path $ArtifactDirectory 'ui-dist.tar.gz'
    $checksum=Join-Path $ArtifactDirectory 'ui-dist.tar.gz.sha256'
    $manifestPath=Join-Path $ArtifactDirectory 'build-manifest.json'
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $archiveSha) {throw 'Approved UI archive digest mismatch.'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if((@($manifest.PSObject.Properties.Name|Sort-Object)-join ',') -cne 'artifact,artifactSha256,builtOnManagementNode,cloudstackUiCommit,component,product,schemaVersion' -or $manifest.cloudstackUiCommit -cne $ui -or $manifest.artifactSha256 -cne $archiveSha -or $manifest.artifact -cne 'ui-dist.tar.gz' -or $manifest.schemaVersion -cne '1.0' -or $manifest.product -cne 'LayerSentry' -or $manifest.component -cne 'cloudstack-ui' -or $manifest.builtOnManagementNode -ne $false) {throw 'Approved build manifest mismatch.'}
    if((Get-Content -LiteralPath $checksum -Raw).Trim() -cnotmatch "^${archiveSha} [ *]ui-dist\.tar\.gz$") {throw 'Approved checksum file mismatch.'}
    $keys=@($env:DC_KNOWN_HOSTS.Replace("`r",'').Split("`n")|Where-Object{$_.Trim()})
    if($keys.Count -eq 0) {throw 'Verified known_hosts required.'}
    foreach($line in $keys) {if($line -cnotmatch '^10\.10\.10\.14 (ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,2}$') {throw 'Only exact verified DC host keys permitted.'}}
    New-Item -ItemType Directory -Path $private -ErrorAction Stop|Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $private /inheritance:r /grant:r "${owner}:(OI)(CI)F"|Out-Null
    if($LASTEXITCODE -ne 0) {throw 'Private ACL failed.'}
    $known=Join-Path $private 'known_hosts';$askpass=Join-Path $private 'askpass.cmd'
    [IO.File]::WriteAllText($known,($keys -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    $askpassText='@echo off'+"`r`n"+'powershell.exe -NoProfile -NonInteractive -Command "[Console]::Write([Environment]::GetEnvironmentVariable(''ROCKY_PASSWORD''))"'+"`r`n"
    [IO.File]::WriteAllText($askpass,$askpassText,[Text.Encoding]::ASCII)
    $env:SSH_ASKPASS=$askpass;$env:SSH_ASKPASS_REQUIRE='force';$env:DISPLAY='layersentry-noninteractive'
    $ssh=(Get-Command ssh.exe -CommandType Application -ErrorAction Stop).Source
    $scp=(Get-Command scp.exe -CommandType Application -ErrorAction Stop).Source
    $state['sshExecutable']=$ssh
    $opts=@('-F','NUL','-o','BatchMode=no','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','-o','NumberOfPasswordPrompts=1','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$known",'-o','GlobalKnownHostsFile=NUL','-o','UpdateHostKeys=no','-o','ForwardAgent=no','-o','LogLevel=ERROR','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=4')
    foreach($name in @('deploy-dr-cloudstack-ui.sh','deploy-dc-current-ui.sh')) {
        $source=(Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -Raw -Encoding UTF8).Replace("`r`n","`n")
        [IO.File]::WriteAllText((Join-Path $private $name),$source,[Text.UTF8Encoding]::new($false))
    }
    $helper=Join-Path $private 'deploy-dr-cloudstack-ui.sh'
    if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant() -cne '60fa2fe3142e6a8a9c01c3c33c2afab6187984294618d09eff86efeba0bb8f0d') {throw 'Reviewed deployment helper changed.'}
    $wrapper=Join-Path $private 'deploy-dc-current-ui.sh'
    $wrapperSha=(Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash.ToLowerInvariant()
    $state['wrapperSha256']=$wrapperSha
    $state.status='BLOCKED';$state['phase']='Stage'
    # Native stderr is withheld, including SSH/client exceptions; evidence is projected below.
    $nativePreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {
        $output=@(& $ssh @opts 'root@10.10.10.14' "umask 077; test ! -e '$remote' && mkdir '$remote'" 2>$null)
        $code=$LASTEXITCODE
    } finally {$ErrorActionPreference=$nativePreference}
    if($code -ne 0) {throw 'Exact remote staging creation failed.'}
    $state.stagingRetained=$true
    $copyArgs=@($opts)+@($archive,$checksum,$manifestPath,$helper,$wrapper,"root@10.10.10.14:$remote/")
    $nativePreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {$output=@(& $scp @copyArgs 2>$null);$code=$LASTEXITCODE} finally {$ErrorActionPreference=$nativePreference}
    if($code -ne 0) {throw 'Transfer failed; staging retained for reviewed recovery.'}
    $state.phase='Deploy';$state.deploymentInvoked=$true
    $command="printf '%s  %s\n' '$wrapperSha' '$remote/deploy-dc-current-ui.sh' | sha256sum --check --strict --status && timeout 1200 bash '$remote/deploy-dc-current-ui.sh' '$remote' '$runIdentity'"
    $nativePreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {$output=@(& $ssh @opts 'root@10.10.10.14' $command 2>$null);$code=$LASTEXITCODE} finally {$ErrorActionPreference=$nativePreference}
    $state['remoteExitCode']=$code
    $allowed=@('EXACT_UI_FILES=PASS','HTTP_UI_ASSET_HASHES=PASS','BACKEND_CONTENT_HASHES=PASS','RUNTIME_CONFIG_PRESERVATION=PASS','DC_SERVER_PROPERTIES_PRESERVATION=PASS','LAYERSENTRY_DC_UI_DEPLOYMENT=PASS',"CLOUDSTACK_UI_COMMIT=$ui",'CLOUDSTACK_VERSION=4.22.1.1','RUNTIME_PRODUCT=LayerSentry','RUNTIME_PROFILE=layersentry-kvm','HTTP_CLIENT=200')
    $observed=@($output|ForEach-Object{[string]$_}|Where-Object{$_ -cin $allowed}|Sort-Object -Unique)
    $state['checks']=$observed
    if($code -ne 0 -or $observed.Count -ne $allowed.Count) {throw 'Deployment incomplete; no automatic retry or cleanup.'}
    $state.status='PARTIAL';$state.phase='Complete';$state['artifactServedVerified']=$true
} catch {
    $state.status='BLOCKED'
    throw "DC current UI deployment stopped at $($state.phase): $($state.status)."
} finally {
    $state|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $evidence 'summary.json') -Encoding UTF8
    Remove-Item Env:SSH_ASKPASS,Env:SSH_ASKPASS_REQUIRE,Env:DISPLAY -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $private) {Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue}
}
