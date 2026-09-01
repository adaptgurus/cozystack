[CmdletBinding()]
param(
    [string]$RequestPath = 'hack/layersentry/console-command.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-console-command'),
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$tracePath = Join-Path $OutputDirectory 'console-command-trace.txt'
"start $(Get-Date -Format o)" | Set-Content -LiteralPath $tracePath -Encoding UTF8

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
$allowedSecrets = @('nodePassword', 'clusterToken', 'adminPassword')
$allowedKeyCodes = @(
    8, 9, 13, 27, 32,
    33, 34, 35, 36, 37, 38, 39, 40,
    46,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
    65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77,
    78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90,
    112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123
)

$credentials = $null
function Get-CredentialValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($allowedSecrets -notcontains $Name) {
        throw "Secret reference is not permitted: $Name"
    }
    if ($null -eq $script:credentials) {
        if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
            throw "Bootstrap credential file not found: $CredentialPath"
        }
        $script:credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $property = $script:credentials.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrEmpty([string]$property.Value)) {
        throw "Bootstrap credential field is missing: $Name"
    }
    return [string]$property.Value
}

function Get-Keyboard {
    param([Parameter(Mandatory = $true)][string]$VMName)

    $escapedName = $VMName.Replace("'", "''")
    $vmcs = Get-CimInstance `
        -Namespace 'root/virtualization/v2' `
        -ClassName 'Msvm_ComputerSystem' `
        -Filter "ElementName='$escapedName'" `
        -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $vmcs) {
        throw "Msvm_ComputerSystem not found for $VMName"
    }
    $keyboard = Get-CimAssociatedInstance `
        -InputObject $vmcs `
        -ResultClassName 'Msvm_Keyboard' `
        -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $keyboard) {
        throw "Msvm_Keyboard not found for $VMName"
    }
    return $keyboard
}

function Send-Key {
    param(
        [Parameter(Mandatory = $true)]$Keyboard,
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][uint32]$Code
    )

    if ($allowedKeyCodes -notcontains [int]$Code) {
        throw "Virtual key code $Code is not permitted."
    }
    $response = Invoke-CimMethod `
        -InputObject $Keyboard `
        -MethodName 'TypeKey' `
        -Arguments @{ keyCode = $Code } `
        -ErrorAction Stop
    $returnValue = [uint32]$response.ReturnValue
    if ($returnValue -ne 0) {
        throw "TypeKey($Code) failed for $VMName with return value $returnValue"
    }
    Start-Sleep -Milliseconds 300
}

function Send-Text {
    param(
        [Parameter(Mandatory = $true)]$Keyboard,
        [Parameter(Mandatory = $true)][string]$VMName,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][bool]$Secret
    )

    if ($Value.Length -gt 512) {
        throw "Text payload for $VMName is longer than 512 characters."
    }
    if ($Value -match '[\r\n]') {
        throw "Text payload for $VMName may not contain newlines."
    }
    $response = Invoke-CimMethod `
        -InputObject $Keyboard `
        -MethodName 'TypeText' `
        -Arguments @{ asciiText = $Value } `
        -ErrorAction Stop
    $returnValue = [uint32]$response.ReturnValue
    if ($returnValue -ne 0) {
        throw "TypeText failed for $VMName with return value $returnValue"
    }
    $kind = if ($Secret) { 'secret' } else { 'text' }
    "sent-$kind vm=$VMName chars=$($Value.Length)" | Add-Content -LiteralPath $tracePath -Encoding UTF8
    Start-Sleep -Milliseconds 300
}

$results = @()
$fatalError = $null
try {
    foreach ($target in $request.targets) {
        $name = [string]$target.vm
        "target=$name" | Add-Content -LiteralPath $tracePath -Encoding UTF8
        if ($allowedNames -notcontains $name) {
            throw "VM is not in the approved target set: $name"
        }
        $vm = Get-VM -Name $name -ErrorAction Stop
        if ($vm.State -ne 'Running') {
            throw "VM $name is not Running. Current state: $($vm.State)"
        }
        $keyboard = Get-Keyboard -VMName $name
        $actionResults = @()

        if ($target.PSObject.Properties['actions']) {
            foreach ($action in $target.actions) {
                $kind = ([string]$action.kind).ToLowerInvariant()
                switch ($kind) {
                    'key' {
                        $code = [uint32]$action.code
                        Send-Key -Keyboard $keyboard -VMName $name -Code $code
                        $actionResults += [pscustomobject]@{ Kind = 'key'; Code = [int]$code; Status = 'success' }
                    }
                    'text' {
                        $value = [string]$action.value
                        Send-Text -Keyboard $keyboard -VMName $name -Value $value -Secret $false
                        $actionResults += [pscustomobject]@{ Kind = 'text'; CharacterCount = $value.Length; Status = 'success' }
                    }
                    'secret' {
                        $secretName = [string]$action.name
                        $value = Get-CredentialValue -Name $secretName
                        Send-Text -Keyboard $keyboard -VMName $name -Value $value -Secret $true
                        $actionResults += [pscustomobject]@{ Kind = 'secret'; Name = $secretName; CharacterCount = $value.Length; Status = 'success' }
                    }
                    'sleep' {
                        $milliseconds = [int]$action.milliseconds
                        if ($milliseconds -lt 0 -or $milliseconds -gt 10000) {
                            throw 'Action sleep must be between 0 and 10000 milliseconds.'
                        }
                        Start-Sleep -Milliseconds $milliseconds
                        $actionResults += [pscustomobject]@{ Kind = 'sleep'; Milliseconds = $milliseconds; Status = 'success' }
                    }
                    default {
                        throw "Unsupported console action kind: $kind"
                    }
                }
            }
        }
        else {
            foreach ($rawKey in $target.keys) {
                $code = [uint32]$rawKey
                Send-Key -Keyboard $keyboard -VMName $name -Code $code
                $actionResults += [pscustomobject]@{ Kind = 'key'; Code = [int]$code; Status = 'success' }
            }
            if ($target.PSObject.Properties['text'] -and -not [string]::IsNullOrEmpty([string]$target.text)) {
                $value = [string]$target.text
                Send-Text -Keyboard $keyboard -VMName $name -Value $value -Secret $false
                $actionResults += [pscustomobject]@{ Kind = 'text'; CharacterCount = $value.Length; Status = 'success' }
            }
        }

        $results += [pscustomobject]@{
            VM = $name
            Actions = $actionResults
            StateAfter = [string](Get-VM -Name $name).State
        }
    }

    $delay = 5
    if ($request.PSObject.Properties['delayAfterSeconds']) {
        $delay = [int]$request.delayAfterSeconds
    }
    if ($delay -lt 0 -or $delay -gt 120) {
        throw 'delayAfterSeconds must be between 0 and 120.'
    }
    Start-Sleep -Seconds $delay
}
catch {
    $fatalError = $_.Exception.Message
    "fatal=$fatalError" | Add-Content -LiteralPath $tracePath -Encoding UTF8
}
finally {
    $report = [pscustomobject]@{
        SchemaVersion = '2.0'
        RequestId = [string]$request.requestId
        ExecutedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Host = $env:COMPUTERNAME
        CredentialPathUsed = if ($null -ne $credentials) { $CredentialPath } else { $null }
        Results = $results
        FatalError = $fatalError
    }
    $report | ConvertTo-Json -Depth 15 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'console-command-result.json') -Encoding UTF8
    @(
        'LayerSentry Hyper-V console command'
        "Request ID: $($report.RequestId)"
        "Executed UTC: $($report.ExecutedAtUtc)"
        "Fatal error: $fatalError"
        ($results | Select-Object VM, StateAfter | Format-Table -AutoSize | Out-String -Width 300)
    ) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'console-command-result.txt') -Encoding UTF8
    Get-Content -LiteralPath (Join-Path $OutputDirectory 'console-command-result.txt')
}

if ($null -ne $fatalError) {
    throw $fatalError
}
