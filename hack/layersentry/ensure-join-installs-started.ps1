[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen2', 'sen3'),
    [double]$MinimumStartedDiskGiB = 1.0,
    [int]$ObservationSeconds = 180,
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-join-start-guard')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module Hyper-V -ErrorAction Stop

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

function Get-OsDiskState {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    $drive = @(
        Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
                [string]$_.Path -match '(?i)-os\.vhdx$'
            }
    )
    if ($drive.Count -ne 1) {
        throw "Expected exactly one -os.vhdx disk for $VmName; found $($drive.Count)."
    }
    $vhd = Get-VHD -Path $drive[0].Path -ErrorAction Stop
    $dvdPaths = @(
        Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
            ForEach-Object { [string]$_.Path } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    return [ordered]@{
        vm = $VmName
        state = [string]$vm.State
        uptimeSeconds = [int64]$vm.Uptime.TotalSeconds
        osDiskPath = [string]$drive[0].Path
        osDiskVirtualSizeGiB = [math]::Round(([double]$vhd.Size / 1GB), 3)
        osDiskFileSizeGiB = [math]::Round(([double]$vhd.FileSize / 1GB), 3)
        dvdAttached = ($dvdPaths.Count -gt 0)
        dvdPaths = $dvdPaths
    }
}

function Get-Keyboard {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $escaped = $VmName.Replace("'", "''")
    $vmcs = Get-CimInstance `
        -Namespace 'root/virtualization/v2' `
        -ClassName 'Msvm_ComputerSystem' `
        -Filter "ElementName='$escaped'" `
        -ErrorAction Stop |
        Select-Object -First 1
    if ($null -eq $vmcs) {
        throw "Msvm_ComputerSystem was not found for $VmName."
    }
    $keyboard = Get-CimAssociatedInstance `
        -InputObject $vmcs `
        -ResultClassName 'Msvm_Keyboard' `
        -ErrorAction Stop |
        Select-Object -First 1
    if ($null -eq $keyboard) {
        throw "Msvm_Keyboard was not found for $VmName."
    }
    return $keyboard
}

function Send-Enter {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $keyboard = Get-Keyboard -VmName $VmName
    $response = Invoke-CimMethod `
        -InputObject $keyboard `
        -MethodName TypeKey `
        -Arguments @{ keyCode = [uint32]13 } `
        -ErrorAction Stop
    if ([uint32]$response.ReturnValue -ne 0) {
        throw "Enter key delivery failed for $VmName with return value $($response.ReturnValue)."
    }
}

$startedAt = (Get-Date).ToUniversalTime()
$before = @()
$after = @()
$actions = @()
$passed = $false
$failure = $null

try {
    foreach ($vmName in $VmNames) {
        if ($vmName -notin @('sen2', 'sen3')) {
            throw "Unapproved join-node target: $vmName"
        }
        $state = Get-OsDiskState -VmName $vmName
        $before += [pscustomobject]$state

        $shouldPress = (
            $state.state -eq 'Running' -and
            [bool]$state.dvdAttached -and
            [double]$state.osDiskFileSizeGiB -lt $MinimumStartedDiskGiB
        )
        if ($shouldPress) {
            Send-Enter -VmName $vmName
            $actions += [pscustomobject]@{
                vm = $vmName
                action = 'enter-on-empty-installer-disk'
                executed = $true
            }
        }
        else {
            $actions += [pscustomobject]@{
                vm = $vmName
                action = 'no-input-install-already-started-or-media-ejected'
                executed = $false
            }
        }
    }

    Start-Sleep -Seconds $ObservationSeconds

    foreach ($vmName in $VmNames) {
        $after += [pscustomobject](Get-OsDiskState -VmName $vmName)
    }

    $notStarted = @(
        $after |
            Where-Object {
                $_.state -eq 'Running' -and
                $_.dvdAttached -and
                [double]$_.osDiskFileSizeGiB -lt $MinimumStartedDiskGiB
            }
    )
    if ($notStarted.Count -gt 0) {
        throw "Installation has not started on: $($notStarted.vm -join ', ')."
    }
    $passed = $true
}
catch {
    $failure = $_.Exception.Message
    throw
}
finally {
    $captureScript = Join-Path $PSScriptRoot 'capture-hyperv-console.ps1'
    if (Test-Path -LiteralPath $captureScript -PathType Leaf) {
        try {
            & $captureScript -VmNames $VmNames -OutputDirectory (Join-Path $OutputDirectory 'consoles')
        }
        catch {
            Write-Warning "Console capture failed: $($_.Exception.Message)"
        }
    }

    $finishedAt = (Get-Date).ToUniversalTime()
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        observationSeconds = $ObservationSeconds
        minimumStartedDiskGiB = $MinimumStartedDiskGiB
        passed = $passed
        failure = $failure
        before = $before
        actions = $actions
        after = $after
        credentialsRead = $false
        containsCredentialValues = $false
        productionReleaseApproved = $false
    }
    $result | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'join-start-guard.json') -Encoding UTF8

    @"
# LayerSentry join-node installation start guard

- Targets: $($VmNames -join ', ')
- Observation seconds: $ObservationSeconds
- Minimum started-disk threshold: $MinimumStartedDiskGiB GiB
- Passed: $passed
- Failure: $failure
- Credential values retained: **false**
- Production release approved: **false**
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'STATUS.md') -Encoding UTF8
}
