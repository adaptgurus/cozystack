$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-RetainedBoot($summary, $result, $ownership, $cleanup, $facts) {
    if ($summary.status -cne 'LIVE_VERIFIED' -or $summary.target -cne '10.10.10.20' -or $summary.runId -cne $env:BOOT_RUN -or $summary.runnerCommit -cne $env:BOOT_RUNNER_SOURCE -or $summary.bootSource -cne $env:BOOT_SOURCE -or $summary.imageSha256 -cne $env:IMAGE_SHA256 -or $summary.bootExitCode -ne 0) { throw 'Successful boot summary binding failed.' }
    $identity = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$ownership.domainUuid, 'D', [ref]$identity) -or $identity.ToString('D') -cne $ownership.domainUuid) { throw 'Canonical retained UUID required.' }
    $base = "/var/lib/libvirt/images/layersentry-cpuqc-$identity"
    if ($ownership.domainName -cne "layersentry-cpuqc-$identity" -or $ownership.diskPath -cne "$base/runtime.qcow2" -or $ownership.seedPath -cne "$base/seed.iso" -or $ownership.sourceSha256 -cne $env:IMAGE_SHA256 -or $ownership.retainForDrQualification -ne $true) { throw 'Retained fixture/image binding failed.' }
    if ($result.status -cne 'LIVE_VERIFIED' -or $result.scope -cne 'networkless Rocky CPU image boot and QGA' -or $result.domainUuid -cne $ownership.domainUuid -or $result.sourceSha256 -cne $env:IMAGE_SHA256 -or $result.ownershipManifest -cne "$base/ownership.json" -or $summary.ownershipManifest -cne $result.ownershipManifest -or $result.productionQualified -ne $false -or $result.rke2Started -ne $false) { throw 'Boot receipt binding failed.' }
    if ($cleanup.status -cne 'PENDING' -or $cleanup.reason -cne 'EXPLICITLY_RETAINED_FOR_DR_QUALIFICATION' -or $cleanup.domainUuid -cne $ownership.domainUuid -or $cleanup.ownershipManifest -cne $result.ownershipManifest) { throw 'Explicit retained cleanup receipt required.' }
    if ($facts.selinux -cne 'Enforcing' -or $facts.hostPublicKeyExportVerified -ne $true -or $facts.fixtureId -cne $ownership.domainUuid -or $facts.qgaSelinuxContext -cnotmatch '^system_u:system_r:virt_qemu_ga_t:s0$') { throw 'Enforcing confined QGA boot proof required.' }
    return $result.ownershipManifest
}
$out = Join-Path $env:RUNNER_TEMP "layersentry-dr-cpu-capture-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
if (-not (Test-Path -LiteralPath $out)) { New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null }
$private = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N'))
$state = [ordered]@{status='PENDING';target='10.10.10.20';runnerCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;runAttempt=$env:GITHUB_RUN_ATTEMPT;captureSource=$env:CAPTURE_SOURCE;imageSha256=$env:IMAGE_SHA256;bootRun=$env:BOOT_RUN;bootArtifact=$env:BOOT_ARTIFACT;mutationAttempted=$false;captureReplay='PROHIBITED_WITHOUT_RECONCILIATION';productionQualified=$false}
try {
    if ($env:DR_HOST -cne '10.10.10.20' -or $env:DR_USER -cne 'root' -or -not $env:DR_KEY -or -not $env:DR_KNOWN_HOSTS) { throw 'Exact-target verified SSH credentials required.' }
    foreach ($name in @('GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','BOOT_RUN','BOOT_ARTIFACT')) { if ([Environment]::GetEnvironmentVariable($name) -cnotmatch '^[0-9]{1,20}$') { throw 'Invalid run identity.' } }
    if ($env:CAPTURE_SOURCE -cne '8f94ee6e2ac1e360e39b71b8247e64b62187ef0d' -or $env:IMAGE_SHA256 -cne '7580d64a5b9f27d930d7a5f5688f67063db042252dd43c7cf280fdb3e101a34d') { throw 'Reviewed source/image pins required.' }
    $boot = Join-Path $env:RUNNER_TEMP "layersentry-dr-capture-boot-$env:GITHUB_RUN_ID"
    $records = @{}
    foreach ($name in @('summary','result','ownership','cleanup','guest-checks')) {
        $path = Join-Path $boot "$name.json"
        $info = Get-Item -LiteralPath $path
        if ($info.Length -gt 1048576 -or ($info.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe boot evidence file.' }
        $records[$name] = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    $owned = Assert-RetainedBoot $records.summary $records.result $records.ownership $records.cleanup $records.'guest-checks'
    $keys = @($env:DR_KNOWN_HOSTS.Replace("`r", '').Split("`n") | Where-Object { $_.Trim() })
    if ($keys.Count -lt 1) { throw 'Verified DR host keys unavailable.' }
    foreach ($line in $keys) { if ($line -cnotmatch '^10\.10\.10\.20 (ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,2}( .*)?$') { throw 'Verified DR target binding failed.' } }
    New-Item -ItemType Directory -Path $private -ErrorAction Stop | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $private /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Private SSH ACL failed.' }
    $key = Join-Path $private 'identity'
    $known = Join-Path $private 'known_hosts'
    [IO.File]::WriteAllText($key, $env:DR_KEY.Replace("`r", '') + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($known, ($keys -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $sshOptions = @('-F','NUL','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o',"UserKnownHostsFile=$known",'-o','GlobalKnownHostsFile=NUL','-o','UpdateHostKeys=no','-o','LogLevel=ERROR','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-i',$key)
    function Invoke-PinnedRemote([string]$Code) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Code.Replace("`r`n", "`n")))
        $remote = "printf '%s' '$encoded' | base64 -d | timeout --signal=TERM --kill-after=30 2700 python3 -"
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $script:remoteOutput = @(& ssh.exe @sshOptions 'root@10.10.10.20' $remote 2>$null); $script:remoteCode = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    }
    $sourceHead = (& git -C capture-source rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceHead -cne $env:CAPTURE_SOURCE) { throw 'Capture source checkout mismatch.' }
    $files = @('dr_cpu_capture_acceptance.py','dr_libvirt_capture.py','dr_file_replication.py','dr_replication.py','dr_replication_transport.py','dr_state_machine.py','k8s/image/boot_qga_acceptance.py')
    $hashes = @{}
    foreach ($name in $files) { $hashes[$name] = (Get-FileHash -LiteralPath "capture-source/tools/layersentry/$name" -Algorithm SHA256).Hash.ToLowerInvariant() }
    $request = @{runId=$env:GITHUB_RUN_ID;runAttempt=$env:GITHUB_RUN_ATTEMPT;bootRunId=$env:BOOT_RUN;bootArtifactId=$env:BOOT_ARTIFACT;bootRunnerCommit=$env:BOOT_RUNNER_SOURCE;cloudStackSource=$env:CAPTURE_SOURCE;imageSha256=$env:IMAGE_SHA256;ownership=$records.ownership;ownershipManifest=$owned;sourceHashes=$hashes}
    $requestPath = Join-Path $private 'request.json'
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $remoteRoot = "/var/lib/layersentry-validation/dr-capture-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    $prepare = @'
import os,pathlib,stat
assert os.geteuid()==0
base=pathlib.Path('/var/lib/layersentry-validation')
assert base.resolve()==base and base.stat().st_uid==0 and not base.stat().st_mode & 0o077
root=base/'dr-capture-RUN_ID-RUN_ATTEMPT'
root.mkdir(mode=0o700)
(root/'source').mkdir(mode=0o700)
(root/'source/k8s').mkdir(mode=0o700)
(root/'source/k8s/image').mkdir(mode=0o700)
'@
    $state['stage'] = 'COPYING_PINNED_SOURCE'
    $state.mutationAttempted = $true
    Invoke-PinnedRemote $prepare.Replace('RUN_ID',$env:GITHUB_RUN_ID).Replace('RUN_ATTEMPT',$env:GITHUB_RUN_ATTEMPT)
    if ($remoteCode -ne 0) { throw 'Private capture workspace creation failed; no capture submitted.' }
    foreach ($name in $files) {
        & scp.exe @sshOptions "capture-source/tools/layersentry/$name" "root@10.10.10.20:${remoteRoot}/source/$name" 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Pinned source copy failed; no capture submitted.' }
    }
    $wrapper = (Resolve-Path 'hack/layersentry/run-dr-cpu-capture.py').Path
    $wrapperHash = (Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash.ToLowerInvariant()
    foreach ($item in @(@($requestPath,'request.json'),@($wrapper,'runner.py'))) {
        & scp.exe @sshOptions $item[0] "root@10.10.10.20:${remoteRoot}/$($item[1])" 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Capture request copy failed; no capture submitted.' }
    }
    $launch = @'
import hashlib,os,pathlib,subprocess
root=pathlib.Path('/var/lib/layersentry-validation/dr-capture-RUN_ID-RUN_ATTEMPT')
assert root.resolve()==root and root.stat().st_uid==0 and not root.stat().st_mode & 0o077
script=root/'runner.py'
assert not script.is_symlink() and hashlib.sha256(script.read_bytes()).hexdigest()=='SCRIPT_SHA'
for p in root.rglob('*'):
 if p.is_file(): os.chmod(p,0o600)
raise SystemExit(subprocess.run(['python3',str(script),'--root',str(root)],timeout=2650).returncode)
'@
    $state['stage'] = 'CAPTURE_OUTCOME_PENDING'
    Invoke-PinnedRemote $launch.Replace('RUN_ID',$env:GITHUB_RUN_ID).Replace('RUN_ATTEMPT',$env:GITHUB_RUN_ATTEMPT).Replace('SCRIPT_SHA',$wrapperHash)
    $state['remoteExitCode'] = $remoteCode
    $remoteText = $remoteOutput -join "`n"
    [IO.File]::WriteAllText((Join-Path $out 'remote-output.txt'),$remoteText,[Text.UTF8Encoding]::new($false))
    $receipt = $remoteText | ConvertFrom-Json
    $receipt | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $out 'remote-result.json') -Encoding UTF8
    if ($receipt.PSObject.Properties.Name -contains 'collection') {
        $zip = Join-Path $out 'public-evidence.zip'
        & scp.exe @sshOptions "root@10.10.10.20:${remoteRoot}/public-evidence.zip" $zip 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Bounded evidence transfer failed.' }
        if ((Get-Item -LiteralPath $zip).Length -ne $receipt.collection.archiveBytes -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $receipt.collection.archiveSha256) { throw 'Public evidence archive integrity failed.' }
    } else { throw 'Public evidence collection incomplete; exact source/workspace remains retained.' }
    if ($remoteCode -ne 0 -or $receipt.status -cne 'LIVE_VERIFIED' -or $receipt.sourceDomainUuid -cne $records.ownership.domainUuid -or $receipt.sourceCommit -cne $env:CAPTURE_SOURCE -or $receipt.imageSha256 -cne $env:IMAGE_SHA256 -or $receipt.productionQualified -ne $false) { throw 'Provider acceptance failed; reconcile retained source and catalog before any retry.' }
    $state.status = 'LIVE_VERIFIED'
    $state['scope'] = 'same-host networkless libvirt QCOW2 provider acceptance'
    $state['sourceOwnershipManifest'] = $owned
    $state['replicationOwnershipManifest'] = $receipt.replicationOwnershipManifest
} catch {
    $state.status = if ($state.mutationAttempted) { 'PARTIAL' } else { 'BLOCKED' }
    $state['failure'] = $_.Exception.Message
    throw 'DR provider capture did not pass; inspect bounded evidence and retained ownership before any retry.'
} finally {
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
    Remove-Item Env:DR_KEY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
}
