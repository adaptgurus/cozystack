[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Await-WinRT {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Operation,

        [Parameter(Mandatory = $true)]
        [Type]$ResultType
    )

    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq 'AsTask' -and
            $_.IsGenericMethod -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    if ($null -eq $method) {
        throw 'Could not find generic WindowsRuntime AsTask method.'
    }

    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    return $task.Result
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
[void][Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType = WindowsRuntime]

$image = (Resolve-Path -LiteralPath $ImagePath).ProviderPath
$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if ($null -eq $engine) {
    $languages = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
        ForEach-Object { $_.LanguageTag }
    throw "Windows OCR engine is unavailable. Recognizer languages: $($languages -join ', ')"
}

$fileOperation = [Windows.Storage.StorageFile]::GetFileFromPathAsync($image)
$file = Await-WinRT -Operation $fileOperation -ResultType ([Windows.Storage.StorageFile])
$streamOperation = $file.OpenAsync([Windows.Storage.FileAccessMode]::Read)
$stream = Await-WinRT -Operation $streamOperation -ResultType ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])

try {
    $decoderOperation = [Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)
    $decoder = Await-WinRT -Operation $decoderOperation -ResultType ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmapOperation = $decoder.GetSoftwareBitmapAsync()
    $bitmap = Await-WinRT -Operation $bitmapOperation -ResultType ([Windows.Graphics.Imaging.SoftwareBitmap])

    try {
        $recognizeOperation = $engine.RecognizeAsync($bitmap)
        $result = Await-WinRT -Operation $recognizeOperation -ResultType ([Windows.Media.Ocr.OcrResult])
        $text = [string]$result.Text
        $document = [ordered]@{
            schemaVersion = '2.0'
            engineLanguage = $engine.RecognizerLanguage.LanguageTag
            sourceImage = [IO.Path]::GetFileName($image)
            text = $text
            lineCount = @($result.Lines).Count
        }
        $document | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    finally {
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
    }
}
finally {
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}
