$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-PrivateText([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

if ($env:GITHUB_EVENT_NAME -eq 'push') {
    [string[]]$changed = @(git diff-tree --no-commit-id --name-only --diff-filter=A -r $env:GITHUB_SHA -- 'hack/layersentry/dr-management-actions/*.json')
    if ($LASTEXITCODE -ne 0 -or $changed.Count -ne 1) { throw 'Expected one newly added deployment action envelope.' }
    $env:DR_ACTION = $changed[0].Trim()
}
if ($env:DR_ACTION -cnotmatch '^hack/layersentry/dr-management-actions/[a-z0-9-]+\.json$') { throw 'Invalid action envelope path.' }
$action = Get-Content -LiteralPath $env:DR_ACTION -Raw -Encoding UTF8 | ConvertFrom-Json
if ((@($action.PSObject.Properties.Name | Sort-Object) -join ',') -cne 'authorization,phase,request') { throw 'Invalid action envelope fields.' }
if ($action.phase -cnotin @('Preflight', 'Apply', 'Status', 'RecoverDatabaseBootstrap')) { throw 'Invalid deployment phase.' }
if ($action.request -cnotmatch '^hack/layersentry/dr-management-requests/[a-z0-9-]+\.json$') { throw 'Invalid deployment request path.' }
$request = Get-Content -LiteralPath $action.request -Raw -Encoding UTF8 | ConvertFrom-Json
if ($request.request_id -cnotmatch '^[a-z0-9-]{1,64}$' -or $request.source_sha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid request identity.' }
if ($action.phase -ceq 'Apply' -and $action.authorization -cne "$($request.request_id):Apply") { throw 'Exact Apply authorization required.' }
if ($action.phase -ceq 'RecoverDatabaseBootstrap' -and $action.authorization -cne "$($request.request_id):RecoverDatabaseBootstrap") { throw 'Exact database bootstrap recovery authorization required.' }
if ($action.phase -cnotin @('Apply', 'RecoverDatabaseBootstrap') -and $action.authorization -cne '') { throw 'Read-only phase authorization must be empty.' }
$actualSha = (& git -C cloudstack-installer rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actualSha -cne $request.source_sha) { throw 'Installer branch differs from the reviewed source SHA.' }
if ($env:DR_HOST -cne '10.10.10.20' -or $env:DR_USER -cne 'root') { throw 'DR target binding failed.' }
if (-not $env:DR_KEY -or -not $env:DR_KNOWN_HOSTS -or -not $env:DR_PASSWORD -or -not $env:DR_CERTIFICATE) { throw 'Required deployment secrets are missing.' }
if ($env:GITHUB_RUN_ID -cnotmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -cnotmatch '^\d+$') { throw 'Invalid run identity.' }
$runId = "$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$private = Join-Path $env:RUNNER_TEMP "dr-management-private-$runId"
$evidence = Join-Path $env:RUNNER_TEMP "dr-management-evidence-$runId"
$remote = "/run/layersentry-dr-deploy-$runId"
$remoteCreated = $false
New-Item -ItemType Directory -Path $private -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $evidence -ErrorAction Stop | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $private /inheritance:r /grant:r "${identity}:(OI)(CI)(F)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Private runtime directory ACL failed.' }
$key = Join-Path $private 'identity'
$known = Join-Path $private 'known_hosts'
$bundle = Join-Path $private 'bundle'
try {
    New-Item -ItemType Directory -Path $bundle -ErrorAction Stop | Out-Null
    Write-PrivateText $key ($env:DR_KEY.Replace("`r", '') + "`n")
    Write-PrivateText $known ($env:DR_KNOWN_HOSTS.Replace("`r", '') + "`n")
    $deploymentSecrets = [ordered]@{
        db_password = $env:DR_PASSWORD
        db_admin_password = $env:DR_PASSWORD
        management_key = $env:DR_PASSWORD
        database_key = $env:DR_PASSWORD
        backup_db_password = $env:DR_PASSWORD
    } | ConvertTo-Json -Compress
    Write-PrivateText (Join-Path $bundle 'secrets.json') $deploymentSecrets
    Write-PrivateText (Join-Path $bundle 'recipient.pem') $env:DR_CERTIFICATE.Replace("`r", '')
    Copy-Item -LiteralPath $action.request -Destination (Join-Path $bundle 'request.json')
    Copy-Item -LiteralPath $env:DR_ACTION -Destination (Join-Path $bundle 'action.json')
    Copy-Item -LiteralPath 'hack/layersentry/dr-management-remote.py' -Destination (Join-Path $bundle 'remote.py')
    foreach ($name in @('install-rocky9.py', 'bootstrap-rocky9-management.sh', 'db-backup.py')) {
        Copy-Item -LiteralPath "cloudstack-installer/tools/layersentry-management/$name" -Destination $bundle
    }
    $deploymentSecrets = ''; $env:DR_KEY = ''; $env:DR_PASSWORD = ''; $env:DR_CERTIFICATE = ''
    $options = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=yes', '-o', "UserKnownHostsFile=$known", '-o', 'LogLevel=ERROR', '-i', $key)
    $target = 'root@10.10.10.20'
    $output = & ssh @options $target "umask 077; mkdir '$remote'" 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Private remote staging creation failed; SSH output withheld.' }
    $remoteCreated = $true
    $output = & scp @options -r $bundle "${target}:$remote/" 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Secure installer transfer failed; SCP output withheld.' }
    $output = & ssh @options $target "chmod -R go-rwx '$remote'; python3 '$remote/bundle/remote.py' '$remote/bundle'" 2>&1
    $remoteExit = $LASTEXITCODE
    # remote.py emits only a fixed evidence schema. Never publish raw SSH/tool output.
    try { $result = ($output -join "`n") | ConvertFrom-Json } catch { throw 'No valid sanitized remote result; output withheld.' }
    $allowed = @('schema_version','request_id','source_sha','phase','outcome','failure_stage','installer_exit_code','services','ui_http_status','selinux','journal_stages','acceptance','cleanup_complete')
    if (@($result.PSObject.Properties.Name | Where-Object { $_ -cnotin $allowed }).Count) { throw 'Remote evidence contains unexpected fields.' }
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'result.json') -Encoding UTF8
    if ($remoteExit -ne 0 -or $result.outcome -cne 'passed') { throw 'Deployment phase did not pass; inspect sanitized result artifact.' }
}
finally {
    try {
        if ($remoteCreated) {
            $cleanup = & ssh @options 'root@10.10.10.20' "rm -rf -- '$remote'" 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Remote staging cleanup requires follow-up; runtime path contains this run ID.' }
        }
    } catch {
        Write-Warning 'Remote staging cleanup could not be confirmed.'
    } finally {
        Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue
        $deploymentSecrets = ''; $env:DR_KEY = ''; $env:DR_PASSWORD = ''; $env:DR_CERTIFICATE = ''
    }
}
