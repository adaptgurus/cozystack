$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$out = Join-Path $env:RUNNER_TEMP "layersentry-module-dr-host-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$private = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N'))
$state = [ordered]@{target='10.10.10.20'; runnerCommit=$env:GITHUB_SHA; runId=$env:GITHUB_RUN_ID; status='PENDING'; mutationPerformed=$false}
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
    $collector = if ($env:CAPTURE_PROBE -ceq 'true') { 'hack/layersentry/collect-dr-capture-readonly.py' } else { 'hack/layersentry/collect-dc-r0-readonly.py' }
    $script = (Get-Content -LiteralPath $collector -Raw -Encoding UTF8).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $remote = "printf '%s' '$encoded' | base64 -d | timeout 120 python3 - --target 10.10.10.20"
    $sshArgs = @('-F','NUL','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes',
        '-o',"UserKnownHostsFile=$known",'-o','GlobalKnownHostsFile=NUL','-o','UpdateHostKeys=no','-o','LogLevel=ERROR',
        '-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-i',$key,'root@10.10.10.20',$remote)
    $state.status = 'SSH_OR_COLLECTOR_FAILED'
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& ssh.exe @sshArgs 2>$null); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    $state['sshExitCode'] = $code
    if ($code -ne 0) { throw 'Pinned DR SSH or collector failed.' }
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($result.schemaVersion -cne '1.0' -or $result.target -cne '10.10.10.20' -or $result.status -cne 'COLLECTED' -or $result.mutationPerformed -ne $false) { throw 'Collector scope contract failed.' }
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $out 'inventory.json') -Encoding UTF8
    $state.status = 'COLLECTED'
} catch {
    throw 'DR module inventory failed; inspect the sanitized summary.'
} finally {
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
    Remove-Item Env:DR_KEY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
}
