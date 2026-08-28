# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$PatcherPath = (Join-Path $PSScriptRoot 'prepare-linux-vm-persistent-state-cert.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $PatcherPath)) { throw "Patcher not found: $PatcherPath" }

$patcher = Get-Content -Raw $PatcherPath
foreach ($required in @(
    'Expected exactly one Test-ThreeNodeLinstorResource function boundary',
    'TimeoutSeconds=600',
    'IntervalSeconds=10',
    'historyPath',
    'UpToDate',
    'Get-FileHash -Algorithm SHA256',
    'Parser]::ParseInput'
)) {
    if ($patcher -notmatch [regex]::Escape($required)) { throw "Patcher missing required safety marker: $required" }
}
if ($patcher -match "(?im)kubectl.*delete|linstor.*delete|storage-pool.*delete|physical-storage.*create") {
    throw 'Patcher must not contain destructive storage mutation commands'
}

$tempRoot = Join-Path $env:TEMP "layersentry-linstor-static-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $fixture = Join-Path $tempRoot 'runtime-test.ps1'
    $output = Join-Path $tempRoot 'patched-test.ps1'
    @'
function Invoke-NativeText { param([string]$FilePath,[string[]]$Arguments) }
function Test-ThreeNodeLinstorResource {
    param(
        [Parameter(Mandatory=$true)][string]$VolumeHandle,
        [Parameter(Mandatory=$true)][string[]]$NodeNames,
        [string]$EvidencePath=$null
    )
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('old-single-shot')
    if ($probe.ExitCode -ne 0) { throw 'old lookup failed' }
    $upToDateMatches = [regex]::Matches($probe.Text,'(?im)\bUpToDate\b')
    if ($upToDateMatches.Count -lt $NodeNames.Count) { throw 'old immediate failure' }
    return $true
}

if (-not (Test-Path $KubectlPath)) { throw "kubectl not found: $KubectlPath" }
'@ | Set-Content -Path $fixture -Encoding UTF8

    $fixtureHash = (Get-FileHash -Algorithm SHA256 $fixture).Hash.ToLowerInvariant()
    & $PatcherPath -RuntimeTestPath $fixture -OutputPath $output -ExpectedSha256 $fixtureHash
    if (-not $?) { throw 'Patcher fixture execution failed' }
    if (-not (Test-Path $output)) { throw 'Patcher did not produce output' }

    $patched = Get-Content -Raw $output
    if ($patched -match 'old-single-shot|old immediate failure') { throw 'Old immediate LINSTOR assertion survived patching' }
    foreach ($required in @(
        'do {',
        'Start-Sleep -Seconds $IntervalSeconds',
        'Get-Date) -lt $deadline',
        'missingNodes.Count -eq 0',
        'upToDateMatches.Count -ge $NodeNames.Count',
        '$EvidencePath.history.txt'
    )) {
        if ($patched -notmatch [regex]::Escape($required)) { throw "Patched fixture missing required convergence behavior: $required" }
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($output,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "Patched fixture parse failed: $($errors[0].Message)" }
} finally {
    Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
}

Write-Host "Linux VM persistent-state bounded LINSTOR certification static validation PASSED: $PatcherPath"
