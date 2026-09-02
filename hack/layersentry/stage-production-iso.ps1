[CmdletBinding()]
param(
    [string]$SourceRepository = 'adaptgurus/harvester-installer',
    [string]$SourceBranch = 'layersentry-v1.0-dev',
    [string]$WorkflowName = 'LayerSentry v1.0 full-offline ISO (Harvester v1.8.2 embedded)',
    [string]$DestinationRoot = 'C:\ProgramData\LayerSentry\production-iso',
    [string]$FriendlyDestinationDirectory = 'C:\Users\opc\Downloads\final iso',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-production-iso-staging')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$ResultPath = Join-Path $OutputDirectory 'production-iso-staging-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Failure = $null
$Passed = $false
$Run = $null
$Artifact = $null
$IsoPath = $null
$StagedIsoPath = $null
$FriendlyIsoPath = $null
$CalculatedSha256 = $null
$CalculatedSha512 = $null
$CalculatedBytes = $null
$ExpectedSha256 = $null
$ExpectedSha512 = $null
$ExpectedBytes = $null
$LockStatus = $null
$UnresolvedCount = $null
$DependencyLockComplete = $false
$ReleaseApproved = $false
$ArchiveDigest = $null
$DownloadBytes = $null

function Invoke-GitHubJson {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'LayerSentry-ISO-Staging/1.0'
    }
    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 90 -ErrorAction Stop
}

function Get-FileHashLower {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('SHA256','SHA512')][string]$Algorithm
    )
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLowerInvariant()
}

function Get-FreeBytesForPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $drive = New-Object System.IO.DriveInfo($root)
    return [int64]$drive.AvailableFreeSpace
}

try {
    foreach ($command in @('curl.exe','tar.exe')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            throw "Required Windows command is missing: $command"
        }
    }

    $runsUri = "https://api.github.com/repos/$SourceRepository/actions/runs?branch=$([uri]::EscapeDataString($SourceBranch))&per_page=100"
    $runs = Invoke-GitHubJson -Uri $runsUri
    $matchingRuns = @($runs.workflow_runs | Where-Object {
        [string]$_.name -eq $WorkflowName -and
        [string]$_.head_branch -eq $SourceBranch -and
        [string]$_.status -eq 'completed' -and
        [string]$_.conclusion -eq 'success'
    } | Sort-Object -Property id -Descending)
    if ($matchingRuns.Count -eq 0) {
        throw "No successful completed workflow named '$WorkflowName' was found on $SourceRepository/$SourceBranch."
    }
    $Run = $matchingRuns[0]
    if ([string]$Run.head_sha -notmatch '^[0-9a-f]{40}$') {
        throw 'Selected workflow run does not have an exact 40-hex source commit.'
    }

    $artifacts = Invoke-GitHubJson -Uri "https://api.github.com/repos/$SourceRepository/actions/runs/$($Run.id)/artifacts?per_page=100"
    $matchingArtifacts = @($artifacts.artifacts | Where-Object {
        -not [bool]$_.expired -and
        [string]$_.name -match 'layersentry-v1\.0-harvester-v1\.8\.2-amd64-offline' -and
        [string]$_.name -notmatch 'evidence'
    } | Sort-Object -Property id -Descending)
    if ($matchingArtifacts.Count -ne 1) {
        throw "Expected exactly one non-expired production ISO artifact; found $($matchingArtifacts.Count)."
    }
    $Artifact = $matchingArtifacts[0]
    $ArchiveDigest = [string]$Artifact.digest
    if ($ArchiveDigest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'GitHub artifact does not expose a valid SHA-256 archive digest.'
    }

    $headSha = [string]$Run.head_sha
    $stagingRoot = Join-Path $DestinationRoot $headSha
    $downloadDirectory = Join-Path $stagingRoot 'download'
    $extractDirectory = Join-Path $stagingRoot 'extracted'
    $archivePath = Join-Path $downloadDirectory 'github-artifact.zip'
    $temporaryArchive = "$archivePath.partial"
    New-Item -Path $downloadDirectory -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $extractDirectory) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }
    New-Item -Path $extractDirectory -ItemType Directory -Force | Out-Null
    Remove-Item -LiteralPath $temporaryArchive -Force -ErrorAction SilentlyContinue

    $requiredFree = [int64]$Artifact.size_in_bytes * 3 + 20GB
    $freeBefore = Get-FreeBytesForPath -Path $stagingRoot
    if ($freeBefore -lt $requiredFree) {
        throw "Insufficient free space for safe ISO download/extraction. Required $requiredFree bytes; available $freeBefore bytes."
    }

    & curl.exe `
        --fail `
        --location `
        --retry 8 `
        --retry-all-errors `
        --connect-timeout 30 `
        --max-time 10800 `
        --user-agent 'LayerSentry-ISO-Staging/1.0' `
        --output $temporaryArchive `
        ([string]$Artifact.archive_download_url)
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed to download the GitHub artifact; exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $temporaryArchive -PathType Leaf)) {
        throw 'GitHub artifact download did not create an archive file.'
    }
    $DownloadBytes = [int64](Get-Item -LiteralPath $temporaryArchive).Length
    if ($DownloadBytes -le 0) {
        throw 'Downloaded GitHub artifact archive is empty.'
    }
    Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force

    $calculatedArchiveDigest = 'sha256:' + (Get-FileHashLower -Path $archivePath -Algorithm SHA256)
    if ($calculatedArchiveDigest -ne $ArchiveDigest) {
        throw "Downloaded artifact archive digest $calculatedArchiveDigest does not equal GitHub digest $ArchiveDigest."
    }

    & tar.exe -xf $archivePath -C $extractDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed to extract the artifact archive; exit code $LASTEXITCODE."
    }

    $isoFiles = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -Filter '*.iso')
    if ($isoFiles.Count -ne 1) {
        throw "Expected exactly one ISO in the artifact; found $($isoFiles.Count)."
    }
    $IsoPath = $isoFiles[0].FullName
    $digestFiles = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -Filter 'artifact-digests.json')
    $provenanceFiles = @(Get-ChildItem -LiteralPath $extractDirectory -Recurse -File -Filter 'resolved-provenance.json')
    if ($digestFiles.Count -ne 1 -or $provenanceFiles.Count -ne 1) {
        throw "Expected one artifact-digests.json and one resolved-provenance.json; found $($digestFiles.Count) and $($provenanceFiles.Count)."
    }
    $digests = Get-Content -LiteralPath $digestFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $provenance = Get-Content -LiteralPath $provenanceFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json

    $ExpectedSha256 = [string]$digests.sha256
    $ExpectedSha512 = [string]$digests.sha512
    $ExpectedBytes = [int64]$digests.bytes
    $CalculatedSha256 = Get-FileHashLower -Path $IsoPath -Algorithm SHA256
    $CalculatedSha512 = Get-FileHashLower -Path $IsoPath -Algorithm SHA512
    $CalculatedBytes = [int64](Get-Item -LiteralPath $IsoPath).Length

    if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$' -or $ExpectedSha512 -notmatch '^[0-9a-f]{128}$') {
        throw 'Artifact digest metadata contains an invalid SHA-256 or SHA-512 value.'
    }
    if ($CalculatedSha256 -ne $ExpectedSha256) {
        throw "ISO SHA-256 mismatch: calculated $CalculatedSha256; expected $ExpectedSha256."
    }
    if ($CalculatedSha512 -ne $ExpectedSha512) {
        throw "ISO SHA-512 mismatch: calculated $CalculatedSha512; expected $ExpectedSha512."
    }
    if ($CalculatedBytes -ne $ExpectedBytes) {
        throw "ISO byte-count mismatch: calculated $CalculatedBytes; expected $ExpectedBytes."
    }
    if ($CalculatedBytes -lt 8GB) {
        throw "Production full-offline ISO is unexpectedly smaller than 8 GiB: $CalculatedBytes bytes."
    }

    $DependencyLockComplete = [bool]$digests.dependency_lock_complete
    if (-not $DependencyLockComplete) {
        throw 'Artifact digest metadata does not report dependency_lock_complete=true.'
    }
    if ($provenance.PSObject.Properties['dependency_lock_complete']) {
        if (-not [bool]$provenance.dependency_lock_complete) {
            throw 'Resolved provenance does not report dependency_lock_complete=true.'
        }
    }
    if ($provenance.PSObject.Properties['dependency_lock']) {
        $LockStatus = [string]$provenance.dependency_lock.status
        $UnresolvedCount = [int]$provenance.dependency_lock.unresolved_count
        if ($LockStatus -ne 'complete' -or $UnresolvedCount -ne 0) {
            throw "Resolved provenance dependency lock is '$LockStatus' with $UnresolvedCount unresolved inputs."
        }
    }
    if ([string]$provenance.build_source.commit -ne $headSha) {
        throw "Resolved provenance build source '$($provenance.build_source.commit)' does not equal workflow source '$headSha'."
    }
    $ReleaseApproved = if ($provenance.PSObject.Properties['release_approved']) {
        [bool]$provenance.release_approved
    } else { $false }
    if ($ReleaseApproved) {
        throw 'Build artifact unexpectedly claims runtime production release approval before Hyper-V final-ISO qualification.'
    }

    $friendlyFileName = 'layersentry-v1.0-harvester-v1.8.2-production-build.iso'
    New-Item -Path $FriendlyDestinationDirectory -ItemType Directory -Force | Out-Null
    $StagedIsoPath = Join-Path $stagingRoot $friendlyFileName
    $FriendlyIsoPath = Join-Path $FriendlyDestinationDirectory $friendlyFileName
    Copy-Item -LiteralPath $IsoPath -Destination $StagedIsoPath -Force
    Copy-Item -LiteralPath $IsoPath -Destination $FriendlyIsoPath -Force
    if ((Get-FileHashLower -Path $StagedIsoPath -Algorithm SHA256) -ne $CalculatedSha256) {
        throw 'ProgramData staged ISO failed post-copy SHA-256 verification.'
    }
    if ((Get-FileHashLower -Path $FriendlyIsoPath -Algorithm SHA256) -ne $CalculatedSha256) {
        throw 'Friendly Downloads ISO failed post-copy SHA-256 verification.'
    }

    foreach ($directory in @($stagingRoot, $FriendlyDestinationDirectory)) {
        $prefix = if ($directory -eq $stagingRoot) { $stagingRoot } else { $FriendlyDestinationDirectory }
        "$CalculatedSha256  $friendlyFileName" |
            Set-Content -LiteralPath (Join-Path $prefix "$friendlyFileName.sha256") -Encoding ASCII
        "$CalculatedSha512  $friendlyFileName" |
            Set-Content -LiteralPath (Join-Path $prefix "$friendlyFileName.sha512") -Encoding ASCII
        "$CalculatedBytes" |
            Set-Content -LiteralPath (Join-Path $prefix "$friendlyFileName.bytes") -Encoding ASCII
    }

    $Passed = $true
}
catch {
    $Failure = $_.Exception.Message
    throw
}
finally {
    $finished = (Get-Date).ToUniversalTime()
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        sourceRepository = $SourceRepository
        sourceBranch = $SourceBranch
        workflowName = $WorkflowName
        workflowRunId = if ($null -ne $Run) { [int64]$Run.id } else { $null }
        workflowSourceCommit = if ($null -ne $Run) { [string]$Run.head_sha } else { $null }
        workflowConclusion = if ($null -ne $Run) { [string]$Run.conclusion } else { $null }
        artifactId = if ($null -ne $Artifact) { [int64]$Artifact.id } else { $null }
        artifactName = if ($null -ne $Artifact) { [string]$Artifact.name } else { $null }
        artifactArchiveDigest = $ArchiveDigest
        downloadedArchiveBytes = $DownloadBytes
        calculatedIsoBytes = $CalculatedBytes
        expectedIsoBytes = $ExpectedBytes
        calculatedIsoSha256 = $CalculatedSha256
        expectedIsoSha256 = $ExpectedSha256
        calculatedIsoSha512 = $CalculatedSha512
        expectedIsoSha512 = $ExpectedSha512
        dependencyLockComplete = $DependencyLockComplete
        dependencyLockStatus = $LockStatus
        unresolvedDependencyCount = $UnresolvedCount
        runtimeReleaseApprovedByBuildArtifact = $ReleaseApproved
        stagedIsoPath = $StagedIsoPath
        friendlyIsoPath = $FriendlyIsoPath
        attachedToHyperVVirtualMachines = $false
        currentPocClusterModified = $false
        passed = $Passed
        failure = $Failure
    }
    $result | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry production-build ISO staging

- Source workflow: $WorkflowName
- Source run: $($result.workflowRunId)
- Source commit: $($result.workflowSourceCommit)
- Artifact: $($result.artifactName)
- ISO bytes: $CalculatedBytes
- SHA-256: $CalculatedSha256
- SHA-512: $CalculatedSha512
- Dependency lock complete: $DependencyLockComplete
- Dependency lock status: $LockStatus
- Unresolved dependency count: $UnresolvedCount
- ProgramData path: $StagedIsoPath
- Downloads path: $FriendlyIsoPath
- Attached to Hyper-V VMs: **false**
- Existing POC cluster modified: **false**
- Runtime production release approved: **false**
- Staging passed: $Passed
- Failure: $Failure
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}
