# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RuntimeTestPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$ExpectedSha256 = '02e9e48c73bcca59cc0e6f59daa25d2c8a0903714f7d71832ebb97f2b7592f26'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RuntimeTestPath)) { throw "Runtime Linux VM test not found: $RuntimeTestPath" }
if (-not $ExpectedSha256 -or $ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'ExpectedSha256 must be a 64-character SHA256 value' }

$actualSha256 = (Get-FileHash -Algorithm SHA256 $RuntimeTestPath).Hash.ToLowerInvariant()
if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "Pinned runtime Linux VM test hash mismatch: expected=$ExpectedSha256 actual=$actualSha256"
}

$source = Get-Content -Raw $RuntimeTestPath
$pattern = '(?s)function Test-ThreeNodeLinstorResource \{.*?\r?\n\}\r?\n\r?\nif \(-not \(Test-Path \$KubectlPath\)\)'
$matches = [regex]::Matches($source,$pattern)
if ($matches.Count -ne 1) {
    throw "Expected exactly one Test-ThreeNodeLinstorResource function boundary; found $($matches.Count)"
}

$replacement = @'
function Test-ThreeNodeLinstorResource {
    param(
        [Parameter(Mandatory=$true)][string]$VolumeHandle,
        [Parameter(Mandatory=$true)][string[]]$NodeNames,
        [string]$EvidencePath=$null,
        [int]$TimeoutSeconds=600,
        [int]$IntervalSeconds=10
    )

    # CDI reports a cloned DataVolume as Succeeded before a newly-created DRBD
    # resource is guaranteed to have completed three-way synchronization. Keep
    # the production requirement strict (all expected nodes + UpToDate on every
    # replica), but give LINSTOR a bounded convergence window and persist every
    # raw observation so a genuine storage fault remains diagnosable.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastProbe = $null
    $lastMissingNodes = @()
    $lastUpToDateCount = 0
    $historyPath = if ($EvidencePath) { "$EvidencePath.history.txt" } else { $null }
    if ($historyPath) { Remove-Item -Force $historyPath -ErrorAction SilentlyContinue }

    do {
        $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @(
            'exec','-n','cozy-linstor','deploy/linstor-controller','--',
            'linstor','resource','list','--resources',$VolumeHandle
        )
        $lastProbe = $probe

        if ($EvidencePath) {
            $probe.Text | Set-Content -Path $EvidencePath -Encoding UTF8
            @(
                "===== $([DateTimeOffset]::UtcNow.ToString('o')) exit=$($probe.ExitCode) =====",
                $probe.Text,
                ''
            ) | Add-Content -Path $historyPath -Encoding UTF8
        }

        if ($probe.ExitCode -eq 0 -and $probe.Text -match [regex]::Escape($VolumeHandle)) {
            $missingNodes = New-Object System.Collections.Generic.List[string]
            foreach ($nodeName in $NodeNames) {
                if ($probe.Text -notmatch [regex]::Escape($nodeName)) { $missingNodes.Add($nodeName) }
            }
            $upToDateMatches = [regex]::Matches($probe.Text,'(?im)\bUpToDate\b')
            $lastMissingNodes = @($missingNodes)
            $lastUpToDateCount = $upToDateMatches.Count
            if ($missingNodes.Count -eq 0 -and $upToDateMatches.Count -ge $NodeNames.Count) {
                return $true
            }
        }

        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)

    if ($null -eq $lastProbe) { throw "LINSTOR resource lookup produced no observation for $VolumeHandle" }
    if ($lastProbe.ExitCode -ne 0) {
        throw "LINSTOR resource lookup failed to converge for ${VolumeHandle}: $($lastProbe.Text)"
    }
    if ($lastProbe.Text -notmatch [regex]::Escape($VolumeHandle)) {
        throw "LINSTOR output never identified expected resource $VolumeHandle within ${TimeoutSeconds}s"
    }
    if ($lastMissingNodes.Count -gt 0) {
        throw "LINSTOR resource $VolumeHandle did not converge onto all expected nodes within ${TimeoutSeconds}s; missing=$($lastMissingNodes -join ',')"
    }
    throw "LINSTOR resource $VolumeHandle did not reach UpToDate on all expected replicas within ${TimeoutSeconds}s; observed=$lastUpToDateCount expected=$($NodeNames.Count)"
}

if (-not (Test-Path $KubectlPath))
'@

$patched = [regex]::Replace($source,$pattern,$replacement,1)
if ($patched -eq $source) { throw 'Runtime Linux VM test was not patched' }
if ([regex]::Matches($patched,'function Test-ThreeNodeLinstorResource \{').Count -ne 1) {
    throw 'Patched runtime Linux VM test does not contain exactly one LINSTOR validation function'
}
if ($patched -notmatch 'TimeoutSeconds=600' -or $patched -notmatch 'historyPath' -or $patched -notmatch '\\bUpToDate\\b') {
    throw 'Patched runtime Linux VM test is missing bounded convergence/evidence guards'
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($patched,[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) {
    throw "Patched runtime Linux VM test PowerShell parse failed: $($errors[0].Message)"
}

$parent = Split-Path -Parent $OutputPath
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
Set-Content -Path $OutputPath -Value $patched -Encoding UTF8
Write-Host "Prepared bounded persistent-state Linux VM certification test: source_sha256=$actualSha256 output=$OutputPath"
