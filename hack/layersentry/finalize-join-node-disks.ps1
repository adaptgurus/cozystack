[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen2', 'sen3'),
    [double]$MinimumCompletedDiskGiB = 20.0,
    [int]$RequiredStableSeconds = 120,
    [int]$MaxWaitMinutes = 30,
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-join-disk-finalizer')
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
$historyPath = Join-Path $OutputDirectory 'disk-history.jsonl'
$resultPath = Join-Path $OutputDirectory 'join-disk-finalization.json'
$statusPath = Join-Path $OutputDirectory 'STATUS.md'

function Get-JoinDiskState {
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
        throw "Expected exactly one -os.vhdx for $VmName; found $($drive.Count)."
    }
    $vhd = Get-VHD -Path $drive[0].Path -ErrorAction Stop
    $dvds = @(
        Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) }
    )
    return [pscustomobject]@{
        VmName = $VmName
        State = [string]$vm.State
        UptimeSeconds = [int64]$vm.Uptime.TotalSeconds
        OsDrive = $drive[0]
        OsDiskPath = [string]$drive[0].Path
        OsDiskFileSizeGiB = [math]::Round(([double]$vhd.FileSize / 1GB), 3)
        OsDiskVirtualSizeGiB = [math]::Round(([double]$vhd.Size / 1GB), 3)
        DvdDrives = $dvds
        DvdAttached = ($dvds.Count -gt 0)
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

function Send-EnterOnce {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $keyboard = Get-Keyboard -VmName $VmName
    $response = Invoke-CimMethod `
        -InputObject $keyboard `
        -MethodName TypeKey `
        -Arguments @{ keyCode = [uint32]13 } `
        -ErrorAction Stop
    if ([uint32]$response.ReturnValue -ne 0) {
        throw "Enter delivery failed for $VmName with return value $($response.ReturnValue)."
    }
}

function Set-OsDiskBootIdempotent {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $state = Get-JoinDiskState -VmName $VmName
    if (-not $state.DvdAttached) {
        if ($state.State -eq 'Off') {
            Start-VM -Name $VmName -ErrorAction Stop | Out-Null
        }
        return
    }

    if ($state.State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force -ErrorAction Stop
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            Start-Sleep -Seconds 1
            if ([string](Get-VM -Name $VmName -ErrorAction Stop).State -eq 'Off') {
                break
            }
        }
    }

    $refreshed = Get-JoinDiskState -VmName $VmName
    foreach ($dvd in @($refreshed.DvdDrives)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dvd.Path)) {
            Set-VMDvdDrive `
                -VMName $VmName `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $null `
                -ErrorAction Stop
        }
    }
    $osDrive = (Get-JoinDiskState -VmName $VmName).OsDrive
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDrive -ErrorAction Stop
    if ([string](Get-VM -Name $VmName -ErrorAction Stop).State -eq 'Off') {
        Start-VM -Name $VmName -ErrorAction Stop | Out-Null
    }
}

$startedAt = (Get-Date).ToUniversalTime()
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
$runtime = @{}
$actions = @()
$passed = $false
$failure = $null

try {
    foreach ($vmName in $VmNames) {
        if ($vmName -notin @('sen2', 'sen3')) {
            throw "Unapproved join-node target: $vmName"
        }
        $state = Get-JoinDiskState -VmName $vmName
        $runtime[$vmName] = [pscustomobject]@{
            LastSizeGiB = [double]$state.OsDiskFileSizeGiB
            StableSeconds = 0
            EnterSent = $false
            Finalized = (-not [bool]$state.DvdAttached)
        }
    }

    do {
        $snapshot = @()
        foreach ($vmName in $VmNames) {
            $rt = $runtime[$vmName]
            $state = Get-JoinDiskState -VmName $vmName
            $delta = [math]::Abs([double]$state.OsDiskFileSizeGiB - [double]$rt.LastSizeGiB)
            if ($delta -le 0.02) {
                $rt.StableSeconds += 15
            }
            else {
                $rt.StableSeconds = 0
            }

            if (
                -not $rt.EnterSent -and
                $state.State -eq 'Running' -and
                $state.DvdAttached -and
                [double]$state.OsDiskFileSizeGiB -lt 1.0
            ) {
                Send-EnterOnce -VmName $vmName
                $rt.EnterSent = $true
                $actions += [pscustomobject]@{
                    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    vm = $vmName
                    action = 'enter-on-empty-installer-disk'
                }
            }

            if (
                $state.DvdAttached -and
                [double]$state.OsDiskFileSizeGiB -ge $MinimumCompletedDiskGiB -and
                [int]$rt.StableSeconds -ge $RequiredStableSeconds
            ) {
                Set-OsDiskBootIdempotent -VmName $vmName
                $rt.Finalized = $true
                $actions += [pscustomobject]@{
                    capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                    vm = $vmName
                    action = 'eject-media-set-os-disk-first-and-start'
                }
                Start-Sleep -Seconds 10
                $state = Get-JoinDiskState -VmName $vmName
            }
            elseif (-not $state.DvdAttached) {
                $rt.Finalized = $true
                if ($state.State -eq 'Off') {
                    Start-VM -Name $vmName -ErrorAction Stop | Out-Null
                    Start-Sleep -Seconds 5
                    $state = Get-JoinDiskState -VmName $vmName
                }
            }

            $rt.LastSizeGiB = [double]$state.OsDiskFileSizeGiB
            $snapshot += [ordered]@{
                vm = $vmName
                state = $state.State
                osDiskFileSizeGiB = $state.OsDiskFileSizeGiB
                dvdAttached = $state.DvdAttached
                stableSeconds = $rt.StableSeconds
                enterSent = $rt.EnterSent
                finalized = $rt.Finalized
            }
        }

        ([ordered]@{
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            nodes = $snapshot
        } | ConvertTo-Json -Depth 8 -Compress) |
            Add-Content -LiteralPath $historyPath -Encoding UTF8

        $allFinalized = @($VmNames | Where-Object { -not [bool]$runtime[$_].Finalized }).Count -eq 0
        if (-not $allFinalized) {
            Start-Sleep -Seconds 15
        }
    } while (-not $allFinalized -and (Get-Date) -lt $deadline)

    if (-not $allFinalized) {
        $remaining = @($VmNames | Where-Object { -not [bool]$runtime[$_].Finalized })
        throw "Join-node disk finalization timed out for: $($remaining -join ', ')."
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
            & $captureScript -VmNames @('sen1', 'sen2', 'sen3') -OutputDirectory (Join-Path $OutputDirectory 'consoles')
        }
        catch {
            Write-Warning "Console capture failed: $($_.Exception.Message)"
        }
    }

    $finalStates = @()
    foreach ($vmName in $VmNames) {
        try {
            $state = Get-JoinDiskState -VmName $vmName
            $finalStates += [ordered]@{
                vm = $vmName
                state = $state.State
                osDiskFileSizeGiB = $state.OsDiskFileSizeGiB
                dvdAttached = $state.DvdAttached
            }
        }
        catch {
            $finalStates += [ordered]@{ vm = $vmName; error = $_.Exception.Message }
        }
    }

    $finishedAt = (Get-Date).ToUniversalTime()
    [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $startedAt.ToString('o')
        finishedAtUtc = $finishedAt.ToString('o')
        durationSeconds = [int64]($finishedAt - $startedAt).TotalSeconds
        minimumCompletedDiskGiB = $MinimumCompletedDiskGiB
        requiredStableSeconds = $RequiredStableSeconds
        passed = $passed
        failure = $failure
        actions = $actions
        finalStates = $finalStates
        credentialsRead = $false
        containsCredentialValues = $false
        productionReleaseApproved = $false
    } | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $resultPath -Encoding UTF8

    @"
# LayerSentry authoritative join-disk finalization

- Targets: $($VmNames -join ', ')
- Completed-disk threshold: $MinimumCompletedDiskGiB GiB
- Required stability: $RequiredStableSeconds seconds
- Passed: $passed
- Credential values retained: **false**
- Production release approved: **false**
- Failure: $failure
"@ | Set-Content -LiteralPath $statusPath -Encoding UTF8
}
