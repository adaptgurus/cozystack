[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen1', 'sen2', 'sen3'),
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-installer-autopilot-v3'),
    [ValidateRange(1, 180)]
    [int]$MaxIterations = 120,
    [ValidateRange(3, 120)]
    [int]$PollSeconds = 12,
    [ValidateRange(10, 180)]
    [int]$ClusterReadyTimeoutMinutes = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseClassifier = Join-Path $PSScriptRoot 'classify-harvester-installer-screen.ps1'
$extendedClassifier = Join-Path $PSScriptRoot 'classify-harvester-installer-screen-v3.ps1'
$autopilot = Join-Path $PSScriptRoot 'invoke-harvester-installer-autopilot.ps1'

foreach ($path in @($baseClassifier, $extendedClassifier, $autopilot)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required autopilot v3 input is missing: $path"
    }
}

$backup = Join-Path $env:RUNNER_TEMP ('layersentry-base-classifier-{0}.ps1' -f [Guid]::NewGuid().ToString('N'))
Copy-Item -LiteralPath $baseClassifier -Destination $backup -Force
$escapedExtended = $extendedClassifier.Replace("'", "''")
$escapedBackup = $backup.Replace("'", "''")
$shim = @"
[CmdletBinding()]
param(
    [Parameter(Mandatory = `$true)]
    [string]`$OcrJsonPath
)
& '$escapedExtended' -OcrJsonPath `$OcrJsonPath -BaseClassifierPath '$escapedBackup'
"@

try {
    Set-Content -LiteralPath $baseClassifier -Value $shim -Encoding UTF8
    & $autopilot `
        -VmNames $VmNames `
        -OutputDirectory $OutputDirectory `
        -MaxIterations $MaxIterations `
        -PollSeconds $PollSeconds `
        -ClusterReadyTimeoutMinutes $ClusterReadyTimeoutMinutes
}
finally {
    Copy-Item -LiteralPath $backup -Destination $baseClassifier -Force
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
}
