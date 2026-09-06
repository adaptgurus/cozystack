param([ValidateSet('collect-dc-r0-readonly.py', 'collect-dc-storage-readonly.py')][string]$Collector = 'collect-dc-r0-readonly.py')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$out = Join-Path $env:RUNNER_TEMP "layersentry-dc-r0-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$summary = Join-Path $out 'summary.json'
$state = [ordered]@{ target = '10.10.10.14'; user = 'root'; runnerCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT; status = 'PENDING'; mutationPerformed = $false }
$private = Join-Path $env:RUNNER_TEMP ([Guid]::NewGuid().ToString('N'))
try {
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
    $script = (Get-Content -LiteralPath (Join-Path 'hack/layersentry' $Collector) -Raw -Encoding UTF8).Replace("`r`n", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    $remote = "printf '%s' '$encoded' | base64 -d | timeout 120 python3 -"
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
        $output = @(& ssh.exe @sshArgs 2>$null)
        $sshExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    $state['sshExitCode'] = $sshExit
    if ($sshExit -ne 0) { throw 'Pinned-host SSH or DC collector failed; no raw diagnostic output published.' }
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($result.schemaVersion -cne '1.0' -or $result.target -cne '10.10.10.14' -or $result.status -cne 'COLLECTED' -or $result.mutationPerformed -ne $false) {
        throw 'DC collector evidence contract failed.'
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $out 'inventory.json') -Encoding UTF8
    $state.status = 'COLLECTED'
} catch {
    # Parser/native exceptions can include remote content. Publish only state.
    throw "DC R0 inventory failed: $($state.status)."
} finally {
    $state | ConvertTo-Json | Set-Content -LiteralPath $summary -Encoding UTF8
    Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
}
