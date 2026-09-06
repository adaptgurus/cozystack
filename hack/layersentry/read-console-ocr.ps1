[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ImagePath,

    [string]$LanguageTag = 'en-US',

    [ValidateRange(1, 2)]
    [int]$ImageScale = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethodDefinition -and
        $_.GetGenericArguments().Count -eq 1 -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.IsGenericType -and
        $_.GetParameters()[0].ParameterType.GetGenericTypeDefinition().FullName -ceq 'Windows.Foundation.IAsyncOperation`1'
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

function Sort-ConsoleOcrLines($Lines) {
    # OCR reading order may put a right-hand kernel continuation after the
    # lower terminal prompt. Preserve text, order by the visible coordinates.
    return @($Lines | Sort-Object @{Expression={($_.words | ForEach-Object { $_.boundingRect.y } | Measure-Object -Minimum).Minimum}},
        @{Expression={($_.words | ForEach-Object { $_.boundingRect.x } | Measure-Object -Minimum).Minimum}})
}

[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapTransform, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
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
    $stream = Wait-WinRtOperation -Operation $streamOperation -ResultType ([Windows.Storage.Streams.IRandomAccessStream])

    $decoderOperation = [Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)
    $decoder = Wait-WinRtOperation -Operation $decoderOperation -ResultType ([Windows.Graphics.Imaging.BitmapDecoder])

    if ($ImageScale -eq 1) { $bitmapOperation = $decoder.GetSoftwareBitmapAsync() }
    else {
        $width = [uint32]($decoder.PixelWidth * $ImageScale)
        $height = [uint32]($decoder.PixelHeight * $ImageScale)
        if ($width -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension -or $height -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension) {
            throw 'Scaled console exceeds the OCR dimension limit.'
        }
        $transform = [Windows.Graphics.Imaging.BitmapTransform]::new()
        $transform.ScaledWidth = $width
        $transform.ScaledHeight = $height
        $transform.InterpolationMode = [Windows.Graphics.Imaging.BitmapInterpolationMode]::NearestNeighbor
        $bitmapOperation = $decoder.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
            [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied, $transform,
            [Windows.Graphics.Imaging.ExifOrientationMode]::IgnoreExifOrientation,
            [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)
    }
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
        lines = @(Sort-ConsoleOcrLines $lines)
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
