[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ImagePath,

    [string]$LanguageTag = 'en-US'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethodDefinition -and
        $_.GetGenericArguments().Count -eq 1 -and
        $_.GetParameters().Count -eq 1
    } |
    Select-Object -First 1

if ($null -eq $asTaskMethod) {
    throw 'Unable to locate the generic WinRT AsTask conversion method.'
}

function Wait-WinRtOperation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Operation,

        [Parameter(Mandatory = $true)]
        [Type]$ResultType
    )

    $closedMethod = $script:asTaskMethod.MakeGenericMethod($ResultType)
    $task = $closedMethod.Invoke($null, @($Operation))
    if (-not $task.Wait([TimeSpan]::FromSeconds(60))) {
        throw "Timed out waiting for WinRT operation returning $($ResultType.FullName)."
    }
    if ($task.IsFaulted) {
        throw $task.Exception.GetBaseException()
    }
    return $task.Result
}

[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType = WindowsRuntime]

$resolvedPath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath
$language = [Windows.Globalization.Language]::new($LanguageTag)
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
if ($null -eq $engine) {
    $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
        ForEach-Object { $_.LanguageTag })
    throw "Windows OCR engine is unavailable for '$LanguageTag'. Available languages: $($available -join ', ')"
}

$stream = $null
$bitmap = $null
try {
    $fileOperation = [Windows.Storage.StorageFile]::GetFileFromPathAsync($resolvedPath)
    $storageFile = Wait-WinRtOperation -Operation $fileOperation -ResultType ([Windows.Storage.StorageFile])

    $streamOperation = $storageFile.OpenAsync([Windows.Storage.FileAccessMode]::Read)
    $stream = Wait-WinRtOperation -Operation $streamOperation -ResultType ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])

    $decoderOperation = [Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)
    $decoder = Wait-WinRtOperation -Operation $decoderOperation -ResultType ([Windows.Graphics.Imaging.BitmapDecoder])

    $bitmapOperation = $decoder.GetSoftwareBitmapAsync()
    $bitmap = Wait-WinRtOperation -Operation $bitmapOperation -ResultType ([Windows.Graphics.Imaging.SoftwareBitmap])

    $recognizeOperation = $engine.RecognizeAsync($bitmap)
    $result = Wait-WinRtOperation -Operation $recognizeOperation -ResultType ([Windows.Media.Ocr.OcrResult])

    $lines = @($result.Lines | ForEach-Object {
        [ordered]@{
            text = $_.Text
            words = @($_.Words | ForEach-Object {
                [ordered]@{
                    text = $_.Text
                    boundingRect = [ordered]@{
                        x = $_.BoundingRect.X
                        y = $_.BoundingRect.Y
                        width = $_.BoundingRect.Width
                        height = $_.BoundingRect.Height
                    }
                }
            })
        }
    })

    [ordered]@{
        schemaVersion = '1.0'
        image = $resolvedPath
        language = $LanguageTag
        text = $result.Text
        lines = $lines
    } | ConvertTo-Json -Depth 10
}
finally {
    if ($null -ne $bitmap) {
        $bitmap.Dispose()
    }
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}
