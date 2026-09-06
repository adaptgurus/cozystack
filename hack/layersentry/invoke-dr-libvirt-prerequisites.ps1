$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$out = Join-Path $env:RUNNER_TEMP "layersentry-dr-libvirt-prerequisites-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$private = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N'))
$state = [ordered]@{target='10.10.10.20'; runnerCommit=$env:GITHUB_SHA; runId=$env:GITHUB_RUN_ID; status='PENDING'; mutationAttempted=$false}
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
    $script = (Get-Content -LiteralPath 'hack/layersentry/prepare-dr-libvirt-validation.py' -Raw -Encoding UTF8).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    if ($env:DR_PHASE -cnotin @('prepare', 'inspect', 'reconcile-socket', 'complete-iso-tool')) { throw 'Invalid phase.' }
    if ($env:GITHUB_RUN_ID -cnotmatch '^[0-9]{1,20}$') { throw 'Run identity invalid.' }
    $prior = ''
    if ($env:DR_PHASE -cin @('reconcile-socket', 'complete-iso-tool')) {
        if ($env:DR_PRIOR_RUN -cnotmatch '^[0-9]{1,20}$') { throw 'Prior run invalid.' }
        $prior = ' ' + $env:DR_PRIOR_RUN
    }
    $remote = "printf '%s' '$encoded' | base64 -d | timeout 1100 python3 - $env:GITHUB_RUN_ID $env:DR_PHASE$prior"
    $sshArgs = @('-F','NUL','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
        '-o',"UserKnownHostsFile=$known",'-o','GlobalKnownHostsFile=NUL','-o','UpdateHostKeys=no','-o','LogLevel=ERROR',
        '-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-i',$key,'root@10.10.10.20',$remote)
    $state.status = 'REMOTE_OUTCOME_UNKNOWN'; $state.mutationAttempted = $true
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& ssh.exe @sshArgs 2>$null); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $state['sshExitCode'] = $code
    if (-not $output) { throw 'Remote outcome unknown; inspect exact run journal before retry.' }
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($result.schemaVersion -cne '1.0' -or $result.target -cne '10.10.10.20' -or $result.runId -cne $env:GITHUB_RUN_ID) { throw 'Prerequisite target contract failed.' }
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $out 'prerequisites.json') -Encoding UTF8
    $state.status = $result.status
    $state.mutationAttempted = $result.mutationAttempted
    if ($code -ne 0 -or $result.status -cnotin @('PREREQUISITES_VERIFIED', 'INSPECTED')) { throw 'Prerequisite validation failed.' }
} catch {
    throw 'DR libvirt prerequisites failed; inspect the sanitized summary.'
} finally {
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
    Remove-Item Env:DR_KEY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
}
