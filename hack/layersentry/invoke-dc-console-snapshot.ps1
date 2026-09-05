$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedId = '29ba176b-b81a-4f47-8f51-ecec869f247f'
$out = Join-Path $env:RUNNER_TEMP "layersentry-dc-console-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$state = [ordered]@{
    expectedHost = 'TESTSER'; vmName = 'sen'; vmId = $expectedId
    runnerCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT
    captureAttempted = $false; captureSucceeded = $false; status = 'PENDING'
    guestInputPerformed = $false; mutationPerformed = $false
}

function Assert-DcIdentity {
    if ($env:COMPUTERNAME -cne 'TESTSER') { throw 'Host mismatch.' }
    $vms = @(Get-VM -Name 'sen' -ErrorAction Stop)
    if ($vms.Count -ne 1 -or [string]$vms[0].Id -cne $expectedId -or [string]$vms[0].Name -cne 'sen' -or [string]$vms[0].State -cne 'Running') {
        throw 'DC VM identity or state mismatch.'
    }
}

try {
    $state.status = 'TARGET_BINDING_FAILED'
    if ($env:COMPUTERNAME -cne 'TESTSER') { throw 'Host mismatch.' }
    Import-Module Hyper-V -ErrorAction Stop
    Assert-DcIdentity
    # The reused helper clears its output path; give it a fresh child only.
    $capture = Join-Path $out ([Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $capture) { throw 'Capture path already exists.' }
    $state.status = 'CAPTURE_FAILED'
    $state.captureAttempted = $true
    & (Join-Path $PSScriptRoot 'capture-hyperv-console.ps1') -VmNames @('sen') -OutputDirectory $capture
    $reportPath = Join-Path $capture 'console-capture.json'
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'Capture report missing.' }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $rows = @($report.VirtualMachines)
    if ($report.Host -cne 'TESTSER' -or $report.CollectionMode -cne 'read-only-hyperv-console-thumbnail' -or
        $rows.Count -ne 1 -or $rows[0].Name -cne 'sen' -or $rows[0].State -cne 'Running' -or
        $rows[0].ConsoleCaptureStatus -cne 'Success' -or $rows[0].ConsoleImage -cne 'sen-console.png' -or
        $rows[0].ConsoleWidth -le 0 -or $rows[0].ConsoleHeight -le 0) {
        throw 'Capture report did not prove the requested DC snapshot.'
    }
    $png = Join-Path $capture 'sen-console.png'
    if (-not (Test-Path -LiteralPath $png -PathType Leaf) -or (Get-Item -LiteralPath $png).Length -le 8) {
        throw 'Capture image missing or empty.'
    }
    Assert-DcIdentity
    $state['imageSha256'] = (Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash.ToLowerInvariant()
    $state['imagePath'] = (Split-Path -Leaf $capture) + '/sen-console.png'
    $state.captureSucceeded = $true
    $state.status = 'CAPTURED'
} catch {
    throw "DC console snapshot failed: $($state.status)."
} finally {
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
}
