$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$out = Join-Path $env:RUNNER_TEMP "layersentry-rke2-dr-boot-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$private = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N'))
$state = [ordered]@{target='10.10.10.20'; runnerCommit=$env:GITHUB_SHA; runId=$env:GITHUB_RUN_ID; status='PENDING'; mutationAttempted=$false; imageSource=$env:IMAGE_SOURCE; bootSource=$env:BOOT_SOURCE; imageRun=$env:IMAGE_RUN; imageArtifact=$env:IMAGE_ARTIFACT; imageSha256=$env:IMAGE_SHA256}
try {
    if ($env:DR_HOST -cne '10.10.10.20' -or $env:DR_USER -cne 'root' -or -not $env:DR_KEY -or -not $env:DR_KNOWN_HOSTS) { throw 'Required exact-target DR credentials or verified host keys are unavailable.' }
    $keys = @($env:DR_KNOWN_HOSTS.Replace("`r", '').Split("`n") | Where-Object { $_.Trim() })
    if ($keys.Count -lt 1) { throw 'Verified DR host keys are unavailable.' }
    foreach ($line in $keys) {
        if ($line -cnotmatch '^10\.10\.10\.20 (ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,2}( .*)?$') { throw 'Verified DR host key target binding failed.' }
    }
    New-Item -ItemType Directory -Path $private -ErrorAction Stop | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $private /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Private SSH directory ACL failed.' }
    $key = Join-Path $private 'identity'
    $known = Join-Path $private 'known_hosts'
    [IO.File]::WriteAllText($key, $env:DR_KEY.Replace("`r", '') + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($known, ($keys -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    if ($env:GITHUB_RUN_ID -cnotmatch '^[0-9]{1,20}$' -or $env:IMAGE_SHA256 -cnotmatch '^[0-9a-f]{64}$' -or $env:IMAGE_SOURCE -cnotmatch '^[0-9a-f]{40}$') { throw 'Immutable input validation failed.' }
    if ($env:CACHE_RUN -and $env:CACHE_RUN -cnotmatch '^[0-9]{1,20}$') { throw 'Invalid sealed candidate cache run.' }
    if ($env:CACHE_RUN -and ($env:CACHE_RUN -cne '34057059334' -or $env:IMAGE_RUN -cne '34056395384' -or $env:IMAGE_ARTIFACT -cne '9996215787' -or $env:IMAGE_SOURCE -cne '4d0d323569805ae022d6094dfa2cfa0ced0ea071' -or $env:IMAGE_SHA256 -cne '7580d64a5b9f27d930d7a5f5688f67063db042252dd43c7cf280fdb3e101a34d')) { throw 'Cached image lacks the exact prior independent artifact binding.' }
    if (-not $env:CACHE_RUN) {
    $candidate = Join-Path $env:RUNNER_TEMP "layersentry-cpu-candidate-$env:GITHUB_RUN_ID/cpu-image"
    $image = Join-Path $candidate 'layersentry-rke2-rocky9-amd64.qcow2'
    $manifest = Get-Content -LiteralPath (Join-Path $candidate 'candidate-manifest.json') -Raw | ConvertFrom-Json
    $actualHash = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $env:IMAGE_SHA256 -or $manifest.sha256 -cne $actualHash -or $manifest.sourceCommit -cne $env:IMAGE_SOURCE -or $manifest.artifactType -cne 'layersentry-rke2-node-image' -or $manifest.status -cne 'CI_VERIFIED' -or $manifest.osVersion -cne '9.8' -or $manifest.rke2Version -cne 'v1.36.4+rke2r1' -or $manifest.rke2Started -ne $false -or $manifest.runtimeQualified -ne $false) { throw 'Candidate manifest binding failed.' }
    }
    $sourceHead = (& git -C candidate-source rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceHead -cne $env:BOOT_SOURCE) { throw 'Boot source binding failed.' }
    $bootScript = (Resolve-Path 'candidate-source/tools/layersentry/k8s/image/boot_qga_acceptance.py').Path
    $scriptHash = (Get-FileHash -LiteralPath $bootScript -Algorithm SHA256).Hash.ToLowerInvariant()
    $sshOptions = @('-F','NUL','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
        '-o',"UserKnownHostsFile=$known",'-o','GlobalKnownHostsFile=NUL','-o','UpdateHostKeys=no','-o','LogLevel=ERROR',
        '-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-i',$key)
    function Invoke-PinnedRemote([string]$Code) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Code.Replace("`r`n", "`n")))
        $remote = "printf '%s' '$encoded' | base64 -d | timeout 1300 python3 -"
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $script:remoteOutput = @(& ssh.exe @sshOptions 'root@10.10.10.20' $remote 2>$null); $script:remoteCode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    }
    $remoteRoot = "/var/lib/layersentry-validation/cpu-image-$env:GITHUB_RUN_ID"
    $preflight = @'
import json,os,pathlib,stat,subprocess
assert os.geteuid()==0
assert subprocess.check_output(['hostname','-f'],text=True).strip()=='layersentry-dr-mgmt1'
addresses=json.loads(subprocess.check_output(['ip','-j','-4','address','show']))
assert '10.10.10.20' in [a.get('local') for link in addresses for a in link.get('addr_info',[])]
assert subprocess.check_output(['getenforce'],text=True).strip()=='Enforcing'
assert subprocess.check_output(['systemctl','is-active','firewalld'],text=True).strip()=='active'
assert subprocess.check_output(['systemctl','is-active','cloudstack-management'],text=True).strip()=='active'
assert not subprocess.check_output(['virsh','--readonly','-c','qemu:///system','list','--all','--uuid'],text=True).strip()
assert stat.S_ISCHR(os.stat('/dev/kvm').st_mode)
free=os.statvfs('/var/lib/libvirt/images')
assert free.f_bavail*free.f_frsize >= 12*1024**3
base=pathlib.Path('/var/lib/layersentry-validation')
assert base.resolve()==base and base.stat().st_uid==0 and not base.stat().st_mode & 0o077
path=base/'cpu-image-RUN_ID'
path.mkdir(mode=0o700)
print(json.dumps({'status':'BOOT_DIRECTORY_CREATED','freeBytes':free.f_bavail*free.f_frsize}))
'@
    $state.status = 'HOST_PREFLIGHT'
    $state.mutationAttempted = $true
    Invoke-PinnedRemote $preflight.Replace('RUN_ID', $env:GITHUB_RUN_ID)
    if ($remoteCode -ne 0) { throw 'Host boot preflight failed before guest creation.' }
    $state['hostPreflight'] = ($remoteOutput -join "`n") | ConvertFrom-Json
    $state.status = 'COPYING_VERIFIED_CANDIDATE'
    if (-not $env:CACHE_RUN) {
    & scp.exe @sshOptions $image "root@10.10.10.20:${remoteRoot}/candidate.qcow2" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Candidate copy failed; no guest submitted.' }
    }
    & scp.exe @sshOptions $bootScript "root@10.10.10.20:${remoteRoot}/boot.py" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Boot source copy failed; no guest submitted.' }
    $launch = @'
import hashlib,json,os,pathlib,stat,subprocess
root=pathlib.Path('/var/lib/layersentry-validation/cpu-image-RUN_ID')
assert root.resolve()==root and root.stat().st_uid==0 and not root.stat().st_mode & 0o077
cached='CACHE_RUN'
if cached:
 source=pathlib.Path('/var/lib/layersentry-validation')/('cpu-image-'+cached)/'candidate.qcow2'
 assert source.resolve()==source and stat.S_ISREG(source.stat().st_mode) and source.stat().st_uid==0
 assert not source.stat().st_mode & 0o077 and not (root/'candidate.qcow2').exists()
 subprocess.run(['cp','--reflink=auto','--sparse=always',str(source),str(root/'candidate.qcow2')],check=True,timeout=300)
script=root/'boot.py'
assert not script.is_symlink() and hashlib.sha256(script.read_bytes()).hexdigest()=='SCRIPT_SHA'
for name in ('boot.py','candidate.qcow2'): os.chmod(root/name,0o600)
result=subprocess.run(['python3',str(script),'--image',str(root/'candidate.qcow2'),'--sha256','IMAGE_SHA','--evidence',str(root/'evidence'),'--retain-for-dr-qualification'],timeout=1200)
raise SystemExit(result.returncode)
'@
    $state.status = 'GUEST_BOOT_OUTCOME_PENDING'
    Invoke-PinnedRemote $launch.Replace('RUN_ID', $env:GITHUB_RUN_ID).Replace('SCRIPT_SHA', $scriptHash).Replace('IMAGE_SHA', $env:IMAGE_SHA256).Replace('CACHE_RUN', [string]$env:CACHE_RUN)
    $state['bootExitCode'] = $remoteCode
    # Only explicit harness evidence files, never the live image/host private keys.
    foreach ($name in @('result.json','guest-checks.json','domain-request.xml','domain-actual.xml','source-image-info.json','failure.txt','console.log','ownership.json','cleanup.json')) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & scp.exe @sshOptions "root@10.10.10.20:${remoteRoot}/evidence/$name" (Join-Path $out $name) 2>$null } finally { $ErrorActionPreference = $old }
    }
    if ($state.bootExitCode -ne 0) { throw 'Candidate boot did not pass; inspect owned fixture evidence before retry.' }
    $result = Get-Content -LiteralPath (Join-Path $out 'result.json') -Raw | ConvertFrom-Json
    if ($result.status -cne 'LIVE_VERIFIED' -or $result.scope -cne 'networkless Rocky CPU image boot and QGA' -or $result.sourceSha256 -cne $env:IMAGE_SHA256 -or $result.productionQualified -ne $false -or $result.rke2Started -ne $false) { throw 'Boot receipt validation failed.' }
    $state.status = 'LIVE_VERIFIED'
    $state['scope'] = 'networkless Rocky CPU image boot and QGA'
    $state['ownershipManifest'] = $result.ownershipManifest
} catch {
    throw 'DR candidate boot qualification failed; inspect bounded evidence and exact owned guest before retry.'
} finally {
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
    Remove-Item Env:DR_KEY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
}
