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
    $task.Wait()
    return $task.Result
}

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
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

$file = Await-WinRT \
    -Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($image)) \
    -ResultType ([Windows.Storage.StorageFile])
$stream = Await-WinRT \
    -Operation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) \
    -ResultType ([Windows.Storage.Streams.IRandomAccessStream])
try {
    $decoder = Await-WinRT \
        -Operation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) \
        -ResultType ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await-WinRT \
        -Operation ($decoder.GetSoftwareBitmapAsync()) \
        -ResultType ([Windows.Graphics.Imaging.SoftwareBitmap])
    try {
        $result = Await-WinRT \
            -Operation ($engine.RecognizeAsync($bitmap)) \
            -ResultType ([Windows.Media.Ocr.OcrResult])
        $text = [string]$result.Text
        [ordered]@{
            schemaVersion = '1.0'
            engineLanguage = $engine.RecognizerLanguage.LanguageTag
            sourceImage = [IO.Path]::GetFileName($image)
            text = $text
            lineCount = @($result.Lines).Count
        } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    finally {
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
    }
}
finally {
    $stream.Dispose()
}
