# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ClusterName = 'cozystack-hci-lab'
$ClusterEndpoint = 'https://10.10.10.10:6443'
$Vip = '10.10.10.10'
$Gateway = '10.10.10.1'
$AdvertisedSubnet = '10.10.10.0/24'
$TalosVersion = 'v1.13.6'
$TalosImage = 'ghcr.io/cozystack/cozystack/talos:v1.13.6'
$CozystackVersion = '1.6.2'
$StateRoot = 'C:\hci-state\cozystack-hci-lab'
$ToolsRoot = 'C:\hci-tools'
$DiagRoot = 'C:\hci-diagnostics'
$IsoPath = 'C:\HyperV\Cozystack\ISO\metal-amd64.iso'
$IsoSha256 = 'd925b18dde9262adbb0804a98a8161b7ebca16bf362c70a1bd40530281d519d6'
$TalosctlSha256 = '87289b89abc444e9428d067f4e4097757148f4c3283491444ef4cceb9cd58b07'
$TalmVersion = 'v0.34.0'
$TalmZipSha256 = '7b7925660c38bf51938648368d3995ce2e48b7422719e9c8d915e39dba6fc07b'
$MetalLBPool = '10.10.10.200-10.10.10.220'
$PublishingHost = '10-10-10-200.nip.io'

$Nodes = @(
    [pscustomobject]@{Name='sen1'; IP='10.10.10.11'; Link='enx00155d0a0a11'; Mac='00:15:5d:0a:0a:11'; OsWwid='naa.600224806f287aeacd4f9e6329e29270'; DataWwid='naa.600224806dc058308dd8a3bf014a297c'},
    [pscustomobject]@{Name='sen2'; IP='10.10.10.12'; Link='enx00155d0a0a12'; Mac='00:15:5d:0a:0a:12'; OsWwid='naa.60022480b49d2169f5708f59478f5f15'; DataWwid='naa.600224807175cdc319d108c6c7383188'},
    [pscustomobject]@{Name='sen3'; IP='10.10.10.13'; Link='enx00155d0a0a13'; Mac='00:15:5d:0a:0a:13'; OsWwid='naa.600224803650253d9f3d59ac3e984736'; DataWwid='naa.6002248070d1f838aed76ca81fff39a0'}
)

function Write-Section([string]$Text) {
    Write-Host "`n================ $Text ================"
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][int]$Port,
        [int]$TimeoutMs=2500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName,$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs,$false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Invoke-NativeText {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments=@()
    )
    $saved = $ErrorActionPreference
    $exitCode = 1
    $output = @()
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $output += $_.Exception.Message
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $saved
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Text = (($output | Out-String).TrimEnd())
        Lines = $output
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments
    )
    $probe = Invoke-NativeText -FilePath $FilePath -Arguments $Arguments
    if ($probe.Text) { Write-Host $probe.Text }
    if ($probe.ExitCode -ne 0) {
        throw "$FilePath failed with exit code $($probe.ExitCode)"
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Condition,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
        [int]$IntervalSeconds=5,
        [string]$Description='condition'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastTransientError = $null
    do {
        try {
            $result = @(& $Condition)
            if ($result.Count -gt 0 -and [bool]$result[-1]) { return }
        } catch {
            $lastTransientError = $_.Exception.Message
            Write-Host "Transient error while waiting for ${Description}: $lastTransientError"
        }
        if ((Get-Date) -ge $deadline) { break }
        Write-Host "Waiting for $Description ..."
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)

    if ($lastTransientError) {
        throw "Timed out waiting for $Description. Last transient error: $lastTransientError"
    }
    throw "Timed out waiting for $Description"
}

function Install-PinnedTools {
    Write-Section 'PINNED TALOS TOOLING'
    New-Item -ItemType Directory -Force -Path $ToolsRoot,$DiagRoot | Out-Null
    $curl = (Get-Command curl.exe -ErrorAction Stop).Source

    $talosctl = Join-Path $ToolsRoot 'talosctl.exe'
    $hash = if (Test-Path $talosctl) { (Get-FileHash -Algorithm SHA256 $talosctl).Hash.ToLowerInvariant() } else { '' }
    if ($hash -ne $TalosctlSha256) {
        $tmp = "$talosctl.download"
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Invoke-External $curl '--fail' '--location' '--connect-timeout' '10' '--max-time' '180' '--retry' '2' '--output' $tmp "https://github.com/siderolabs/talos/releases/download/$TalosVersion/talosctl-windows-amd64.exe"
        $hash = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLowerInvariant()
        if ($hash -ne $TalosctlSha256) {
            Remove-Item -Force $tmp -ErrorAction SilentlyContinue
            throw "talosctl checksum mismatch: $hash"
        }
        Move-Item -Force $tmp $talosctl
    }

    $talm = Join-Path $ToolsRoot 'talm.exe'
    $zip = Join-Path $ToolsRoot "talm-$TalmVersion-windows-amd64.zip"
    $zipHash = if (Test-Path $zip) { (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant() } else { '' }
    if ($zipHash -ne $TalmZipSha256) {
        Remove-Item -Force $zip -ErrorAction SilentlyContinue
        Invoke-External $curl '--fail' '--location' '--connect-timeout' '10' '--max-time' '180' '--retry' '2' '--output' $zip "https://github.com/cozystack/talm/releases/download/$TalmVersion/talm-windows-amd64.zip"
        $zipHash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
        if ($zipHash -ne $TalmZipSha256) { throw "talm archive checksum mismatch: $zipHash" }
    }

    $extract = Join-Path $env:TEMP "talm-install-$PID"
    Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $extract | Out-Null
    try {
        Expand-Archive -Path $zip -DestinationPath $extract -Force
        $candidate = Get-ChildItem $extract -Recurse -Filter talm.exe | Select-Object -First 1
        if (-not $candidate) { throw 'Verified talm archive contains no talm.exe' }
        Copy-Item -Force $candidate.FullName $talm
    } finally {
        Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
    }

    $script:Talosctl = $talosctl
    $script:Talm = $talm
    Write-Host "Verified talosctl=$TalosVersion and talm=$TalmVersion"
}

function Test-AuthenticatedTalos([string]$IP) {
    $talosconfig = Join-Path $StateRoot 'talosconfig'
    if (-not (Test-Path $talosconfig)) { return $false }
    $probe = Invoke-NativeText -FilePath $Talosctl -Arguments @(
        '--talosconfig',$talosconfig,'version','--nodes',$IP,'--endpoints',$IP
    )
    return ($probe.ExitCode -eq 0 -and $probe.Text -match 'Tag:\s+v1\.13\.6')
}

function Assert-HyperVSafety {
    Write-Section 'HYPER-V AND DISK SAFETY'
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Runner is not elevated.'
    }

    $talosconfig = Join-Path $StateRoot 'talosconfig'
    if (-not (Test-Path $talosconfig)) {
        foreach ($node in $Nodes) {
            $maintenance = Invoke-NativeText -FilePath $Talosctl -Arguments @(
                'version','--insecure','--nodes',$node.IP,'--endpoints',$node.IP
            )
            if ($maintenance.ExitCode -ne 0 -or $maintenance.Text -notmatch 'Tag:\s+v1\.13\.6') {
                throw "Talos state/talosconfig is missing while $($node.Name) is not provably in v1.13.6 maintenance mode; refusing reinstall or cluster reinitialization"
            }
        }
    }

    $authenticated = 0
    foreach ($node in $Nodes) {
        if (Test-AuthenticatedTalos $node.IP) { $authenticated++ }
    }

    if ($authenticated -lt $Nodes.Count) {
        if (-not (Test-Path $IsoPath)) {
            throw "Cozystack ISO missing while at least one node still needs Talos installation: $IsoPath"
        }
        $isoHash = (Get-FileHash -Algorithm SHA256 $IsoPath).Hash.ToLowerInvariant()
        if ($isoHash -ne $IsoSha256) { throw "Cozystack ISO checksum mismatch: $isoHash" }
    } else {
        Write-Host 'All three nodes already authenticate with Talos; install media is not required for resume.'
    }

    foreach ($node in $Nodes) {
        $vm = Get-VM -Name $node.Name -ErrorAction Stop
        $cpu = (Get-VMProcessor -VMName $node.Name).Count
        $mem = (Get-VMMemory -VMName $node.Name).Startup
        if ($cpu -lt 10) { throw "$($node.Name) has only $cpu vCPU" }
        if ($mem -lt 30GB) { throw "$($node.Name) has less than 30 GiB startup RAM" }
        if (-not (Get-VMProcessor -VMName $node.Name).ExposeVirtualizationExtensions) {
            throw "$($node.Name) nested virtualization is disabled"
        }
        $disks = @(Get-VMHardDiskDrive -VMName $node.Name)
        if ($disks.Count -ne 2) { throw "$($node.Name) must have exactly two VHD disks; found $($disks.Count)" }
        $vhdInfo = @($disks | ForEach-Object { Get-VHD -Path $_.Path })
        if (-not ($vhdInfo | Where-Object { $_.Size -ge 95GB -and $_.Size -le 110GB })) {
            throw "$($node.Name) 100-GB OS VHD not found"
        }
        if (-not ($vhdInfo | Where-Object { $_.Size -ge 290GB -and $_.Size -le 310GB })) {
            throw "$($node.Name) 300-GB data VHD not found"
        }
        if ($vm.State -eq 'Off') { Start-VM -Name $node.Name }
    }

    Wait-Until -TimeoutSeconds 120 -IntervalSeconds 5 -Description 'all Talos API endpoints on TCP/50000' -Condition {
        foreach ($node in $Nodes) {
            if (-not (Test-TcpPort $node.IP 50000 2000)) { return $false }
        }
        return $true
    }
}

function Assert-MaintenanceDiskIdentity([pscustomobject]$Node) {
    $probe = Invoke-NativeText -FilePath $Talosctl -Arguments @(
        'get','disks','--insecure','--nodes',$Node.IP,'--endpoints',$Node.IP
    )
    if ($probe.ExitCode -ne 0) { throw "$($Node.Name) maintenance disk discovery failed: $($probe.Text)" }
    $osMatches = @($probe.Lines | Where-Object { $_ -match [regex]::Escape($Node.OsWwid) })
    $dataMatches = @($probe.Lines | Where-Object { $_ -match [regex]::Escape($Node.DataWwid) })
    if ($osMatches.Count -ne 1 -or $dataMatches.Count -ne 1) {
        throw "$($Node.Name) immutable maintenance WWID verification failed"
    }
    $osLine = ($osMatches[0] | Out-String)
    $dataLine = ($dataMatches[0] | Out-String)
    if ($osLine -notmatch '\bruntime\s+Disk\s+sda\s' -or $osLine -notmatch '\b107 GB\b') {
        throw "$($Node.Name) expected OS WWID is not /dev/sda 107 GB"
    }
    if ($dataLine -notmatch '\bruntime\s+Disk\s+sdb\s' -or $dataLine -notmatch '\b322 GB\b') {
        throw "$($Node.Name) expected data WWID is not /dev/sdb 322 GB"
    }
}

function Assert-AuthenticatedDataDiskIdentity {
    param(
        [Parameter(Mandatory=$true)][pscustomobject]$Node,
        [switch]$RequireBlank
    )
    $talosconfig = Join-Path $StateRoot 'talosconfig'
    if (-not (Test-AuthenticatedTalos $Node.IP)) {
        throw "$($Node.Name) is not authenticated; refusing storage inspection"
    }

    $disks = Invoke-NativeText -FilePath $Talosctl -Arguments @(
        '--talosconfig',$talosconfig,'get','disks','--nodes',$Node.IP,'--endpoints',$Node.IP
    )
    if ($disks.ExitCode -ne 0) { throw "$($Node.Name) authenticated disk discovery failed: $($disks.Text)" }

    $osMatches = @($disks.Lines | Where-Object { $_ -match [regex]::Escape($Node.OsWwid) })
    $dataMatches = @($disks.Lines | Where-Object { $_ -match [regex]::Escape($Node.DataWwid) })
    if ($osMatches.Count -ne 1 -or $dataMatches.Count -ne 1) {
        throw "$($Node.Name) authenticated WWID verification failed"
    }
    $osLine = ($osMatches[0] | Out-String)
    $dataLine = ($dataMatches[0] | Out-String)
    if ($osLine -notmatch '\bruntime\s+Disk\s+sda\s' -or $osLine -notmatch '\b107 GB\b') {
        throw "$($Node.Name) expected OS WWID does not map to /dev/sda 107 GB"
    }
    if ($dataLine -notmatch '\bruntime\s+Disk\s+sdb\s' -or $dataLine -notmatch '\b322 GB\b') {
        throw "$($Node.Name) expected data WWID does not map to /dev/sdb 322 GB"
    }
    if ($Node.OsWwid -eq $Node.DataWwid) { throw "$($Node.Name) OS and data WWIDs collide" }

    $mounts = Invoke-NativeText -FilePath $Talosctl -Arguments @(
        '--talosconfig',$talosconfig,'get','mounts','--nodes',$Node.IP,'--endpoints',$Node.IP
    )
    if ($mounts.ExitCode -ne 0) { throw "$($Node.Name) mount discovery failed: $($mounts.Text)" }
    if ($mounts.Text -match '(?m)\s/dev/sdb(?:\s|\d)') {
        throw "$($Node.Name) /dev/sdb is mounted; refusing storage mutation"
    }

    if ($RequireBlank) {
        $volumes = Invoke-NativeText -FilePath $Talosctl -Arguments @(
            '--talosconfig',$talosconfig,'get','discoveredvolumes','--nodes',$Node.IP,'--endpoints',$Node.IP,'-o','yaml'
        )
        if ($volumes.ExitCode -ne 0) {
            throw "$($Node.Name) discovered-volume inspection failed: $($volumes.Text)"
        }
        $docs = @($volumes.Text -split '(?m)^---\s*$')
        $sdbDocs = @($docs | Where-Object {
            $_ -match '(?m)^\s+id:\s+sdb\s*$' -and $_ -match '(?m)^\s+dev_path:\s+/dev/sdb\s*$'
        })
        if ($sdbDocs.Count -ne 1) {
            throw "$($Node.Name) expected exactly one whole-disk /dev/sdb discovered-volume record; found $($sdbDocs.Count)"
        }
        $sdb = $sdbDocs[0]
        if ($sdb -notmatch '(?m)^\s+size:\s+322122547200\s*$') {
            throw "$($Node.Name) /dev/sdb size is not exactly 322122547200 bytes"
        }
        if ($sdb -notmatch '(?m)^\s+name:\s+""\s*$') {
            throw "$($Node.Name) /dev/sdb has a discovered filesystem/signature; refusing initialization"
        }
        if ($volumes.Text -match '(?m)^\s+(?:id:\s+sdb\d+|dev_path:\s+/dev/sdb\d+)\s*$') {
            throw "$($Node.Name) /dev/sdb has partitions; refusing initialization"
        }
    }

    Write-Host "$($Node.Name) data disk verified: /dev/sdb WWID=$($Node.DataWwid) blankRequired=$RequireBlank"
}

function Initialize-TalmProject {
    Write-Section 'TALM STATE'
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
    & icacls $StateRoot /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null

    $chart = Join-Path $StateRoot 'Chart.yaml'
    if (-not (Test-Path $chart)) {
        $endpointList = ($Nodes.IP -join ',')
        Invoke-External $Talm 'init' '--root' $StateRoot '--preset' 'cozystack' '--name' $ClusterName '--endpoints' $endpointList '--cluster-endpoint' $ClusterEndpoint '--image' $TalosImage '--talos-version' $TalosVersion '--force'
    } else {
        Write-Host 'Existing secured Talm project found; preserving cluster CA, tokens and encryption material.'
    }

    $valuesPath = Join-Path $StateRoot 'values.yaml'
    $values = Get-Content -Raw $valuesPath
    if ($values -match '(?m)^floatingIP:\s*.*$') {
        $values = [regex]::Replace($values,'(?m)^floatingIP:\s*.*$',"floatingIP: `"$Vip`"")
    } else {
        $values += "`r`nfloatingIP: `"$Vip`"`r`n"
    }
    if ($values -match '(?ms)^advertisedSubnets:\s*\[\]\s*$') {
        $values = [regex]::Replace($values,'(?ms)^advertisedSubnets:\s*\[\]\s*$',"advertisedSubnets:`r`n- $AdvertisedSubnet")
    } elseif ($values -notmatch '(?m)^advertisedSubnets:') {
        $values += "`r`nadvertisedSubnets:`r`n- $AdvertisedSubnet`r`n"
    }
    Set-Content -Path $valuesPath -Value $values -Encoding UTF8

    if ((Get-Content -Raw $valuesPath) -notmatch [regex]::Escape($TalosImage)) {
        throw 'Talm state is not pinned to expected Cozystack Talos image'
    }
    if (-not (Test-Path (Join-Path $StateRoot 'talosconfig'))) { throw 'Talm did not produce talosconfig' }
    New-Item -ItemType Directory -Force -Path (Join-Path $StateRoot 'nodes') | Out-Null

    $hostnameHelper = Join-Path $StateRoot 'charts\talm\templates\_helpers.tpl'
    if (-not (Test-Path $hostnameHelper)) { throw "Talm hostname helper missing: $hostnameHelper" }
    $hostnameTemplate = Get-Content -Raw $hostnameHelper
    $hostnamePattern = '(?m)^kind: HostnameConfig\r?\nhostname: \{\{ include "talm\.discovered\.hostname" \. \| quote \}\}$'
    $hostnameMatches = ([regex]::Matches($hostnameTemplate,$hostnamePattern)).Count
    if ($hostnameMatches -eq 1) {
        $replacement = "kind: HostnameConfig`r`nauto: off`r`nhostname: {{ include `"talm.discovered.hostname`" . | quote }}"
        $hostnameTemplate = [regex]::Replace($hostnameTemplate,$hostnamePattern,$replacement,1)
        Set-Content -Path $hostnameHelper -Value $hostnameTemplate -Encoding UTF8
        Write-Host 'Normalized Talos v1.13 HostnameConfig to auto: off plus static hostname.'
    } elseif ($hostnameTemplate -match '(?m)^kind: HostnameConfig\r?\nauto: off\r?\nhostname: \{\{ include "talm\.discovered\.hostname" \. \| quote \}\}$') {
        Write-Host 'Talos v1.13 HostnameConfig normalization already present.'
    } else {
        throw "Expected exactly one Talm HostnameConfig template; found $hostnameMatches unnormalized matches."
    }
}

function Render-NodeConfig([pscustomobject]$Node) {
    $nodeFile = Join-Path $StateRoot "nodes\$($Node.Name).yaml"
    Push-Location $StateRoot
    try {
        $stderr = Join-Path $StateRoot "nodes\$($Node.Name).stderr.txt"
        $saved = $ErrorActionPreference
        $exitCode = 1
        try {
            $ErrorActionPreference = 'Continue'
            & $Talm template -e $Node.IP --nodes $Node.IP -t templates/controlplane.yaml -i 1> $nodeFile 2> $stderr
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $saved
        }
        if ($exitCode -ne 0) {
            $safe = Get-Content -Raw $stderr -ErrorAction SilentlyContinue
            throw "talm template failed for $($Node.Name): $safe"
        }
        Remove-Item -Force $stderr -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }

    $render = Get-Content -Raw $nodeFile
    if ($render -notmatch '(?m)^\s+disk:\s*["'']?/dev/sda["'']?\s*$') {
        throw "$($Node.Name) render does not install to /dev/sda"
    }
    if ($render -match '(?m)^\s+disk:\s*["'']?/dev/sdb["'']?\s*$') {
        throw "$($Node.Name) render attempts to install to /dev/sdb"
    }
    if ($render -notmatch [regex]::Escape($Node.OsWwid)) { throw "$($Node.Name) render lacks expected OS WWID evidence" }
    if ($render -notmatch [regex]::Escape($Vip)) { throw "$($Node.Name) render lacks VIP" }
    if ($render -notmatch [regex]::Escape($Node.Link)) { throw "$($Node.Name) render lacks management link" }
    return $nodeFile
}

function Install-TalosCluster {
    Write-Section 'TALOS INSTALL AND KUBERNETES BOOTSTRAP'
    Initialize-TalmProject
    $installedThisRun = $false

    foreach ($node in $Nodes) {
        if (Test-AuthenticatedTalos $node.IP) {
            Write-Host "$($node.Name) already has authenticated Talos configuration; preserving it."
            Get-VMDvdDrive -VMName $node.Name -ErrorAction SilentlyContinue |
                Set-VMDvdDrive -Path $null -ErrorAction SilentlyContinue
            continue
        }

        $version = Invoke-NativeText -FilePath $Talosctl -Arguments @(
            'version','--insecure','--nodes',$node.IP,'--endpoints',$node.IP
        )
        if ($version.ExitCode -ne 0 -or $version.Text -notmatch 'Tag:\s+v1\.13\.6') {
            throw "$($node.Name) is neither authenticated nor expected v1.13.6 maintenance mode"
        }

        Assert-MaintenanceDiskIdentity $node
        $nodeFile = Render-NodeConfig $node
        Push-Location $StateRoot
        try {
            Write-Host "Applying Talos to $($node.Name) OS disk /dev/sda. /dev/sdb remains untouched."
            Invoke-External $Talm '--nodes' $node.IP '--endpoints' $node.IP 'apply' '-f' $nodeFile '-i'
            $installedThisRun = $true
        } finally {
            Pop-Location
        }

        Get-VMDvdDrive -VMName $node.Name -ErrorAction SilentlyContinue |
            Set-VMDvdDrive -Path $null -ErrorAction SilentlyContinue
    }

    Wait-Until -TimeoutSeconds 600 -IntervalSeconds 10 -Description 'authenticated Talos on all three nodes' -Condition {
        foreach ($node in $Nodes) {
            if (-not (Test-AuthenticatedTalos $node.IP)) { return $false }
        }
        return $true
    }

    if (-not (Test-TcpPort $Vip 6443 2500)) {
        if (-not $installedThisRun) {
            throw "Kubernetes API VIP $Vip is unavailable on an already-authenticated cluster; refusing to bootstrap etcd again"
        }
        Invoke-External $Talosctl '--talosconfig' (Join-Path $StateRoot 'talosconfig') 'bootstrap' '--nodes' $Nodes[0].IP '--endpoints' $Nodes[0].IP
    } else {
        Write-Host "Kubernetes API on $Vip is already available; skipping etcd bootstrap."
    }

    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description "Kubernetes API on VIP $Vip" -Condition {
        Test-TcpPort $Vip 6443 2500
    }

    Invoke-External $Talosctl '--talosconfig' (Join-Path $StateRoot 'talosconfig') 'kubeconfig' (Join-Path $StateRoot 'kubeconfig') '--force' '--merge=false' '--nodes' $Nodes[0].IP '--endpoints' $Nodes[0].IP
    $kubeconfig = Join-Path $StateRoot 'kubeconfig'
    if (-not (Test-Path $kubeconfig)) { throw 'talosctl did not produce kubeconfig' }
    $env:KUBECONFIG = $kubeconfig
}

function Assert-KubernetesTools {
    Write-Section 'KUBERNETES CLIENT TOOLS'
    $kubectl = Get-Command kubectl.exe -ErrorAction SilentlyContinue
    if (-not $kubectl) { $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue }
    $helm = Get-Command helm.exe -ErrorAction SilentlyContinue
    if (-not $helm) { $helm = Get-Command helm -ErrorAction SilentlyContinue }
    if (-not $kubectl) { throw 'kubectl is required on the self-hosted runner' }
    if (-not $helm) { throw 'helm is required on the self-hosted runner' }
    $script:Kubectl = $kubectl.Source
    $script:Helm = $helm.Source
    Invoke-External $Kubectl 'version' '--client'
    Invoke-External $Helm 'version'
}

function Invoke-Kubectl {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    Invoke-External $Kubectl @Arguments
}

function Apply-YamlText([string]$Yaml) {
    $tmp = Join-Path $env:TEMP "hci-$([guid]::NewGuid().ToString('N')).yaml"
    try {
        Set-Content -Path $tmp -Value $Yaml -Encoding UTF8
        Invoke-Kubectl 'apply' '-f' $tmp
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Get-KubectlObject {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $allArgs = @($Arguments + @('-o','json'))
    $probe = Invoke-NativeText -FilePath $Kubectl -Arguments $allArgs
    if ($probe.ExitCode -ne 0 -or -not $probe.Text) { return $null }
    try { return ($probe.Text | ConvertFrom-Json) } catch { return $null }
}

function Test-KubernetesReadyCondition {
    param([Parameter(Mandatory=$true)][string[]]$GetArguments)
    $obj = Get-KubectlObject -Arguments $GetArguments
    if (-not $obj) { return $false }
    foreach ($condition in @($obj.status.conditions)) {
        if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') { return $true }
    }
    return $false
}

function Wait-CrdEstablished([string]$Name,[int]$TimeoutSeconds=900) {
    Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 10 -Description "CRD $Name Established" -Condition {
        $obj = Get-KubectlObject -Arguments @('get','crd',$Name)
        if (-not $obj) { return $false }
        foreach ($condition in @($obj.status.conditions)) {
            if ($condition.type -eq 'Established' -and $condition.status -eq 'True') { return $true }
        }
        return $false
    }
}

function Wait-HelmReleaseReady([string]$Namespace,[string]$Name,[int]$TimeoutSeconds=1800) {
    Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 15 -Description "HelmRelease $Namespace/$Name Ready" -Condition {
        Test-KubernetesReadyCondition -GetArguments @('get','hr','-n',$Namespace,$Name)
    }
}

function Wait-DeploymentAvailable([string]$Namespace,[string]$Name,[int]$TimeoutSeconds=900) {
    Wait-Until -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 10 -Description "deployment $Namespace/$Name available" -Condition {
        $obj = Get-KubectlObject -Arguments @('get','deployment','-n',$Namespace,$Name)
        if (-not $obj) { return $false }
        return ([int]$obj.status.availableReplicas -ge 1)
    }
}

function Install-CozystackPlatform {
    Write-Section 'LAYERSENTRY / COZYSTACK 1.6.2 PLATFORM'
    Invoke-Kubectl 'get' 'nodes' '-o' 'wide'

    $installerUri = [string]$env:LAYERSENTRY_INSTALLER_URI
    if ($installerUri -notmatch '^oci://ghcr\.io/adaptgurus/cozystack/cozy-installer@sha256:[0-9a-f]{64}$') {
        throw "Digest-pinned LayerSentry installer is required; got '$installerUri'"
    }

    Invoke-External $Helm 'upgrade' '--install' 'cozystack' $installerUri '--namespace' 'cozy-system' '--create-namespace' '--wait' '--timeout' '10m'
    Wait-DeploymentAvailable -Namespace 'cozy-system' -Name 'cozystack-operator' -TimeoutSeconds 900
    Wait-CrdEstablished -Name 'packages.cozystack.io' -TimeoutSeconds 900
    Wait-CrdEstablished -Name 'packagesources.cozystack.io' -TimeoutSeconds 900

    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description 'custom Cozystack platform PackageSource Ready' -Condition {
        Test-KubernetesReadyCondition -GetArguments @('get','packagesources.cozystack.io','cozystack.cozystack-platform')
    }

    $platform = @"
apiVersion: cozystack.io/v1alpha1
kind: Package
metadata:
  name: cozystack.cozystack-platform
spec:
  variant: isp-full
  components:
    platform:
      values:
        publishing:
          host: "$PublishingHost"
          apiServerEndpoint: "$ClusterEndpoint"
          exposedServices:
            - dashboard
            - api
        networking:
          podCIDR: "10.244.0.0/16"
          podGateway: "10.244.0.1"
          serviceCIDR: "10.96.0.0/16"
          joinCIDR: "100.64.0.0/16"
"@
    Apply-YamlText $platform

    Wait-Until -TimeoutSeconds 300 -IntervalSeconds 5 -Description 'platform Package accepted by API' -Condition {
        $probe = Invoke-NativeText -FilePath $Kubectl -Arguments @(
            'get','packages.cozystack.io','cozystack.cozystack-platform','-o','name'
        )
        return ($probe.ExitCode -eq 0)
    }

    Wait-HelmReleaseReady -Namespace 'cozy-cilium' -Name 'cilium' -TimeoutSeconds 1800
    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description 'Cilium DaemonSet ready on all three nodes' -Condition {
        $obj = Get-KubectlObject -Arguments @('get','ds','-n','cozy-cilium','cilium')
        if (-not $obj) { return $false }
        return ([int]$obj.status.desiredNumberScheduled -eq 3 -and [int]$obj.status.numberReady -eq 3)
    }

    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description 'all three Kubernetes nodes Ready' -Condition {
        $obj = Get-KubectlObject -Arguments @('get','nodes')
        if (-not $obj -or @($obj.items).Count -ne 3) { return $false }
        foreach ($item in @($obj.items)) {
            $ready = $false
            foreach ($condition in @($item.status.conditions)) {
                if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') {
                    $ready = $true
                    break
                }
            }
            if (-not $ready) { return $false }
        }
        return $true
    }

    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description 'cozy-linstor namespace' -Condition {
        $probe = Invoke-NativeText -FilePath $Kubectl -Arguments @('get','namespace','cozy-linstor','-o','name')
        return ($probe.ExitCode -eq 0)
    }
    foreach ($hr in 'piraeus-operator-crds','piraeus-operator','linstor','linstor-scheduler') {
        Wait-HelmReleaseReady -Namespace 'cozy-linstor' -Name $hr -TimeoutSeconds 1800
    }
    Wait-DeploymentAvailable -Namespace 'cozy-linstor' -Name 'linstor-controller' -TimeoutSeconds 1800
}

function Get-KubernetesNodeNameByIP([string]$IP) {
    $obj = Get-KubectlObject -Arguments @('get','nodes')
    if (-not $obj) { throw 'Kubernetes node inventory failed' }
    foreach ($item in @($obj.items)) {
        foreach ($address in @($item.status.addresses)) {
            if ($address.type -eq 'InternalIP' -and $address.address -eq $IP) {
                return [string]$item.metadata.name
            }
        }
    }
    throw "No Kubernetes node maps to InternalIP $IP"
}

function Invoke-Linstor([string[]]$LinstorArgs) {
    $allArgs = @('exec','-n','cozy-linstor','deploy/linstor-controller','--','linstor') + @($LinstorArgs)
    Invoke-External $Kubectl @allArgs
}

function Get-LinstorText([string[]]$LinstorArgs) {
    $allArgs = @('exec','-n','cozy-linstor','deploy/linstor-controller','--','linstor') + @($LinstorArgs)
    return (Invoke-NativeText -FilePath $Kubectl -Arguments $allArgs)
}

function Get-LinstorSatellitePodForNode([string]$NodeName) {
    $pods = Get-KubectlObject -Arguments @('get','pods','-n','cozy-linstor')
    if (-not $pods) { throw 'LINSTOR satellite pod inventory failed' }

    $matches = @($pods.items | Where-Object {
        $podName = [string]$_.metadata.name
        [string]$_.spec.nodeName -eq $NodeName -and
        ($podName -eq "linstor-satellite.$NodeName" -or $podName.StartsWith("linstor-satellite.$NodeName-"))
    })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one LINSTOR satellite pod on $NodeName; found $($matches.Count)"
    }

    $pod = $matches[0]
    if ([string]$pod.status.phase -ne 'Running') {
        throw "LINSTOR satellite pod $($pod.metadata.name) on $NodeName is not Running"
    }
    foreach ($container in @($pod.status.containerStatuses)) {
        if (-not [bool]$container.ready) {
            throw "LINSTOR satellite pod $($pod.metadata.name) on $NodeName has a non-ready container $($container.name)"
        }
    }
    return [string]$pod.metadata.name
}

function Configure-HCIStorage {
    Write-Section 'LINSTOR/ZFS ON VERIFIED /DEV/SDB'
    $nodeNames = @{}
    foreach ($node in $Nodes) {
        $nodeNames[$node.Name] = Get-KubernetesNodeNameByIP $node.IP
    }

    foreach ($node in $Nodes) {
        $k8sName = $nodeNames[$node.Name]
        $pools = Get-LinstorText @('storage-pool','list')
        if ($pools.ExitCode -ne 0) {
            throw "LINSTOR storage-pool inventory failed: $($pools.Text)"
        }

        $hasPool = ($pools.Text -match "(?m).*\b$([regex]::Escape($k8sName))\b.*\bdata\b")
        if ($hasPool) {
            Assert-AuthenticatedDataDiskIdentity -Node $node
            Write-Host "$k8sName already has LINSTOR data pool; preserving it."
            continue
        }

        # Destructive mutation boundary: authenticated WWID, size, mount and blank-signature checks
        # are deliberately re-read immediately before physical-storage create-device-pool.
        Assert-AuthenticatedDataDiskIdentity -Node $node -RequireBlank

        $physical = Get-LinstorText @('physical-storage','list')
        if ($physical.ExitCode -ne 0) {
            throw "LINSTOR physical-storage inventory failed: $($physical.Text)"
        }
        if ($physical.Text -notmatch [regex]::Escape("$k8sName[/dev/sdb]")) {
            throw "$k8sName does not expose verified blank /dev/sdb to LINSTOR; refusing destructive storage action"
        }

        # Re-read identity a second time after LINSTOR inventory to close the TOCTOU window.
        Assert-AuthenticatedDataDiskIdentity -Node $node -RequireBlank
        Invoke-Linstor @('physical-storage','create-device-pool','zfs',$k8sName,'/dev/sdb','--pool-name','data','--storage-pool','data')

        Wait-Until -TimeoutSeconds 300 -IntervalSeconds 10 -Description "LINSTOR data pool on $k8sName" -Condition {
            $verify = Get-LinstorText @('storage-pool','list')
            return (
                $verify.ExitCode -eq 0 -and
                $verify.Text -match "(?m).*\b$([regex]::Escape($k8sName))\b.*\bdata\b"
            )
        }
        Write-Host "$k8sName data pool created and re-read successfully before continuing."
    }

    foreach ($node in $Nodes) {
        $k8sName = $nodeNames[$node.Name]
        $podName = Get-LinstorSatellitePodForNode -NodeName $k8sName
        Invoke-External $Kubectl 'exec' '-n' 'cozy-linstor' "pod/$podName" '--' 'zpool' 'set' 'failmode=continue' 'data'
    }

    $storageClasses = @'
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "data"
  linstor.csi.linbit.com/layerList: "storage"
  linstor.csi.linbit.com/allowRemoteVolumeAccess: "false"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: replicated
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "data"
  linstor.csi.linbit.com/autoPlace: "3"
  linstor.csi.linbit.com/layerList: "drbd storage"
  linstor.csi.linbit.com/allowRemoteVolumeAccess: "true"
  property.linstor.csi.linbit.com/DrbdOptions/auto-quorum: suspend-io
  property.linstor.csi.linbit.com/DrbdOptions/Resource/on-no-data-accessible: suspend-io
  property.linstor.csi.linbit.com/DrbdOptions/Resource/on-suspended-primary-outdated: force-secondary
  property.linstor.csi.linbit.com/DrbdOptions/Net/rr-conflict: retry-connect
volumeBindingMode: Immediate
allowVolumeExpansion: true
'@
    Apply-YamlText $storageClasses

    Wait-Until -TimeoutSeconds 300 -IntervalSeconds 10 -Description 'three LINSTOR data storage pools' -Condition {
        $pools = Get-LinstorText @('storage-pool','list')
        if ($pools.ExitCode -ne 0) { return $false }
        foreach ($node in $Nodes) {
            $k8sName = $nodeNames[$node.Name]
            if ($pools.Text -notmatch "(?m).*\b$([regex]::Escape($k8sName))\b.*\bdata\b") {
                return $false
            }
        }
        return $true
    }

    $replicated = Invoke-NativeText -FilePath $Kubectl -Arguments @(
        'get','storageclass','replicated','-o','jsonpath={.provisioner}'
    )
    if ($replicated.ExitCode -ne 0 -or $replicated.Text.Trim() -ne 'linstor.csi.linbit.com') {
        throw 'replicated StorageClass is not backed by LINSTOR CSI'
    }

    Invoke-Linstor @('storage-pool','list')
    Invoke-Kubectl 'get' 'storageclass'
}

function Configure-NetworkingAndRootServices {
    Write-Section 'METALLB AND ROOT SERVICES'
    Wait-CrdEstablished -Name 'ipaddresspools.metallb.io' -TimeoutSeconds 900
    Wait-CrdEstablished -Name 'l2advertisements.metallb.io' -TimeoutSeconds 900

    $networking = @"
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: cozystack
  namespace: cozy-metallb
spec:
  addresses:
    - $MetalLBPool
  autoAssign: true
  avoidBuggyIPs: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: cozystack
  namespace: cozy-metallb
spec:
  ipAddressPools:
    - cozystack
"@
    Apply-YamlText $networking

    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description 'root tenant CR' -Condition {
        $probe = Invoke-NativeText -FilePath $Kubectl -Arguments @(
            'get','-n','tenant-root','tenants.apps.cozystack.io','root','-o','name'
        )
        return ($probe.ExitCode -eq 0)
    }

    Invoke-Kubectl 'patch' '-n' 'tenant-root' 'tenants.apps.cozystack.io' 'root' '--type=merge' '-p' '{"spec":{"ingress":true,"monitoring":true,"etcd":true}}'
}

function Final-ProductionLikeGates {
    Write-Section 'FINAL BASELINE CLUSTER GATES'
    Invoke-Kubectl 'wait' '--for=condition=Ready' 'nodes' '--all' '--timeout=20m'

    foreach ($pair in @(
        @('cozy-cilium','cilium'),
        @('cozy-linstor','piraeus-operator-crds'),
        @('cozy-linstor','piraeus-operator'),
        @('cozy-linstor','linstor'),
        @('cozy-linstor','linstor-scheduler')
    )) {
        Wait-HelmReleaseReady -Namespace $pair[0] -Name $pair[1] -TimeoutSeconds 1800
    }

    $replicated = Invoke-NativeText -FilePath $Kubectl -Arguments @(
        'get','storageclass','replicated','-o','jsonpath={.provisioner}'
    )
    if ($replicated.ExitCode -ne 0 -or $replicated.Text.Trim() -ne 'linstor.csi.linbit.com') {
        throw 'replicated StorageClass gate failed'
    }

    Invoke-Kubectl 'get' 'nodes' '-o' 'wide'
    Invoke-Kubectl 'get' 'hr' '-A'
    Invoke-Kubectl 'get' 'storageclass'
    Invoke-Kubectl 'get' 'kubevirt' '-A'
    Invoke-Kubectl 'get' 'cdi' '-A'
    Invoke-Kubectl 'get' 'pods' '-n' 'cozy-linstor' '-o' 'wide'
}

function Write-Evidence([string]$Result) {
    New-Item -ItemType Directory -Force -Path $DiagRoot | Out-Null
    $runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'manual' }
    $path = Join-Path $DiagRoot "production-bootstrap-$runId.txt"

    $lines = @(
        "timestamp_utc=$([DateTime]::UtcNow.ToString('o'))",
        "result=$Result",
        "orchestration_sha=$env:GITHUB_SHA",
        "runtime_source_sha=$env:LAYERSENTRY_RUNTIME_SOURCE_SHA",
        "cluster=$ClusterName",
        "cluster_endpoint=$ClusterEndpoint",
        "talos_version=$TalosVersion",
        "cozystack_version=$CozystackVersion",
        "nodes=$($Nodes.IP -join ',')",
        "data_wwid_sen1=$($Nodes[0].DataWwid)",
        "data_wwid_sen2=$($Nodes[1].DataWwid)",
        "data_wwid_sen3=$($Nodes[2].DataWwid)",
        "os_disk=/dev/sda",
        "data_disk=/dev/sdb",
        "storage=LINSTOR/ZFS + DRBD replicated",
        "metallb_pool=$MetalLBPool",
        "publishing_host=$PublishingHost",
        "NOTE=no kubeconfig, Talos secrets, tokens or private keys are stored in this evidence file"
    )
    $lines | Set-Content -Path $path -Encoding UTF8
    Write-Host "Non-secret evidence: $path"
}

try {
    Install-PinnedTools
    Assert-HyperVSafety
    Install-TalosCluster
    Assert-KubernetesTools
    Install-CozystackPlatform
    Configure-HCIStorage
    Configure-NetworkingAndRootServices
    Final-ProductionLikeGates
    Write-Evidence -Result 'PASS'
    Write-Host 'LayerSentry HCI bootstrap/resume baseline completed through verified LINSTOR/ZFS, DRBD StorageClass and MetalLB/root-services configuration.'
} catch {
    Write-Error $_
    try {
        Write-Section 'FAILURE DIAGNOSTICS'
        Get-VM -Name sen1,sen2,sen3 -ErrorAction SilentlyContinue |
            Format-Table Name,State,Status,CPUUsage,MemoryAssigned,Uptime -AutoSize
        foreach ($node in $Nodes) {
            Write-Host "$($node.IP) TCP50000=$(Test-TcpPort $node.IP 50000 1500) TCP6443=$(Test-TcpPort $node.IP 6443 1500)"
        }
        if ($script:Kubectl -and (Test-Path (Join-Path $StateRoot 'kubeconfig'))) {
            $env:KUBECONFIG = Join-Path $StateRoot 'kubeconfig'
            & $script:Kubectl get nodes -o wide 2>&1 | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
            & $script:Kubectl get hr -A 2>&1 | Select-Object -First 150 | ForEach-Object { Write-Host $_ }
            & $script:Kubectl get pods -A -o wide 2>&1 | Select-Object -First 250 | ForEach-Object { Write-Host $_ }
        }
    } catch {
        Write-Warning "Failure diagnostics also failed: $_"
    }
    Write-Evidence -Result 'FAIL'
    exit 1
}
