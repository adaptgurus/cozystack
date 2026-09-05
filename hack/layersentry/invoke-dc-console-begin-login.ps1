$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedId = '29ba176b-b81a-4f47-8f51-ecec869f247f'
$out = Join-Path $env:RUNNER_TEMP "layersentry-dc-begin-login-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$state = [ordered]@{
    action = 'BeginLogin'; expectedHost = 'TESTSER'; vmName = 'sen'; vmId = $expectedId
    runnerCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT
    status = 'TARGET_BINDING_FAILED'; beforeCaptured = $false; afterCaptured = $false
    loginPromptVerified = $false; inputAttempted = $false; usernameSent = $false; enterSent = $false
    passwordSent = $false; guestConfigChanged = $false; mutationPerformed = $false
}

function Assert-DcIdentity {
    if ($env:COMPUTERNAME -cne 'TESTSER') { throw 'Host mismatch.' }
    $vms = @(Get-VM -Name 'sen' -ErrorAction Stop)
    if ($vms.Count -ne 1 -or [string]$vms[0].Id -cne $expectedId -or [string]$vms[0].Name -cne 'sen' -or [string]$vms[0].State -cne 'Running') {
        throw 'DC identity/state mismatch.'
    }
}

function Capture-DcConsole([string]$Phase) {
    Assert-DcIdentity
    $directory = Join-Path $out ($Phase + '-' + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $directory) { throw 'Capture path already exists.' }
    & (Join-Path $PSScriptRoot 'capture-hyperv-console.ps1') -VmNames @('sen') -OutputDirectory $directory | Out-Null
    $report = Get-Content -LiteralPath (Join-Path $directory 'console-capture.json') -Raw | ConvertFrom-Json
    $rows = @($report.VirtualMachines)
    $image = Join-Path $directory 'sen-console.png'
    if ($report.Host -cne 'TESTSER' -or $report.CollectionMode -cne 'read-only-hyperv-console-thumbnail' -or
        $rows.Count -ne 1 -or $rows[0].Name -cne 'sen' -or $rows[0].State -cne 'Running' -or
        $rows[0].ConsoleCaptureStatus -cne 'Success' -or $rows[0].ConsoleImage -cne 'sen-console.png' -or
        -not (Test-Path -LiteralPath $image -PathType Leaf) -or (Get-Item -LiteralPath $image).Length -le 8) {
        throw 'Requested console capture failed.'
    }
    Assert-DcIdentity
    $state[$Phase + 'Captured'] = $true
    $state[$Phase + 'ImageSha256'] = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()
    return $image
}

try {
    if ($env:COMPUTERNAME -cne 'TESTSER') { throw 'Host mismatch.' }
    Import-Module Hyper-V -ErrorAction Stop
    Assert-DcIdentity
    $state.status = 'BEFORE_CAPTURE_FAILED'
    $captureStarted = Get-Date
    $before = Capture-DcConsole 'before'
    $state.status = 'LOGIN_PROMPT_NOT_VERIFIED'
    $ocr = & (Join-Path $PSScriptRoot 'read-console-ocr.ps1') -ImagePath $before | ConvertFrom-Json
    $lines = @($ocr.lines | ForEach-Object { ([string]$_.text).Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0 -or $lines[-1] -cnotmatch '^layersentry\s+login:\s*$' -or
        ([string]$ocr.text) -match '(?i)password\s*:|\[root@|root@.*[#\$]' -or
        ((Get-Date) - $captureStarted).TotalSeconds -gt 30) {
        throw 'Fresh console is not an unambiguous empty layersentry login prompt.'
    }
    $state.loginPromptVerified = $true
    Assert-DcIdentity
    $state.status = 'KEYBOARD_BINDING_FAILED'
    # Resolve the keyboard by immutable VM ID, not a name-only WMI lookup.
    $systems = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName 'Msvm_ComputerSystem' -Filter "Name='$expectedId'" -ErrorAction Stop)
    if ($systems.Count -ne 1 -or [string]$systems[0].Name -cne $expectedId -or $systems[0].ElementName -cne 'sen') { throw 'CIM DC binding failed.' }
    $keyboards = @(Get-CimAssociatedInstance -InputObject $systems[0] -ResultClassName 'Msvm_Keyboard' -ErrorAction Stop)
    if ($keyboards.Count -ne 1) { throw 'Expected exactly one DC keyboard.' }
    $state.status = 'LOGIN_PROMPT_EXPIRED'
    if (((Get-Date) - $captureStarted).TotalSeconds -gt 30) { throw 'Login prompt evidence expired.' }
    Assert-DcIdentity
    $state.status = 'INPUT_OUTCOME_UNKNOWN'
    $state.inputAttempted = $true
    $state.mutationPerformed = $true
    # Only these two literal operations are authorized. Never retry either.
    $typed = Invoke-CimMethod -InputObject $keyboards[0] -MethodName TypeText -Arguments @{ asciiText = 'root' } -ErrorAction Stop
    if ([uint32]$typed.ReturnValue -ne 0) { throw 'Username typing was not confirmed.' }
    $state.usernameSent = $true
    $entered = Invoke-CimMethod -InputObject $keyboards[0] -MethodName TypeKey -Arguments @{ keyCode = [uint32]13 } -ErrorAction Stop
    if ([uint32]$entered.ReturnValue -ne 0) { throw 'Enter was not confirmed.' }
    $state.enterSent = $true
    $state.status = 'USERNAME_SENT_AWAITING_CONSOLE_REVIEW'
} catch {
    throw "DC BeginLogin stopped: $($state.status)."
} finally {
    if ($state.inputAttempted) {
        try { [void](Capture-DcConsole 'after') }
        catch { $state.status = 'AFTER_CAPTURE_FAILED_INPUT_OUTCOME_REQUIRES_REVIEW' }
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
    if ($state.inputAttempted -and -not $state.afterCaptured) { throw 'After-input console evidence is missing; do not retry input.' }
}
