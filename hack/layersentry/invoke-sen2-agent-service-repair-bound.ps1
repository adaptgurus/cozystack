[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-sen2-agent-service-repair'),
    [int]$InitialWaitMinutes = 15,
    [int]$StableSamples = 24,
    [int]$StableIntervalSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    [System.IO.File]::WriteAllText(
        $Path,
        $Value,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Repair request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'REPAIR_SEN2_AGENT_SERVICE_CONFLICT') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.expectedRancherdServerUrl -ne 'https://10.10.10.11:443') {
    throw 'The bound repair requires the read-only verified rancherd server URL https://10.10.10.11:443.'
}
foreach ($forbidden in @(
    'reinstallOrWipeDisks',
    'deleteRke2Data',
    'acceptEula',
    'writeCredentialValuesToEvidence',
    'productionReleaseApprovalImplied'
)) {
    if ([bool]$request.$forbidden) {
        throw "Forbidden request flag is true: $forbidden"
    }
}

$sourcePath = Join-Path $PSScriptRoot 'repair-sen2-agent-service-conflict.ps1'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Authoritative service-repair source is missing: $sourcePath"
}
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
$legacyServer = 'https://10.10.10.10:443'
$expectedServer = [string]$request.expectedRancherdServerUrl
$replacementCount = [regex]::Matches($source, [regex]::Escape($legacyServer)).Count
if ($replacementCount -ne 1) {
    throw "Expected exactly one legacy rancherd server assertion; found $replacementCount."
}
$boundSource = $source.Replace($legacyServer, $expectedServer)
if ($boundSource -eq $source -or $boundSource.Contains($legacyServer)) {
    throw 'The request-bound rancherd server substitution was not applied exactly.'
}

$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-sen2-bound-repair-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
$boundPath = Join-Path $temporaryDirectory 'repair-sen2-agent-service-conflict.bound.ps1'
$innerSucceeded = $false
$innerFailure = $null
try {
    Write-Utf8NoBom -Path $boundPath -Value $boundSource
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $boundPath,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -gt 0) {
        $message = ($errors | ForEach-Object { $_.Message }) -join '; '
        throw "The deterministic bound repair source does not parse: $message"
    }

    & $boundPath `
        -RequestPath $RequestPath `
        -CredentialPath $CredentialPath `
        -OutputDirectory $OutputDirectory `
        -InitialWaitMinutes $InitialWaitMinutes `
        -StableSamples $StableSamples `
        -StableIntervalSeconds $StableIntervalSeconds
    $innerSucceeded = $true
}
catch {
    $innerFailure = [string]$_.Exception.Message
    throw
}
finally {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    }
    $sourceBytes = [System.Text.Encoding]::UTF8.GetBytes($source)
    $boundBytes = [System.Text.Encoding]::UTF8.GetBytes($boundSource)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $sourceSha = ([BitConverter]::ToString($sha256.ComputeHash($sourceBytes))).Replace('-', '').ToLowerInvariant()
        $boundSha = ([BitConverter]::ToString($sha256.ComputeHash($boundBytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
    [ordered]@{
        schemaVersion = '1.0'
        requestId = [string]$request.requestId
        bindingMode = 'deterministic-single-literal-replacement'
        originalExpectedServer = $legacyServer
        verifiedExpectedServer = $expectedServer
        replacementCount = $replacementCount
        authoritativeSourceSha256 = $sourceSha
        boundSourceSha256 = $boundSha
        innerRepairSucceeded = $innerSucceeded
        innerFailure = $innerFailure
        rke2DataDeleted = $false
        vmDiskWiped = $false
        vmReinstalled = $false
        credentialValuesWrittenToEvidence = $false
        eulaAutomaticallyAccepted = $false
        productionReleaseApproved = $false
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'rancherd-server-binding.json') -Encoding UTF8

    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
