param([ValidateSet('ObserveIdentity','Plan','Prepare','Install','Activate','Firewall')][string]$Mode='Plan', [string]$PlanPath='', [string]$PlanSha256='', [string[]]$FirewallSources=@())
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$out = Join-Path $env:RUNNER_TEMP "layersentry-dc-native-tls-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-$Mode"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$summary = Join-Path $out 'summary.json'
$state = [ordered]@{ target = '10.10.10.14'; user = 'root'; runnerCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT; status = 'PENDING'; mode = $Mode; nativeTlsMutationRequested = ($Mode -cnotin @('ObserveIdentity','Plan')); tlsJournalWritesPossible = ($Mode -cnotin @('ObserveIdentity','Plan')) }
$private = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N'))
try {
    if($Mode -ceq 'ObserveIdentity') {
        if($env:COMPUTERNAME -cne 'TESTSER') {throw 'Hyper-V host identity mismatch.'}
        Import-Module Hyper-V -ErrorAction Stop
        $vmId='29ba176b-b81a-4f47-8f51-ecec869f247f'
        $vms=@(Get-VM -Name 'sen' -ErrorAction Stop)
        if($vms.Count -ne 1 -or [string]$vms[0].Id -cne $vmId -or [string]$vms[0].State -cne 'Running') {throw 'Exact sen VM identity unavailable.'}
        $systems=@(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Name='$vmId'" -ErrorAction Stop)
        if($systems.Count -ne 1 -or $systems[0].ElementName -cne 'sen') {throw 'Exact sen CIM system unavailable.'}
        $settings=@(Get-CimAssociatedInstance -InputObject $systems[0] -ResultClassName Msvm_VirtualSystemSettingData -ErrorAction Stop | Where-Object {$_.VirtualSystemType -ceq 'Microsoft:Hyper-V:System:Realized'})
        if($settings.Count -ne 1 -or $settings[0].VirtualSystemIdentifier -ine $vmId) {throw 'Exact realized sen settings unavailable.'}
        $bios=[Guid]::Parse($settings[0].BIOSGUID).ToString('D')
        if($bios -ceq [Guid]::Empty.ToString('D')) {throw 'Empty BIOS identity.'}
        $state['hypervVmId']=$vmId
        $state['hypervBiosGuid']=$bios
    }
    $sshCommand = Get-Command ssh.exe -CommandType Application -ErrorAction Stop
    $sshExecutable = $sshCommand.Source
    if (-not [IO.Path]::IsPathRooted($sshExecutable) -or -not (Test-Path -LiteralPath $sshExecutable -PathType Leaf)) { throw 'SSH executable resolution failed.' }
    $state['sshExecutable'] = $sshExecutable
    $versionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $versionOutput = @(& $sshExecutable -V 2>&1) } finally { $ErrorActionPreference = $versionPreference }
    $versionText = $versionOutput -join ' '
    if ($versionText -match '(OpenSSH(?:_for_Windows)?_[0-9][A-Za-z0-9.p_-]{0,40})') { $state['sshVersion'] = $Matches[1] }
    if ($env:ROCKY_HOST -cne '10.10.10.14' -or $env:ROCKY_USERNAME -cne 'root') {
        $state.status = 'TARGET_BINDING_FAILED'
        throw 'R0 secrets must bind exactly to DC 10.10.10.14/root.'
    }
    if ([string]::IsNullOrWhiteSpace($env:DC_KNOWN_HOSTS)) {
        $state.status = 'SSH_TRUST_PREREQUISITE_MISSING'
        throw 'Provide independently verified DC host public key(s) in LAYERSENTRY_DC_SSH_KNOWN_HOSTS.'
    }
    $keys = @($env:DC_KNOWN_HOSTS.Replace("`r", '').Split("`n") | Where-Object { $_.Trim() })
    foreach ($line in $keys) {
        if ($line -cnotmatch '^10\.10\.10\.14 (ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/]+={0,2}$') {
            $state.status = 'SSH_TRUST_BINDING_INVALID'
            throw 'DC known_hosts must contain only exact 10.10.10.14 host-key entries; no wildcards, commands or other targets.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($env:ROCKY_PASSWORD)) {
        $state.status = 'CREDENTIAL_PREREQUISITE_MISSING'
        throw 'Protected Rocky R0 password is unavailable.'
    }
    New-Item -ItemType Directory -Path $private -ErrorAction Stop | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $private /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Private SSH directory ACL failed.' }
    $known = Join-Path $private 'known_hosts'
    $askPass = Join-Path $private 'askpass.cmd'
    [IO.File]::WriteAllText($known, ($keys -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    # The helper contains an environment lookup, never the password value.
    $askPassText = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -NonInteractive -Command "[Console]::Write([Environment]::GetEnvironmentVariable(''ROCKY_PASSWORD''))"' + "`r`n"
    [IO.File]::WriteAllText($askPass, $askPassText, [Text.Encoding]::ASCII)
    $env:SSH_ASKPASS = $askPass
    $env:SSH_ASKPASS_REQUIRE = 'force'
    $env:DISPLAY = 'layersentry-noninteractive'
    if ($Mode -cne 'ObserveIdentity' -and ([string]::IsNullOrWhiteSpace($env:CLOUDSTACK_API_KEY) -or [string]::IsNullOrWhiteSpace($env:CLOUDSTACK_SECRET_KEY))) {
        $state.status = 'API_CREDENTIAL_PREREQUISITE_MISSING'
        throw 'Protected runtime API credentials are unavailable.'
    }
    $proof = Get-Content -LiteralPath 'hack/layersentry/evidence/dc-registration-public-proof-20260906.json' -Raw | ConvertFrom-Json
    $proofBytes = [Convert]::FromBase64String($proof.base64)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $proofHash = ([BitConverter]::ToString($sha.ComputeHash($proofBytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($proofHash -cne 'f268bcf25a51e28d33fe475607252d2c8219b51fa9b1f70ea35450c775f2d3a1' -or $proof.sha256 -cne $proofHash) { throw 'Reviewed proof hash mismatch.' }
    $sources = @{}
    foreach ($entry in @(@('dr_recovery_acceptance','dr_recovery_acceptance.py'), @('dc_native_storage_registration','register-dc-native-storage.py'), @('dc_storage_loader','run-dc-storage-registration-stdin.py'), @('dc_native_tls','dc-native-tls.py'))) {
        $code = (Get-Content -LiteralPath (Join-Path 'hack/layersentry' $entry[1]) -Raw -Encoding UTF8).Replace("`r`n", "`n")
        $bytes = [Text.Encoding]::UTF8.GetBytes($code)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $codeHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        $sources[$entry[0]] = @{ base64 = [Convert]::ToBase64String($bytes); sha256 = $codeHash }
    }
    # Credentials are sent exclusively through encrypted SSH stdin. They never enter command arguments or disk files.
    $plan=@{}
    if($Mode -cnotin @('ObserveIdentity','Plan')) {
        if($PlanSha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]::IsNullOrWhiteSpace($PlanPath)) {throw 'Reviewed TLS Plan binding required.'}
        $receipt=Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($receipt.target -cne '10.10.10.14' -or $receipt.phase -cne 'Plan' -or $receipt.planSha256 -cne $PlanSha256) {throw 'TLS Plan receipt mismatch.'}
        $plan=$receipt.plan
        $FirewallSources=@($plan.firewallSources)
    }
    $apiKey=''; $apiSecret=''
    if($Mode -cne 'ObserveIdentity') {$apiKey=$env:CLOUDSTACK_API_KEY; $apiSecret=$env:CLOUDSTACK_SECRET_KEY}
    $envelope = @{ schema = 1; target = '10.10.10.14'; mode = $Mode; sources = $sources; proof = $proof.base64;
                   apiKey = $apiKey; apiSecret = $apiSecret; plan=$plan; planSha256=$PlanSha256; firewallSources=@($FirewallSources) } | ConvertTo-Json -Depth 8 -Compress
    $loader = (Get-Content -LiteralPath 'hack/layersentry/run-dc-native-tls-stdin.py' -Raw -Encoding UTF8).Replace("`r`n", "`n")
    $loaderEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($loader))
    $remote = "timeout 360 python3 <(printf %s $loaderEncoded | base64 -d)"
    # A separate script FD preserves private JSON stdin and avoids nested Windows argument quotes.
    $state['proofSha256'] = $proofHash
    $sshArgs = @('-F', 'NUL', '-o', 'BatchMode=no', '-o', 'PreferredAuthentications=password',
        '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$known",
        '-o', 'GlobalKnownHostsFile=NUL', '-o', 'UpdateHostKeys=no',
        '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=2', 'root@10.10.10.14', $remote)
    $state.status = 'SSH_OR_COLLECTOR_FAILED'
    # Never publish raw SSH stderr, remote tracebacks or unvalidated output.
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @($envelope | & $sshExecutable @sshArgs 2>$null)
        $sshExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    $state['sshExitCode'] = $sshExit
    $joined = $output -join "`n"
    if ($joined.Length -gt 1048576) { throw 'Remote evidence size limit.' }
    $result = $joined | ConvertFrom-Json
    if ($null -ne $result.PSObject.Properties['status'] -and $result.status -cmatch '^[A-Z_]{1,100}$') { $state['remoteStatus'] = $result.status }
    if ($null -ne $result.PSObject.Properties['reason'] -and $result.reason -is [string] -and $result.reason -cmatch '^[A-Z_]{1,100}$') { $state['remoteReason'] = $result.reason }
    if ($sshExit -ne 0) { throw 'Pinned-host native TLS phase failed; inspect durable journal before any next execution.' }
    if ($result.schema -ne 1 -or $result.target -cne '10.10.10.14' -or $result.phase -cne $Mode -or $result.productionCertified -ne $false -or $result.automaticReplay -ne $false) { throw 'TLS evidence binding failed.' }
    if($joined -match 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY') {throw 'Private key output refused.'}
    if($Mode -ceq 'ObserveIdentity') {
        if($result.guestProductUuid -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {throw 'Guest public UUID shape invalid.'}
        $state['guestProductUuid']=$result.guestProductUuid
        $state['biosEqualsGuest']=($state.hypervBiosGuid -ceq $result.guestProductUuid)
        $state['vmIdEqualsGuest']=($state.hypervVmId -ceq $result.guestProductUuid)
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $out 'dc-native-tls.json') -Encoding UTF8
    $state.status = 'OBSERVED'
} catch {
    # Parser/native exceptions can include remote content. Publish only state.
    throw "DC native TLS phase failed: $($state.status)."
} finally {
    $state | ConvertTo-Json | Set-Content -LiteralPath $summary -Encoding UTF8
    $envelope = $null
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY, Env:CLOUDSTACK_API_KEY, Env:CLOUDSTACK_SECRET_KEY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
}
