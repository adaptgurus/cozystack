param([ValidateSet('Observe', 'Refresh', 'ProbeLogin', 'Login', 'Verify')][string]$Phase = 'Observe')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
Set-PSDebug -Off
$script:DcVmId = '29ba176b-b81a-4f47-8f51-ecec869f247f'
. (Join-Path $PSScriptRoot 'hyperv-console-keystrokes.ps1')

function Test-TrustDcUuid([string]$Value) {
    $parsed = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$parsed) -and $parsed -eq [Guid]$script:DcVmId
}

function Assert-TrustDcIdentity {
    if ($env:COMPUTERNAME -cne 'TESTSER') { throw 'TARGET_BINDING_FAILED' }
    $vms = @(Get-VM -Name 'sen' -ErrorAction Stop)
    if ($vms.Count -ne 1 -or -not (Test-TrustDcUuid ([string]$vms[0].Id)) -or
        [string]$vms[0].Name -cne 'sen' -or [string]$vms[0].State -cne 'Running') { throw 'TARGET_BINDING_FAILED' }
}

function New-TrustPrivateDirectory([string]$Path) {
    New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'PRIVATE_ACL_FAILED' }
}

function Read-TrustConsole([string]$Private) {
    Assert-TrustDcIdentity
    $started = Get-Date
    $folder = Join-Path $Private ([Guid]::NewGuid().ToString('N'))
    $script:TrustDiagnosticStage = 'CONSOLE_CAPTURE'
    & (Join-Path $PSScriptRoot 'capture-hyperv-console.ps1') -VmNames @('sen') -OutputDirectory $folder | Out-Null
    $script:TrustDiagnosticStage = 'CONSOLE_CAPTURE_REPORT'
    $report = Get-Content -LiteralPath (Join-Path $folder 'console-capture.json') -Raw | ConvertFrom-Json
    $rows = @($report.VirtualMachines)
    $image = Join-Path $folder 'sen-console.png'
    if ($report.Host -cne 'TESTSER' -or $report.CollectionMode -cne 'read-only-hyperv-console-thumbnail' -or
        $rows.Count -ne 1 -or $rows[0].Name -cne 'sen' -or $rows[0].State -cne 'Running' -or
        $rows[0].ConsoleCaptureStatus -cne 'Success' -or $rows[0].ConsoleImage -cne 'sen-console.png' -or
        -not (Test-Path -LiteralPath $image -PathType Leaf) -or (Get-Item -LiteralPath $image).Length -le 8) {
        throw 'CONSOLE_CAPTURE_FAILED'
    }
    $script:TrustDiagnosticStage = 'CONSOLE_OCR'
    $ocr = & (Join-Path $PSScriptRoot 'read-console-ocr.ps1') -ImagePath $image -ImageScale 2 | ConvertFrom-Json
    $script:TrustDiagnosticStage = 'CONSOLE_OCR_SHAPE'
    Assert-TrustDcIdentity
    $lines = @($ocr.lines | ForEach-Object { ([string]$_.text).Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0 -or $lines.Count -gt 128 -or ((Get-Date) - $started).TotalSeconds -gt 30) {
        throw 'CONSOLE_STATE_UNKNOWN_OR_EXPIRED'
    }
    # Exact public empty-login images manually reviewed from snapshots
    # 34046965347 and 34048637562. Arbitrary live captures remain private.
    $digest = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant()
    $knownPublic = $digest -cin @('6d4362bb6d0fe79b88ec077b24dbceadda16b75add5f173fc39642d4aaabe398',
        '2b397045222983268bf0807dbbe8db59ae7ab9cfa7e5588494939f0665ecdb8a')
    return [pscustomobject]@{ Lines = $lines; Image = $image; Started = $started; KnownPublicImage = $knownPublic; ImageSha256 = $digest; Ocr = $ocr }
}

function Get-TrustPrompt($View) {
    $lines = @($View.Lines)
    $last = $lines[-1]
    if ($last -cmatch '^\[root@layersentry\s+[^\r\n\]]+\]#\s*$') { return 'ROOT_SHELL' }
    if ($last -ceq '[root@layersentry' -and $null -ne $View.PSObject.Properties['Ocr']) {
        # Observe 34050853843 visually proved the complete empty root prompt;
        # OCR alone omitted its suffix. Bind to the exact bounded row pixels.
        $row = Export-TrustRootPromptCrop $View ([IO.Path]::GetDirectoryName($View.Image))
        if ($null -ne $row -and $row.sha256 -ceq 'cb0b9b7ee94a363233c9f84436a03f0e9ad3454d560621e0c87a3a76f7c997e9') { return 'ROOT_SHELL' }
    }
    if ($last -cmatch '^[Pp]assword:\s*$') { return 'PASSWORD_PROMPT' }
    # Exact OCR error proved by username-only run 34050130232. This alias
    # requires its reviewed public image and preceding root username; no fuzzy
    # matching or arbitrary UNKNOWN prompt can become a credential target.
    if ($last -ceq 'Passuord :' -and $lines.Count -ge 2 -and
        $lines[-2] -cmatch '^layersentry\s+login:\s+root\s*$' -and
        $null -ne $View.PSObject.Properties['ImageSha256'] -and
        $View.ImageSha256 -ceq '274d45c7f0fca8b8db796963c1c4c1675139c52480322f67af185909457c6bf0') { return 'PASSWORD_PROMPT' }
    if ($last -cmatch '^layersentry\s+login:\s*$') { return 'EMPTY_LOGIN' }
    if ($last -cmatch '^layersentry\s+login:\s+root\s*$') { return 'ROOT_USERNAME_ECHO' }
    # Exactly the observed empty login prompt followed only by kernel messages.
    $joined = $lines -join "`n"
    if ($joined -match '(?im)password\s*:|root@|[#\$]\s*$') { return 'UNKNOWN' }
    $prompts = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -cmatch '^layersentry\s+login:' })
    if ($prompts.Count -ne 1) { return 'UNKNOWN' }
    $index = $prompts[0]
    $tail = @($lines[$index] -creplace '^layersentry\s+login:\s*', '')
    if ($index -lt $lines.Count - 1) { $tail += $lines[($index + 1)..($lines.Count - 1)] }
    $kernel = @($tail | Where-Object { $_ })
    if ($kernel.Count -gt 0 -and @($kernel | Where-Object { $_ -cnotmatch '^\[\s*[0-9]+(?:\.[0-9]+)?\]\s+\S.*$' }).Count -eq 0) {
        return 'LOGIN_WITH_KERNEL_OUTPUT'
    }
    return 'UNKNOWN'
}

function Get-TrustKeyboard {
    Assert-TrustDcIdentity
    $systems = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName 'Msvm_ComputerSystem' -Filter "Name='$script:DcVmId'" -ErrorAction Stop)
    if ($systems.Count -ne 1 -or -not (Test-TrustDcUuid ([string]$systems[0].Name)) -or $systems[0].ElementName -cne 'sen') { throw 'KEYBOARD_BINDING_FAILED' }
    $keyboards = @(Get-CimAssociatedInstance -InputObject $systems[0] -ResultClassName 'Msvm_Keyboard' -ErrorAction Stop)
    if ($keyboards.Count -ne 1 -or -not (Test-TrustDcUuid ([string]$keyboards[0].SystemName)) -or
        $keyboards[0].CreationClassName -cne 'Msvm_Keyboard') { throw 'KEYBOARD_BINDING_FAILED' }
    return $keyboards[0]
}

function Get-TrustPromptDiagnostics($View) {
    # Never return arbitrary credential-phase text. Only fixed username/host
    # spellings plus a small punctuation alphabet may form a prompt candidate.
    $candidates = @($View.Lines | Where-Object {
        $_.Length -le 80 -and $_ -cmatch '^[\[\](){|Il1 ]*root[@][l1I]ayersentry[ ~_\-\[\]{}()|Il1#]*$'
    })
    return [ordered]@{
        rootPromptCandidates = $candidates
        loginRejectedMessage = @($View.Lines | Where-Object { $_ -cmatch '^[Ll]ogin\s+incorrect[.!]?$' }).Count -gt 0
        rootAndHostRecognized = @($View.Lines | Where-Object { $_ -cmatch 'root' -and $_ -cmatch '[l1I]ayersentry' }).Count -gt 0
    }
}

function Export-TrustRootPromptCrop($View, [string]$Out) {
    # Publish at most one short terminal row, never the credential/history frame.
    $roots = @($View.Ocr.lines | Where-Object { $_.text -ceq '[root@layersentry' })
    if ($roots.Count -ne 1) { return $null }
    $root = $roots[0]
    $top = ($root.words | ForEach-Object { $_.boundingRect.y } | Measure-Object -Minimum).Minimum
    $bottom = ($root.words | ForEach-Object { $_.boundingRect.y + $_.boundingRect.height } | Measure-Object -Maximum).Maximum
    $left = ($root.words | ForEach-Object { $_.boundingRect.x } | Measure-Object -Minimum).Minimum
    $right = ($root.words | ForEach-Object { $_.boundingRect.x + $_.boundingRect.width } | Measure-Object -Maximum).Maximum
    if ($left -gt 16 -or $right -gt 350 -or $top -lt 0 -or $bottom - $top -gt 40) { return $null }
    foreach ($line in $View.Ocr.lines) {
        if ($line.text -ceq '[root@layersentry') { continue }
        $y = ($line.words | ForEach-Object { $_.boundingRect.y } | Measure-Object -Minimum).Minimum
        $end = ($line.words | ForEach-Object { $_.boundingRect.y + $_.boundingRect.height } | Measure-Object -Maximum).Maximum
        if ($y -lt $bottom -and $end -gt $top -and $line.text -cnotmatch '^[ ~_\-\[\]{}()|Il1#]*$') { return $null }
    }
    Add-Type -AssemblyName System.Drawing
    $bitmap = [Drawing.Bitmap]::new($View.Image)
    $crop = $null
    try {
        # OCR used 2x scaling; map its visible glyph bounds to original pixels.
        $y = [Math]::Max(0, [int][Math]::Floor($top / 2) - 2)
        $height = [Math]::Min(24, [int][Math]::Ceiling($bottom / 2) - $y + 3)
        if ($y + $height -gt $bitmap.Height -or $bitmap.Width -lt 192) { return $null }
        $rectangle = [Drawing.Rectangle]::new(0, $y, 192, $height)
        $crop = $bitmap.Clone($rectangle, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $path = Join-Path $Out 'public-root-prompt-row.png'
        $crop.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        return [ordered]@{ sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); width=192; height=$height }
    } finally {
        if ($null -ne $crop) { $crop.Dispose() }
        $bitmap.Dispose()
    }
}

function Send-TrustText($Keyboard, [string]$Text) {
    # Linux rejected TypeText as unknown ASCII scan codes. Use the existing
    # reviewed US virtual-key mapping; no input, key codes or errors are logged.
    if ($Text.Length -eq 0 -or $Text.Length -gt 3500 -or $Text -match '[^\x20-\x7e]') { throw 'INPUT_FORMAT_REFUSED' }
    $strokes = @($Text.ToCharArray() | ForEach-Object { Get-CharacterStroke $_ })
    foreach ($stroke in $strokes) {
        try {
            if ($stroke.Shift) { Send-TrustVirtualKey $Keyboard 'PressKey' 16 }
            Send-TrustVirtualKey $Keyboard 'TypeKey' ([uint32]$stroke.Code)
        }
        finally {
            # Release only the modifier owned by this operation; never replay a
            # character or Enter after an uncertain key result.
            if ($stroke.Shift) { Send-TrustVirtualKey $Keyboard 'ReleaseKey' 16 }
        }
    }
}

function Send-TrustVirtualKey($Keyboard, [string]$Method, [uint32]$Code) {
    Assert-TrustDcIdentity
    $result = Invoke-CimMethod -InputObject $Keyboard -MethodName $Method -Arguments @{ keyCode = $Code } -ErrorAction Stop
    if ([uint32]$result.ReturnValue -ne 0) { throw 'INPUT_OUTCOME_UNKNOWN_NO_REPLAY' }
}

function Send-TrustEnter($Keyboard) {
    Assert-TrustDcIdentity
    $result = Invoke-CimMethod -InputObject $Keyboard -MethodName TypeKey -Arguments @{ keyCode = [uint32]13 } -ErrorAction Stop
    if ([uint32]$result.ReturnValue -ne 0) { throw 'INPUT_OUTCOME_UNKNOWN_NO_REPLAY' }
}

function Wait-TrustPrompt([string]$Private, [string]$Expected) {
    $until = (Get-Date).AddSeconds(20)
    do {
        $view = Read-TrustConsole $Private
        if ((Get-TrustPrompt $view) -eq $Expected) { return $view }
        # Observe the console event; never repeat keyboard input.
        # TODO(e2e-replace-fixed-timeouts): Hyper-V thumbnail API has no prompt event.
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $until)
    throw 'CONSOLE_TRANSITION_NOT_OBSERVED_NO_REPLAY'
}

function Get-TrustCandidate {
    # Discovery only: never use this result for password SSH before OOB binding.
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $rows = @(& ssh-keyscan.exe -4 -T 8 -t ed25519 10.10.10.14 2>$null); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $oldPreference }
    $keys = @($rows | Where-Object { $_ -cmatch '^10\.10\.10\.14 ssh-ed25519 [A-Za-z0-9+/]{68}$' } | Select-Object -Unique)
    if ($code -ne 0 -or $keys.Count -ne 1) { throw 'UNTRUSTED_CANDIDATE_UNAVAILABLE' }
    $key = $keys[0].Substring('10.10.10.14 '.Length)
    $blob = [Convert]::FromBase64String($key.Split(' ')[1])
    if ($blob.Length -ne 51 -or [BitConverter]::ToString($blob[0..3]) -cne '00-00-00-0B' -or
        [Text.Encoding]::ASCII.GetString($blob, 4, 11) -cne 'ssh-ed25519' -or
        [BitConverter]::ToString($blob[15..18]) -cne '00-00-00-20') { throw 'INVALID_CANDIDATE_KEY' }
    return $key
}

function New-TrustChallenge {
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function New-TrustGuestCommand([string]$Candidate, [string]$Challenge) {
    if ($Candidate -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]{68}$' -or $Challenge -cnotmatch '^[a-f0-9]{32}$') { throw 'INVALID_TRUST_CHALLENGE' }
    # Fixed read-only program. Its encoded shell input contains no plain verdict
    # marker, so echoed input cannot be mistaken for executed challenge output.
    $payload = @'
import json, os, stat, subprocess
candidate = 'CANDIDATE'
challenge = 'CHALLENGE'
try:
    assert os.geteuid() == 0
    rows = json.loads(subprocess.run(['/usr/sbin/ip','-j','-4','address','show'],check=True,capture_output=True,text=True,timeout=5).stdout)
    assert any(a.get('local') == '10.10.10.14' for r in rows for a in r.get('addr_info',[]))
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for name in ('etc', 'ssh'):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
            info = os.fstat(directory)
            assert info.st_uid == 0 and not info.st_mode & 0o022
        keyfd = os.open('ssh_host_ed25519_key.pub', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        try:
            info = os.fstat(keyfd)
            assert stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022
            raw = os.read(keyfd, 1025)
            assert len(raw) < 1024
        finally:
            os.close(keyfd)
    finally:
        os.close(directory)
    key = ' '.join(raw.decode('ascii').split()[:2])
    assert key == candidate
    print('\033[2J\033[H', end='')
    print('LS-DC-' + challenge + '-BEGIN')
    print('TARGET 10.10.10.14 ROOT KEY MATCH')
    print('LS-DC-' + challenge + '-END')
except Exception:
    print('DC HOST KEY VERIFICATION FAILED')
'@
    $payload = $payload.Replace('CANDIDATE', $Candidate).Replace('CHALLENGE', $Challenge)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($payload))
    return "/usr/bin/printf '%s' '$encoded' | /usr/bin/base64 -d | /usr/bin/python3 -I -"
}

function Assert-TrustPublicReceipt($View, [string]$Candidate, [string]$Challenge) {
    $expected = @("LS-DC-$Challenge-BEGIN", 'TARGET 10.10.10.14 ROOT KEY MATCH', "LS-DC-$Challenge-END")
    $lines = @($View.Lines)
    # After the guest clears its screen, only approved public output and the
    # empty root prompt may be retained. Unknown/extra content fails closed.
    if ($lines.Count -ne 4 -or (Get-TrustPrompt $View) -ne 'ROOT_SHELL') { throw 'PUBLIC_RECEIPT_NOT_VERIFIED' }
    for ($i = 0; $i -lt 3; $i++) {
        if ($lines[$i] -cne $expected[$i]) { throw 'PUBLIC_RECEIPT_NOT_VERIFIED' }
    }
}

function Invoke-DcTrustPhase([string]$Phase) {
    $script:TrustDiagnosticStage = 'TARGET_IDENTITY'
    $private = Join-Path $env:RUNNER_TEMP ('dc-trust-private-' + [Guid]::NewGuid().ToString('N'))
    $out = Join-Path $env:RUNNER_TEMP "layersentry-dc-trust-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
    $state = [ordered]@{ schema = 1; phase = $Phase; target = '10.10.10.14'; vmId = $script:DcVmId;
        runnerCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT;
        status = 'PENDING'; stage = 'TARGET_IDENTITY'; inputAttempted = $false; passwordSent = $false; hostTrustEstablished = $false;
        guestConfigurationChanged = $false; sshAuthenticationAttempted = $false }
    try {
        Import-Module Hyper-V -ErrorAction Stop
        Assert-TrustDcIdentity
        $state.stage = 'PRIVATE_CONSOLE_OBSERVATION'
        $script:TrustDiagnosticStage = 'PRIVATE_ACL'
        New-TrustPrivateDirectory $private
        $view = Read-TrustConsole $private
        $prompt = Get-TrustPrompt $view
        $state['initialPrompt'] = $prompt
        if ($Phase -eq 'Observe') {
            $state['promptDiagnostics'] = Get-TrustPromptDiagnostics $view
            if ($prompt -eq 'UNKNOWN' -and $state.promptDiagnostics.rootPromptCandidates -contains '[root@layersentry') {
                $state['rootPromptRow'] = Export-TrustRootPromptCrop $view $out
            }
            if ($view.KnownPublicImage) { $state['reviewedPublicImageOcrLines'] = @($view.Lines) }
            # Public identity/count diagnostics only; never invoke keyboard methods.
            $systems = @(Get-CimInstance -Namespace 'root/virtualization/v2' -ClassName 'Msvm_ComputerSystem' -Filter "Name='$script:DcVmId'" -ErrorAction Stop)
            $ids = @($systems | ForEach-Object { [ordered]@{ name = [string]$_.Name; elementName = [string]$_.ElementName } })
            $keys = @()
            if ($systems.Count -eq 1) {
                $keys = @(Get-CimAssociatedInstance -InputObject $systems[0] -ResultClassName 'Msvm_Keyboard' -ErrorAction Stop |
                    ForEach-Object { [ordered]@{ systemName = [string]$_.SystemName; creationClassName = [string]$_.CreationClassName } })
            }
            $state['keyboardIdentity'] = [ordered]@{ systems = $ids; keyboards = $keys }
            $state.status = 'OBSERVED'; return
        }
        if ($Phase -eq 'Refresh') {
            # This separate phase can only dismiss the exact reviewed empty
            # login plus kernel-output image; it never enters a username/password.
            if (-not $view.KnownPublicImage) { throw 'REVIEWED_EMPTY_LOGIN_IMAGE_REQUIRED' }
            $keyboard = Get-TrustKeyboard
            if (((Get-Date) - $view.Started).TotalSeconds -gt 30) { throw 'LOGIN_PROMPT_EXPIRED' }
            $state['reviewedImageSha256'] = $view.ImageSha256
            $state.stage = 'REVIEWED_LOGIN_SINGLE_ENTER'
            $state.inputAttempted = $true
            Send-TrustEnter $keyboard
            $null = Wait-TrustPrompt $private 'EMPTY_LOGIN'
            $state.status = 'EMPTY_LOGIN_REFRESHED_NO_CREDENTIAL_INPUT'
            return
        }
        if ($Phase -in @('Login', 'ProbeLogin')) {
            if ($prompt -eq 'ROOT_SHELL') { $state.status = 'ALREADY_AUTHENTICATED'; return }
            if ($prompt -notin @('EMPTY_LOGIN', 'LOGIN_WITH_KERNEL_OUTPUT')) { throw 'FRESH_EMPTY_LOGIN_REQUIRED' }
            if ($env:DC_HOST -cne '10.10.10.14' -or $env:DC_USER -cne 'root' -or
                [string]::IsNullOrEmpty($env:DC_PASSWORD) -or $env:DC_PASSWORD.Length -gt 128 -or $env:DC_PASSWORD -match '[^\x20-\x7e]') {
                throw 'CREDENTIAL_BINDING_OR_FORMAT_FAILED'
            }
            $keyboard = Get-TrustKeyboard
            if (((Get-Date) - $view.Started).TotalSeconds -gt 30) { throw 'LOGIN_PROMPT_EXPIRED' }
            if ($prompt -eq 'LOGIN_WITH_KERNEL_OUTPUT') {
                $state.stage = 'LOGIN_PROMPT_REFRESH'
                $state.inputAttempted = $true
                Send-TrustEnter $keyboard
                $view = Wait-TrustPrompt $private 'EMPTY_LOGIN'
            }
            $state.inputAttempted = $true
            $state.stage = 'USERNAME_INPUT'
            Send-TrustText $keyboard 'root'
            $state['usernameInputCompletedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            $state.stage = 'USERNAME_ECHO_OBSERVATION'
            if ($Phase -eq 'ProbeLogin') {
                $view = Read-TrustConsole $private
                Copy-Item -LiteralPath $view.Image -Destination (Join-Path $out 'public-username-after-keys.png') -ErrorAction Stop
                $state['usernameImmediatePrompt'] = Get-TrustPrompt $view
                $state['usernameImmediateOcrLines'] = @($view.Lines)
                $state['usernameObservationUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            }
            $null = Wait-TrustPrompt $private 'ROOT_USERNAME_ECHO'
            $state['usernameEchoVerified'] = $true
            $state.stage = 'USERNAME_ENTER'
            Send-TrustEnter $keyboard
            $state['usernameEnterCompletedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            $state.stage = 'PASSWORD_PROMPT_OBSERVATION'
            if ($Phase -eq 'ProbeLogin') {
                $view = Read-TrustConsole $private
                Copy-Item -LiteralPath $view.Image -Destination (Join-Path $out 'public-username-after-enter.png') -ErrorAction Stop
                $state['afterUsernameEnterPrompt'] = Get-TrustPrompt $view
                $state['afterUsernameEnterOcrLines'] = @($view.Lines)
                $state['afterUsernameEnterObservationUtc'] = (Get-Date).ToUniversalTime().ToString('o')
            }
            $view = Wait-TrustPrompt $private 'PASSWORD_PROMPT'
            $state['freshPasswordPromptVerified'] = $true
            if ($Phase -eq 'ProbeLogin') {
                # Only the public username has been sent during this phase.
                Copy-Item -LiteralPath $view.Image -Destination (Join-Path $out 'public-username-password-prompt.png') -ErrorAction Stop
                $state['imageSha256'] = (Get-FileHash -LiteralPath (Join-Path $out 'public-username-password-prompt.png') -Algorithm SHA256).Hash.ToLowerInvariant()
                $state.status = 'USERNAME_DELIVERY_VERIFIED_NO_PASSWORD_INPUT'
                return
            }
            $state.stage = 'PASSWORD_INPUT'
            Assert-TrustDcIdentity
            if (((Get-Date) - $view.Started).TotalSeconds -gt 30) { throw 'PASSWORD_PROMPT_EXPIRED' }
            Send-TrustText $keyboard $env:DC_PASSWORD
            $state.passwordSent = $true
            Send-TrustEnter $keyboard
            $null = Wait-TrustPrompt $private 'ROOT_SHELL'
            $state.status = 'AUTHENTICATED_AWAITING_PUBLIC_KEY_PHASE'
            return
        }
        if ($Phase -ne 'Verify' -or $prompt -ne 'ROOT_SHELL') { throw 'VERIFIED_ROOT_PROMPT_REQUIRED' }
        $state.stage = 'UNTRUSTED_KEY_CANDIDATE'
        $candidate = Get-TrustCandidate
        $challenge = New-TrustChallenge
        $command = New-TrustGuestCommand $candidate $challenge
        # Re-check the fresh root prompt after the network-only candidate read.
        $view = Read-TrustConsole $private
        if ((Get-TrustPrompt $view) -ne 'ROOT_SHELL') { throw 'ROOT_PROMPT_CHANGED' }
        $keyboard = Get-TrustKeyboard
        if (((Get-Date) - $view.Started).TotalSeconds -gt 30) { throw 'ROOT_PROMPT_EXPIRED' }
        $state.inputAttempted = $true
        $state.stage = 'PUBLIC_KEY_CHALLENGE_INPUT'
        Send-TrustText $keyboard $command
        Send-TrustEnter $keyboard
        $state.stage = 'PUBLIC_KEY_CONSOLE_PROOF'
        $until = (Get-Date).AddSeconds(20)
        $verified = $false
        do {
            $view = Read-TrustConsole $private
            try { Assert-TrustPublicReceipt $view $candidate $challenge; $verified = $true } catch { }
            if ($verified) { break }
            # TODO(e2e-replace-fixed-timeouts): Hyper-V offers thumbnails, not terminal-output events.
            Start-Sleep -Milliseconds 250
        } while ((Get-Date) -lt $until)
        if (-not $verified) { throw 'OOB_PUBLIC_KEY_PROOF_NOT_VERIFIED' }
        Copy-Item -LiteralPath $view.Image -Destination (Join-Path $out 'public-host-key-console.png') -ErrorAction Stop
        [IO.File]::WriteAllText((Join-Path $out 'verified_known_hosts'), "10.10.10.14 $candidate`n", [Text.UTF8Encoding]::new($false))
        $state['challenge'] = $challenge
        $state['imageSha256'] = (Get-FileHash -LiteralPath (Join-Path $out 'public-host-key-console.png') -Algorithm SHA256).Hash.ToLowerInvariant()
        $state.hostTrustEstablished = $true
        $state.status = 'OOB_HOST_KEY_VERIFIED'
    } catch {
        # Never serialize raw exceptions: CIM errors may contain keyboard input.
        $state['diagnosticStage'] = $script:TrustDiagnosticStage
        $state['exceptionType'] = $_.Exception.GetType().FullName
        $codes = @()
        $exception = $_.Exception
        for ($depth = 0; $depth -lt 5 -and $null -ne $exception; $depth++) {
            $codes += [ordered]@{ type = $exception.GetType().FullName; hresult = ('0x{0:X8}' -f $exception.HResult) }
            $exception = $exception.InnerException
        }
        $state['exceptionCodes'] = $codes
        $safeCodes = @('PRIVATE_ACL_FAILED', 'TARGET_BINDING_FAILED', 'CONSOLE_CAPTURE_FAILED',
            'CONSOLE_STATE_UNKNOWN_OR_EXPIRED', 'FRESH_EMPTY_LOGIN_REQUIRED', 'KEYBOARD_BINDING_FAILED',
            'INPUT_FORMAT_REFUSED', 'INPUT_OUTCOME_UNKNOWN_NO_REPLAY', 'CONSOLE_TRANSITION_NOT_OBSERVED_NO_REPLAY',
            'CREDENTIAL_BINDING_OR_FORMAT_FAILED', 'PASSWORD_PROMPT_EXPIRED', 'LOGIN_PROMPT_EXPIRED',
            'VERIFIED_ROOT_PROMPT_REQUIRED', 'UNTRUSTED_CANDIDATE_UNAVAILABLE', 'INVALID_CANDIDATE_KEY',
            'REVIEWED_EMPTY_LOGIN_IMAGE_REQUIRED',
            'ROOT_PROMPT_CHANGED', 'ROOT_PROMPT_EXPIRED', 'OOB_PUBLIC_KEY_PROOF_NOT_VERIFIED')
        if ($_.Exception.Message -cin $safeCodes) { $state['reason'] = $_.Exception.Message }
        $state.status = 'PHASE_FAILED_NO_REPLAY'
        throw 'DC console trust phase failed; inspect sanitized summary, never replay uncertain input.'
    } finally {
        $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'summary.json') -Encoding UTF8
        Remove-Item Env:DC_PASSWORD -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-DcTrustPhase -Phase $Phase }
