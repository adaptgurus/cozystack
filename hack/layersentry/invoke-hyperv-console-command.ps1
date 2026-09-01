[CmdletBinding()]
param(
    [string]$RequestPath = 'hack/layersentry/console-command.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-console-command')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Console command request not found: $RequestPath"
}

$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $request.requestId -or [string]::IsNullOrWhiteSpace([string]$request.requestId)) {
    throw 'requestId is required.'
}
if ($null -eq $request.targets -or @($request.targets).Count -eq 0) {
    throw 'At least one target is required.'
}

$allowedNames = @('sen1', 'sen2', 'sen3')
$allowedKeyCodes = @(
    8, 9, 13, 27, 32,
    33, 34, 35, 36, 37, 38, 39, 40,
    46,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
    65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77,
    78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123
)

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

$results = New-Object System.Collections.Generic.List[object]
foreach ($target in @($request.targets)) {
    $name = [string]$target.vm
    if ($allowedNames -notcontains $name) {
        throw "VM is not in the approved target set: $name"
    }
    $vm = Get-VM -Name $name -ErrorAction Stop
    if ($vm.State -ne 'Running') {
        throw "VM $name is not Running. Current state: $($vm.State)"
    }

    $escapedName = $name.Replace("'", "''")
    $vmcs = Get-WmiObject `
        -Namespace 'root\virtualization\v2' `
        -Class 'Msvm_ComputerSystem' `
        -Filter "ElementName='$escapedName'" `
        -ErrorAction Stop
    if ($null -eq $vmcs) {
        throw "Msvm_ComputerSystem not found for $name"
    }
    $keyboard = @($vmcs.GetRelated('Msvm_Keyboard')) | Select-Object -First 1
    if ($null -eq $keyboard) {
        throw "Msvm_Keyboard not found for $name"
    }

    $keyResults = New-Object System.Collections.Generic.List[object]
    foreach ($rawKey in @($target.keys)) {
        $key = [int]$rawKey
        if ($allowedKeyCodes -notcontains $key) {
            throw "Virtual key code $key is not permitted."
        }
        $response = $keyboard.TypeKey($key)
        $returnValue = if ($response.PSObject.Properties['ReturnValue']) {
            [int]$response.ReturnValue
        }
        else {
            [int]$response
        }
        if ($returnValue -ne 0) {
            throw "TypeKey($key) failed for $name with return value $returnValue"
        }
        $keyResults.Add([pscustomobject]@{ KeyCode = $key; ReturnValue = $returnValue })
        Start-Sleep -Milliseconds 350
    }

    $textResult = $null
    if ($target.PSObject.Properties['text'] -and -not [string]::IsNullOrEmpty([string]$target.text)) {
        $text = [string]$target.text
        if ($text.Length -gt 512) {
            throw "Text payload for $name is longer than 512 characters."
        }
        if ($text -match '[\r\n]') {
            throw "Text payload for $name may not contain newlines."
        }
        $response = $keyboard.TypeText($text)
        $returnValue = if ($response.PSObject.Properties['ReturnValue']) {
            [int]$response.ReturnValue
        }
        else {
            [int]$response
        }
        if ($returnValue -ne 0) {
            throw "TypeText failed for $name with return value $returnValue"
        }
        $textResult = [pscustomobject]@{
            CharacterCount = $text.Length
            ReturnValue = $returnValue
        }
    }

    $results.Add([pscustomobject]@{
        VM = $name
        Keys = @($keyResults)
        Text = $textResult
        StateAfter = [string](Get-VM -Name $name).State
    })
}

$delay = 5
if ($request.PSObject.Properties['delayAfterSeconds']) {
    $delay = [int]$request.delayAfterSeconds
}
if ($delay -lt 0 -or $delay -gt 120) {
    throw 'delayAfterSeconds must be between 0 and 120.'
}
Start-Sleep -Seconds $delay

$report = [pscustomobject]@{
    SchemaVersion = '1.0'
    RequestId = [string]$request.requestId
    ExecutedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Host = $env:COMPUTERNAME
    Results = @($results)
}
$report | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'console-command-result.json') -Encoding UTF8

@(
    'LayerSentry Hyper-V console command'
    "Request ID: $($report.RequestId)"
    "Executed UTC: $($report.ExecutedAtUtc)"
    ($results | Format-Table -AutoSize | Out-String -Width 300)
) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'console-command-result.txt') -Encoding UTF8

Get-Content -LiteralPath (Join-Path $OutputDirectory 'console-command-result.txt')
