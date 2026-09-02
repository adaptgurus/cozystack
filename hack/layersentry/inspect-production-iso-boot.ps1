[CmdletBinding()]
param(
    [string]$IsoPath = 'C:\Users\opc\Downloads\final iso\layersentry-v1.0-harvester-v1.8.2-production-build.iso',
    [string]$PersistentPlanPath = 'C:\ProgramData\LayerSentry\production-install\iso-boot-plan.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-production-iso-boot-inspection')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LowerHash {
    param([string]$Path, [ValidateSet('SHA256','SHA512')][string]$Algorithm)
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
}

function Read-SidecarValue {
    param([string]$Path, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required sidecar is missing: $Path"
    }
    $text = (Get-Content -LiteralPath $Path -Raw -Encoding ASCII).Trim()
    $match = [regex]::Match($text, $Pattern)
    if (-not $match.Success) {
        throw "Sidecar has an invalid value: $Path"
    }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Get-MenuBlocks {
    param([string[]]$Lines)
    $blocks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\s*menuentry\s+(["''])(.*?)\1') { continue }
        $title = $Matches[2]
        $start = $i
        $depth = 0
        $seenOpen = $false
        $end = $i
        for ($j = $i; $j -lt $Lines.Count; $j++) {
            $opens = ([regex]::Matches($Lines[$j], '\{')).Count
            $closes = ([regex]::Matches($Lines[$j], '\}')).Count
            if ($opens -gt 0) { $seenOpen = $true }
            $depth += $opens
            $depth -= $closes
            $end = $j
            if ($seenOpen -and $depth -le 0) { break }
        }
        $blockLines = @($Lines[$start..$end])
        $linuxIndexes = @()
        for ($k = 0; $k -lt $blockLines.Count; $k++) {
            if ($blockLines[$k] -match '^\s*(linux|linuxefi)\s+') { $linuxIndexes += $k }
        }
        if ($linuxIndexes.Count -gt 0) {
            $blocks.Add([ordered]@{
                title = $title
                startLineOneBased = $start + 1
                endLineOneBased = $end + 1
                linuxLineIndexesFromMenuEntry = @($linuxIndexes)
                lines = $blockLines
            })
        }
        $i = $end
    }
    return @($blocks)
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$resultPath = Join-Path $OutputDirectory 'iso-boot-inspection.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'
$started = (Get-Date).ToUniversalTime()
$failure = $null
$passed = $false
$mounted = $false
$driveRoot = $null
$selected = $null
$candidates = @()

try {
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw "Staged production ISO is missing: $IsoPath"
    }
    $sha256Path = "$IsoPath.sha256"
    $sha512Path = "$IsoPath.sha512"
    $bytesPath = "$IsoPath.bytes"
    $expectedSha256 = Read-SidecarValue -Path $sha256Path -Pattern '^([0-9a-fA-F]{64})(?:\s+.*)?$'
    $expectedSha512 = Read-SidecarValue -Path $sha512Path -Pattern '^([0-9a-fA-F]{128})(?:\s+.*)?$'
    $expectedBytesText = Read-SidecarValue -Path $bytesPath -Pattern '^([0-9]+)$'
    $expectedBytes = [int64]$expectedBytesText
    $beforeSha256 = Get-LowerHash -Path $IsoPath -Algorithm SHA256
    $beforeSha512 = Get-LowerHash -Path $IsoPath -Algorithm SHA512
    $beforeBytes = [int64](Get-Item -LiteralPath $IsoPath).Length
    if ($beforeSha256 -ne $expectedSha256 -or $beforeSha512 -ne $expectedSha512 -or $beforeBytes -ne $expectedBytes) {
        throw 'The staged production ISO does not match its verified SHA-256, SHA-512, and byte-count sidecars.'
    }
    if ($beforeBytes -lt 8GB) {
        throw "Production ISO is unexpectedly smaller than 8 GiB: $beforeBytes bytes."
    }

    $diskImage = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    $mounted = $true
    Start-Sleep -Seconds 2
    $volumes = @($diskImage | Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter })
    if ($volumes.Count -ne 1) {
        throw "Expected exactly one mounted ISO volume with a drive letter; found $($volumes.Count)."
    }
    $driveRoot = "$($volumes[0].DriveLetter):\"

    $priorityNames = @('grub.cfg','grub.conf','isolinux.cfg','syslinux.cfg')
    $files = @(Get-ChildItem -LiteralPath $driveRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -gt 0 -and $_.Length -le 2MB -and
            ($priorityNames -contains $_.Name.ToLowerInvariant() -or $_.Extension -in @('.cfg','.conf'))
        })
    foreach ($file in $files) {
        $text = $null
        try { $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop }
        catch { continue }
        if ($text -notmatch '(?m)^\s*(linux|linuxefi)\s+') { continue }
        $relative = $file.FullName.Substring($driveRoot.Length).Replace('\','/')
        $lines = @($text -split "`r?`n")
        $blocks = Get-MenuBlocks -Lines $lines
        if ($blocks.Count -eq 0) {
            $linux = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*(linux|linuxefi)\s+') { $linux += $i }
            }
            $blocks = @([ordered]@{
                title = '<top-level>'
                startLineOneBased = 1
                endLineOneBased = $lines.Count
                linuxLineIndexesFromMenuEntry = $linux
                lines = $lines
            })
        }
        $fileRecord = [ordered]@{
            relativePath = $relative
            bytes = [int64]$file.Length
            sha256 = Get-LowerHash -Path $file.FullName -Algorithm SHA256
            menuBlocks = @($blocks)
        }
        $candidates += $fileRecord
    }
    if ($candidates.Count -eq 0) {
        throw 'No GRUB/Syslinux configuration containing a Linux kernel command was found in the production ISO.'
    }

    $ranked = foreach ($file in $candidates) {
        foreach ($block in $file.menuBlocks) {
            $titleLower = ([string]$block.title).ToLowerInvariant()
            $pathLower = ([string]$file.relativePath).ToLowerInvariant()
            $score = 0
            if ($pathLower -match 'efi/.*/grub\.cfg|efi/boot/grub\.cfg') { $score += 100 }
            elseif ($pathLower -match 'grub') { $score += 60 }
            if ($titleLower -match 'layersentry') { $score += 60 }
            elseif ($titleLower -match 'harvester') { $score += 40 }
            if ($titleLower -match 'install|start') { $score += 20 }
            if ($titleLower -match 'debug|rescue|recovery|serial') { $score -= 50 }
            [pscustomobject]@{ score = $score; file = $file; block = $block }
        }
    }
    $best = @($ranked | Sort-Object -Property score -Descending | Select-Object -First 1)
    if ($best.Count -ne 1) { throw 'Unable to select a production ISO boot menu entry.' }
    $block = $best[0].block
    $linuxIndexes = @($block.linuxLineIndexesFromMenuEntry)
    if ($linuxIndexes.Count -ne 1) {
        throw "Selected menu entry contains $($linuxIndexes.Count) Linux kernel lines; expected exactly one."
    }
    $linuxIndex = [int]$linuxIndexes[0]
    $linuxLine = [string]$block.lines[$linuxIndex]
    $selected = [ordered]@{
        fileRelativePath = [string]$best[0].file.relativePath
        fileSha256 = [string]$best[0].file.sha256
        menuTitle = [string]$block.title
        score = [int]$best[0].score
        menuEntryStartLineOneBased = [int]$block.startLineOneBased
        menuEntryEndLineOneBased = [int]$block.endLineOneBased
        linuxLineIndexFromMenuEntryZeroBased = $linuxIndex
        linuxLine = $linuxLine
        editNavigation = [ordered]@{
            openEditorKey = 'e'
            homeKeyCode = 36
            downKeyCode = 40
            downKeyCount = $linuxIndex
            endKeyCode = 35
            bootEditedEntryKeyCode = 121
        }
        automaticInstallKernelArguments = @(
            'harvester.install.automatic=true',
            'harvester.install.config_url=http://10.10.10.1:8088/<node>.yaml',
            'ifname=eth0:<node-mac-colon-separated>',
            'ip=<node-ip>::10.10.10.1:255.255.255.0:<node>:eth0:none'
        )
    }

    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop
    $mounted = $false
    $afterSha256 = Get-LowerHash -Path $IsoPath -Algorithm SHA256
    $afterSha512 = Get-LowerHash -Path $IsoPath -Algorithm SHA512
    $afterBytes = [int64](Get-Item -LiteralPath $IsoPath).Length
    if ($afterSha256 -ne $beforeSha256 -or $afterSha512 -ne $beforeSha512 -or $afterBytes -ne $beforeBytes) {
        throw 'The exact production ISO changed during read-only boot inspection.'
    }

    $persistentDirectory = Split-Path -Path $PersistentPlanPath -Parent
    New-Item -Path $persistentDirectory -ItemType Directory -Force | Out-Null
    $passed = $true
}
catch {
    $failure = $_.Exception.Message
    throw
}
finally {
    if ($mounted) {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    }
    $finished = (Get-Date).ToUniversalTime()
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $started.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $started).TotalSeconds
        isoPath = $IsoPath
        isoBytes = if (Test-Path -LiteralPath $IsoPath) { [int64](Get-Item -LiteralPath $IsoPath).Length } else { $null }
        isoSha256 = if (Test-Path -LiteralPath $IsoPath) { Get-LowerHash -Path $IsoPath -Algorithm SHA256 } else { $null }
        isoSha512 = if (Test-Path -LiteralPath $IsoPath) { Get-LowerHash -Path $IsoPath -Algorithm SHA512 } else { $null }
        selectedBootEntry = $selected
        candidateBootFiles = $candidates
        isoModified = $false
        passed = $passed
        failure = $failure
        productionReleaseApproved = $false
    }
    $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    if ($passed) {
        $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $PersistentPlanPath -Encoding UTF8
    }
    @"
# LayerSentry production ISO boot inspection

- ISO: $IsoPath
- ISO modified: **false**
- Selected boot config: $($selected.fileRelativePath)
- Selected menu title: $($selected.menuTitle)
- Linux-line down-key count: $($selected.editNavigation.downKeyCount)
- Inspection passed: $passed
- Runtime production release approved: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8
}
