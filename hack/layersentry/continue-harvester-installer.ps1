[CmdletBinding()]
param(
    [string[]]$VmNames = @('sen1', 'sen2', 'sen3'),
    [string]$EvidenceDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-installer-orchestrator'),
    [int]$MaximumMinutes = 150,
    [int]$PollSeconds = 15,
    [string]$ClusterVip = '10.10.10.10',
    [string]$NtpServers = 'time.cloudflare.com,time.google.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$captureScript = Join-Path $scriptRoot 'capture-hyperv-console.ps1'
$commandScript = Join-Path $scriptRoot 'invoke-hyperv-console-command.ps1'
$ocrScript = Join-Path $scriptRoot 'ocr-console.ps1'
$credentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Normalize-ConsoleText {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    return (($Text -replace '[\r\n\t]+', ' ' -replace '\s+', ' ').Trim()).ToUpperInvariant()
}

function Get-InstallerState {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $normalized = Normalize-ConsoleText -Text $Text
    $state = 'Unknown'
    $reason = 'No reviewed installer prompt matched.'

    if ($normalized -match 'PANIC|FATAL|INSTALLATION FAILED|ERROR.*INSTALL|FAILED TO') {
        $state = 'Error'
        $reason = 'Console contains a fatal or installation-failure marker.'
    }
    elseif ($normalized -match 'INSTALLATION (IS )?COMPLETE|INSTALLATION COMPLETED|REMOVE.*INSTALLATION MEDIA|PRESS ENTER.*REBOOT|REBOOT.*COMPLETE') {
        $state = 'InstallationComplete'
        $reason = 'Installer reports completion or requests reboot.'
    }
    elseif ($normalized -match 'INSTALLING|INSTALLATION IN PROGRESS|COPYING|EXTRACTING|WRITING.*DISK|CREATING.*FILESYSTEM|SETTING UP.*SYSTEM') {
        $state = 'Installing'
        $reason = 'Installer reports active installation work.'
    }
    elseif ($normalized -match 'HARVESTER.*LOGIN|WELCOME TO HARVESTER|MANAGEMENT URL|HTTPS://10\.10\.10\.|KUBERNETES.*READY') {
        $state = 'BootedInstalledSystem'
        $reason = 'Console resembles the installed Harvester system.'
    }
    elseif ($normalized -match 'CONFIRM.*PASSWORD|ENTER.*PASSWORD.*CONFIRM|PASSWORD.*CONTINUE.*INSTALL|CONFIRM.*INSTALLATION') {
        $state = 'InstallationConfirmationPassword'
        $reason = 'Installer requests the node password to confirm installation.'
    }
    elseif ($normalized -match 'ARE YOU SURE|DO YOU WANT TO CONTINUE|PROCEED WITH INSTALLATION|START INSTALLATION') {
        $state = 'InstallationConfirmationYes'
        $reason = 'Installer requests yes/continue confirmation.'
    }
    elseif ($normalized -match 'REVIEW.*CONFIGURATION|REVIEW.*INSTALL|INSTALLATION SUMMARY|SUMMARY.*INSTALL|BEGIN INSTALLATION|INSTALL HARVESTER') {
        $state = 'Review'
        $reason = 'Installer is on the review or install-action screen.'
    }
    elseif ($normalized -match 'CLUSTER TOKEN|ENTER.*TOKEN|TOKEN.*CLUSTER') {
        $state = 'ClusterToken'
        $reason = 'Installer requests the Harvester cluster token.'
    }
    elseif ($normalized -match 'NTP|TIME SERVER|NETWORK TIME') {
        $state = 'NtpServers'
        $reason = 'Installer requests NTP servers.'
    }
    elseif ($normalized -match 'TIME ?ZONE|TIMEZONE') {
        $state = 'Timezone'
        $reason = 'Installer requests a timezone.'
    }
    elseif ($normalized -match 'HTTP.*PROXY|HTTPS.*PROXY|NO[_ -]?PROXY|PROXY ADDRESS|CONFIGURE PROXY') {
        $state = 'Proxy'
        $reason = 'Installer requests optional proxy settings.'
    }
    elseif ($normalized -match 'SSH.*PUBLIC KEY|AUTHORIZED KEY|SSH KEY') {
        $state = 'SshKey'
        $reason = 'Installer requests an optional SSH public key.'
    }
    elseif ($normalized -match 'CONFIRM.*PASSWORD|REPEAT.*PASSWORD|PASSWORD AGAIN') {
        $state = 'NodePassword'
        $reason = 'Installer requests password confirmation.'
    }
    elseif ($normalized -match 'PASSWORD') {
        $state = 'NodePassword'
        $reason = 'Installer requests the node password.'
    }
    elseif ($normalized -match 'DNS') {
        $state = 'Dns'
        $reason = 'Installer requests DNS servers.'
    }
    elseif ($normalized -match 'HOST ?NAME') {
        $state = 'Hostname'
        $reason = 'Installer requests the node hostname.'
    }
    elseif ($normalized -match 'VIRTUAL IP|VIP ADDRESS|MANAGEMENT ADDRESS|SERVER ADDRESS|CLUSTER ADDRESS') {
        $state = 'ClusterAddress'
        $reason = 'Installer requests the cluster VIP or management address.'
    }
    elseif ($normalized -match 'PRESS ENTER|CONTINUE|NEXT') {
        $state = 'Continue'
        $reason = 'Installer exposes an explicit continue action.'
    }

    return [ordered]@{
        vm = $VmName
        state = $state
        reason = $reason
        normalizedText = $normalized
    }
}

function Get-OcrText {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$CaptureDirectory,
        [Parameter(Mandatory = $true)][string]$IterationDirectory
    )

    $image = Join-Path $CaptureDirectory "$VmName-console.png"
    $ocrPath = Join-Path $IterationDirectory "$VmName-ocr.json"
    Assert-Condition -Condition (Test-Path -LiteralPath $image -PathType Leaf) `
        -Message "Console image is missing for $VmName: $image"
    & $ocrScript -ImagePath $image -OutputPath $ocrPath
    $ocr = Get-Content -LiteralPath $ocrPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ocr.PSObject.Properties['error'] -and -not [string]::IsNullOrWhiteSpace([string]$ocr.error)) {
        throw "OCR failed for $VmName: $($ocr.error)"
    }
    return [string]$ocr.text
}

function Invoke-ApprovedAction {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][object[]]$Actions,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][string]$IterationDirectory
    )

    $requestPath = Join-Path $IterationDirectory "$VmName-request.json"
    $resultPath = Join-Path $IterationDirectory "$VmName-command"
    $request = [ordered]@{
        requestId = $RequestId
        delayAfterSeconds = 2
        targets = @(
            [ordered]@{
                vm = $VmName
                actions = $Actions
            }
        )
    }
    Write-JsonFile -Value $request -Path $requestPath
    & $commandScript -RequestPath $requestPath -OutputDirectory $resultPath
}

function New-KeyAction {
    param([int]$Code)
    return [ordered]@{ kind = 'key'; code = $Code }
}

function New-TextAction {
    param([string]$Value)
    return [ordered]@{ kind = 'text'; value = $Value }
}

function New-SecretAction {
    param([ValidateSet('nodePassword', 'clusterToken')][string]$Name)
    return [ordered]@{ kind = 'secret'; name = $Name }
}

function Get-ActionForState {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][bool]$AllowInstallation
    )

    switch ($State) {
        'ClusterToken' {
            return @((New-SecretAction -Name 'clusterToken'), (New-KeyAction -Code 13))
        }
        'NtpServers' {
            return @((New-TextAction -Value $NtpServers), (New-KeyAction -Code 13))
        }
        'Timezone' {
            return @((New-KeyAction -Code 13))
        }
        'Proxy' {
            return @((New-KeyAction -Code 13))
        }
        'SshKey' {
            return @((New-KeyAction -Code 13))
        }
        'NodePassword' {
            return @((New-SecretAction -Name 'nodePassword'), (New-KeyAction -Code 13))
        }
        'InstallationConfirmationPassword' {
            if ($AllowInstallation) {
                return @((New-SecretAction -Name 'nodePassword'), (New-KeyAction -Code 13))
            }
            return @()
        }
        'InstallationConfirmationYes' {
            if ($AllowInstallation) {
                return @((New-TextAction -Value 'y'), (New-KeyAction -Code 13))
            }
            return @()
        }
        'Review' {
            if ($AllowInstallation) {
                return @((New-KeyAction -Code 13))
            }
            return @()
        }
        'Continue' {
            if ($AllowInstallation -or $VmName -ne 'sen1') {
                return @((New-KeyAction -Code 13))
            }
            return @()
        }
        default {
            return @()
        }
    }
}

function Test-Port {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 1500
    )
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Set-InstalledBootConfiguration {
    param([Parameter(Mandatory = $true)][string]$VmName)

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VmName -TurnOff -Force
        Start-Sleep -Seconds 3
    }
    $disks = @(Get-VMHardDiskDrive -VMName $VmName | Sort-Object ControllerNumber, ControllerLocation)
    Assert-Condition -Condition ($disks.Count -ge 1) \
        -Message "$VmName has no attached virtual hard disk."
    $osDisk = $disks | Select-Object -First 1
    Set-VMFirmware -VMName $VmName -FirstBootDevice $osDisk
    Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue |
        Set-VMDvdDrive -Path $null
    Start-VM -Name $VmName | Out-Null
}

foreach ($path in @($captureScript, $commandScript, $ocrScript, $credentialPath)) {
    Assert-Condition -Condition (Test-Path -LiteralPath $path -PathType Leaf) \
        -Message "Required installer automation input is missing: $path"
}
foreach ($vmName in $VmNames) {
    Assert-Condition -Condition ($null -ne (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) \
        -Message "Required VM does not exist: $vmName"
}

if (Test-Path -LiteralPath $EvidenceDirectory) {
    Remove-Item -LiteralPath $EvidenceDirectory -Recurse -Force
}
New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
$transcriptPath = Join-Path $EvidenceDirectory 'orchestrator-transcript.txt'
Start-Transcript -LiteralPath $transcriptPath -Force | Out-Null

$deadline = (Get-Date).AddMinutes($MaximumMinutes)
$iteration = 0
$seenInstalling = @{}
$bootPrepared = @{}
$lastState = @{}
$repeatCount = @{}
$terminalFailure = $null

try {
    while ((Get-Date) -lt $deadline) {
        $iteration++
        $iterationDirectory = Join-Path $EvidenceDirectory ("iteration-{0:D4}" -f $iteration)
        $captureDirectory = Join-Path $iterationDirectory 'capture'
        New-Item -Path $captureDirectory -ItemType Directory -Force | Out-Null

        & $captureScript -VmNames $VmNames -OutputDirectory $captureDirectory

        $clusterReady = (Test-Port -Address $ClusterVip -Port 443) -or
            ((Test-Port -Address $ClusterVip -Port 6443) -and (Test-Port -Address '10.10.10.11' -Port 22))
        $states = New-Object System.Collections.Generic.List[object]
        $madeProgress = $false

        foreach ($vmName in $VmNames) {
            $text = Get-OcrText \
                -VmName $vmName \
                -CaptureDirectory $captureDirectory \
                -IterationDirectory $iterationDirectory
            $detected = Get-InstallerState -VmName $vmName -Text $text
            $state = [string]$detected.state
            $states.Add($detected)

            if ($lastState.ContainsKey($vmName) -and $lastState[$vmName] -eq $state) {
                $repeatCount[$vmName] = 1 + [int]$repeatCount[$vmName]
            }
            else {
                $repeatCount[$vmName] = 0
            }
            $lastState[$vmName] = $state

            Write-Host ("iteration={0} vm={1} state={2} repeat={3} clusterReady={4}" -f \
                $iteration, $vmName, $state, $repeatCount[$vmName], $clusterReady)

            if ($state -eq 'Error') {
                throw "$vmName console entered an installer error state."
            }
            if ($state -eq 'Installing') {
                $seenInstalling[$vmName] = $true
                continue
            }
            if ($state -eq 'InstallationComplete') {
                $seenInstalling[$vmName] = $true
                if (-not $bootPrepared.ContainsKey($vmName)) {
                    Set-InstalledBootConfiguration -VmName $vmName
                    $bootPrepared[$vmName] = $true
                    $madeProgress = $true
                }
                continue
            }
            if ($state -eq 'BootedInstalledSystem') {
                $bootPrepared[$vmName] = $true
                continue
            }

            $allowInstallation = $vmName -eq 'sen1' -or $clusterReady
            $actions = @(Get-ActionForState \
                -VmName $vmName \
                -State $state \
                -AllowInstallation $allowInstallation)
            if ($actions.Count -gt 0) {
                if ([int]$repeatCount[$vmName] -ge 3) {
                    throw "$vmName remained on state $state after three approved actions."
                }
                Invoke-ApprovedAction \
                    -VmName $vmName \
                    -Actions $actions \
                    -RequestId ("orchestrator-{0:D4}-{1}-{2}" -f $iteration, $vmName, $state) \
                    -IterationDirectory $iterationDirectory
                $madeProgress = $true
            }
            elseif ($state -eq 'Unknown' -and [int]$repeatCount[$vmName] -ge 2) {
                throw "$vmName remained on an unknown OCR state for three captures."
            }
        }

        Write-JsonFile -Value ([ordered]@{
            iteration = $iteration
            capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            clusterReady = $clusterReady
            states = @($states)
            seenInstalling = $seenInstalling
            bootPrepared = $bootPrepared
        }) -Path (Join-Path $iterationDirectory 'state.json')

        $allBooted = $true
        foreach ($vmName in $VmNames) {
            if (-not $bootPrepared.ContainsKey($vmName)) {
                $allBooted = $false
            }
        }
        if ($allBooted -and (Test-Port -Address $ClusterVip -Port 443)) {
            Write-Host 'All nodes booted from disk and cluster VIP TCP/443 is reachable.'
            break
        }

        if (-not $madeProgress) {
            Start-Sleep -Seconds $PollSeconds
        }
        else {
            Start-Sleep -Seconds 8
        }
    }

    if ((Get-Date) -ge $deadline) {
        throw "Installer orchestration exceeded the $MaximumMinutes minute deadline."
    }
}
catch {
    $terminalFailure = $_.Exception.Message
    Write-Error $terminalFailure
}
finally {
    try {
        $finalCapture = Join-Path $EvidenceDirectory 'final-capture'
        & $captureScript -VmNames $VmNames -OutputDirectory $finalCapture
    }
    catch {
        Write-Warning "Final console capture failed: $($_.Exception.Message)"
    }

    $summary = [ordered]@{
        schemaVersion = '1.0'
        completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        sourceRepository = $env:GITHUB_REPOSITORY
        sourceCommit = $env:GITHUB_SHA
        sourceRunId = $env:GITHUB_RUN_ID
        vmNames = $VmNames
        clusterVip = $ClusterVip
        iterations = $iteration
        seenInstalling = $seenInstalling
        bootPrepared = $bootPrepared
        vip443Reachable = Test-Port -Address $ClusterVip -Port 443
        sen1SshReachable = Test-Port -Address '10.10.10.11' -Port 22
        sen2SshReachable = Test-Port -Address '10.10.10.12' -Port 22
        sen3SshReachable = Test-Port -Address '10.10.10.13' -Port 22
        failure = $terminalFailure
        installationQualified = $false
        runtimeQualified = $false
        releaseApproved = $false
    }
    Write-JsonFile -Value $summary -Path (Join-Path $EvidenceDirectory 'summary.json')
    Stop-Transcript | Out-Null
}

if ($null -ne $terminalFailure) {
    throw $terminalFailure
}
