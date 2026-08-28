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
    param([Parameter(Mandatory=$true)][string]$ComputerName,[Parameter(Mandatory=$true)][int]$Port,[int]$TimeoutMs=2500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName,$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs,$false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Wait-Until {
    param([scriptblock]$Condition,[int]$TimeoutSeconds,[int]$IntervalSeconds=5,[string]$Description='condition')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Write-Host "Waiting for $Description ..."
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for $Description"
}

function Invoke-External {
    param([Parameter(Mandatory=$true)][string]$FilePath,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE" }
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
        if ($hash -ne $TalosctlSha256) { Remove-Item -Force $tmp -ErrorAction SilentlyContinue; throw "talosctl checksum mismatch: $hash" }
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
    } finally { Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue }

    $script:Talosctl = $talosctl
    $script:Talm = $talm
    Write-Host "Verified talosctl=$TalosVersion and talm=$TalmVersion"
}

function Test-AuthenticatedTalos([string]$IP) {
    $talosconfig = Join-Path $StateRoot 'talosconfig'
    if (-not (Test-Path $talosconfig)) { return $false }
    & $Talosctl --talosconfig $talosconfig version --nodes $IP --endpoints $IP *> $null
    return ($LASTEXITCODE -eq 0)
}

function Assert-HyperVSafety {
    Write-Section 'HYPER-V AND DISK SAFETY'
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Runner is not elevated.' }

    if (-not (Test-Path $IsoPath)) { throw "Cozystack ISO missing: $IsoPath" }
    $isoHash = (Get-FileHash -Algorithm SHA256 $IsoPath).Hash.ToLowerInvariant()
    if ($isoHash -ne $IsoSha256) { throw "Cozystack ISO checksum mismatch: $isoHash" }

    foreach ($node in $Nodes) {
        $vm = Get-VM -Name $node.Name -ErrorAction Stop
        $cpu = (Get-VMProcessor -VMName $node.Name).Count
        $mem = (Get-VMMemory -VMName $node.Name).Startup
        if ($cpu -lt 10) { throw "$($node.Name) has only $cpu vCPU" }
        if ($mem -lt 30GB) { throw "$($node.Name) has less than 30 GiB startup RAM" }
        if (-not (Get-VMProcessor -VMName $node.Name).ExposeVirtualizationExtensions) { throw "$($node.Name) nested virtualization is disabled" }
        $disks = @(Get-VMHardDiskDrive -VMName $node.Name)
        if ($disks.Count -ne 2) { throw "$($node.Name) must have exactly two VHD disks; found $($disks.Count)" }
        $vhdInfo = @($disks | ForEach-Object { Get-VHD -Path $_.Path })
        if (-not ($vhdInfo | Where-Object { $_.Size -ge 95GB -and $_.Size -le 110GB })) { throw "$($node.Name) 100-GB OS VHD not found" }
        if (-not ($vhdInfo | Where-Object { $_.Size -ge 290GB -and $_.Size -le 310GB })) { throw "$($node.Name) 300-GB data VHD not found" }
        if ($vm.State -eq 'Off') { Start-VM -Name $node.Name }
    }

    Wait-Until -TimeoutSeconds 120 -IntervalSeconds 5 -Description 'all Talos API endpoints on TCP/50000' -Condition {
        foreach ($node in $Nodes) { if (-not (Test-TcpPort $node.IP 50000 2000)) { return $false } }
        return $true
    }
}

function Assert-MaintenanceDiskIdentity([pscustomobject]$Node) {
    $lines = & $Talosctl get disks --insecure --nodes $Node.IP --endpoints $Node.IP 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$($Node.Name) maintenance disk discovery failed" }
    $osMatches = @($lines | Where-Object { $_ -match [regex]::Escape($Node.OsWwid) })
    $dataMatches = @($lines | Where-Object { $_ -match [regex]::Escape($Node.DataWwid) })
    if ($osMatches.Count -ne 1 -or $dataMatches.Count -ne 1) { throw "$($Node.Name) immutable WWID verification failed" }
    $osLine = ($osMatches[0] | Out-String)
    $dataLine = ($dataMatches[0] | Out-String)
    if ($osLine -notmatch '\bruntime\s+Disk\s+sda\s' -or $osLine -notmatch '\b107 GB\b') { throw "$($Node.Name) OS WWID is not /dev/sda 107 GB" }
    if ($dataLine -notmatch '\bruntime\s+Disk\s+sdb\s' -or $dataLine -notmatch '\b322 GB\b') { throw "$($Node.Name) data WWID is not /dev/sdb 322 GB" }
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
    } else { $values += "`r`nfloatingIP: `"$Vip`"`r`n" }
    if ($values -match '(?ms)^advertisedSubnets:\s*\[\]\s*$') {
        $values = [regex]::Replace($values,'(?ms)^advertisedSubnets:\s*\[\]\s*$',"advertisedSubnets:`r`n- $AdvertisedSubnet")
    } elseif ($values -notmatch '(?m)^advertisedSubnets:') {
        $values += "`r`nadvertisedSubnets:`r`n- $AdvertisedSubnet`r`n"
    }
    Set-Content -Path $valuesPath -Value $values -Encoding UTF8
    if ((Get-Content -Raw $valuesPath) -notmatch [regex]::Escape($TalosImage)) { throw 'Talm state is not pinned to expected Cozystack Talos image' }
    if (-not (Test-Path (Join-Path $StateRoot 'talosconfig'))) { throw 'Talm did not produce talosconfig' }
    New-Item -ItemType Directory -Force -Path (Join-Path $StateRoot 'nodes') | Out-Null
}

function Render-NodeConfig([pscustomobject]$Node) {
    $nodeFile = Join-Path $StateRoot "nodes\$($Node.Name).yaml"
    Push-Location $StateRoot
    try {
        $stderr = Join-Path $StateRoot "nodes\$($Node.Name).stderr.txt"
        & $Talm template -e $Node.IP --nodes $Node.IP -t templates/controlplane.yaml -i 1> $nodeFile 2> $stderr
        if ($LASTEXITCODE -ne 0) { $safe = Get-Content -Raw $stderr -ErrorAction SilentlyContinue; throw "talm template failed for $($Node.Name): $safe" }
        Remove-Item -Force $stderr -ErrorAction SilentlyContinue
    } finally { Pop-Location }
    $render = Get-Content -Raw $nodeFile
    if ($render -notmatch '(?m)^\s+disk:\s*["'']?/dev/sda["'']?\s*$') { throw "$($Node.Name) render does not install to /dev/sda" }
    if ($render -match '(?m)^\s+disk:\s*["'']?/dev/sdb["'']?\s*$') { throw "$($Node.Name) render attempts to install to /dev/sdb" }
    if ($render -notmatch [regex]::Escape($Node.OsWwid)) { throw "$($Node.Name) render lacks expected OS WWID evidence" }
    if ($render -notmatch [regex]::Escape($Vip)) { throw "$($Node.Name) render lacks VIP" }
    if ($render -notmatch [regex]::Escape($Node.Link)) { throw "$($Node.Name) render lacks management link" }
    return $nodeFile
}

function Install-TalosCluster {
    Write-Section 'TALOS INSTALL AND KUBERNETES BOOTSTRAP'
    Initialize-TalmProject

    foreach ($node in $Nodes) {
        if (Test-AuthenticatedTalos $node.IP) {
            Write-Host "$($node.Name) already has authenticated Talos configuration; preserving it."
            Get-VMDvdDrive -VMName $node.Name -ErrorAction SilentlyContinue | Set-VMDvdDrive -Path $null -ErrorAction SilentlyContinue
            continue
        }

        $version = (& $Talosctl version --insecure --nodes $node.IP --endpoints $node.IP 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $version -notmatch 'Tag:\s+v1\.13\.6') { throw "$($node.Name) is neither authenticated nor expected v1.13.6 maintenance mode" }
        Assert-MaintenanceDiskIdentity $node
        $nodeFile = Render-NodeConfig $node
        Push-Location $StateRoot
        try {
            Write-Host "Applying Talos to $($node.Name) OS disk /dev/sda. /dev/sdb remains untouched."
            Invoke-External $Talm 'apply' '-f' $nodeFile '-i'
        } finally { Pop-Location }
        Get-VMDvdDrive -VMName $node.Name -ErrorAction SilentlyContinue | Set-VMDvdDrive -Path $null -ErrorAction SilentlyContinue
    }

    Wait-Until -TimeoutSeconds 600 -IntervalSeconds 10 -Description 'authenticated Talos on all three installed nodes' -Condition {
        foreach ($node in $Nodes) { if (-not (Test-AuthenticatedTalos $node.IP)) { return $false } }
        return $true
    }

    if (-not (Test-TcpPort $Vip 6443 2500)) {
        Push-Location $StateRoot
        try { Invoke-External $Talm 'bootstrap' '-f' (Join-Path $StateRoot 'nodes\sen1.yaml') }
        finally { Pop-Location }
    } else { Write-Host "Kubernetes API on $Vip is already available; skipping etcd bootstrap." }

    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description "Kubernetes API on VIP $Vip" -Condition { Test-TcpPort $Vip 6443 2500 }

    Push-Location $StateRoot
    try {
        Invoke-External $Talm 'kubeconfig' '-f' (Join-Path $StateRoot 'nodes\sen1.yaml')
    } finally { Pop-Location }
    $kubeconfig = Join-Path $StateRoot 'kubeconfig'
    if (-not (Test-Path $kubeconfig)) { throw 'Talm did not produce kubeconfig' }
    $env:KUBECONFIG = $kubeconfig
}

function Assert-KubernetesTools {
    Write-Section 'KUBERNETES CLIENT TOOLS'
    $kubectl = Get-Command kubectl.exe -ErrorAction SilentlyContinue
    if (-not $kubectl) { $kubectl = Get-Command kubectl -ErrorAction SilentlyContinue }
    $helm = Get-Command helm.exe -ErrorAction SilentlyContinue
    if (-not $helm) { $helm = Get-Command helm -ErrorAction SilentlyContinue }
    if (-not $kubectl) { throw 'kubectl is required on the self-hosted runner before Cozystack installation' }
    if (-not $helm) { throw 'helm is required on the self-hosted runner before Cozystack installation' }
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
    } finally { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }
}

function Install-CozystackPlatform {
    Write-Section 'COZYSTACK 1.6.2 PLATFORM'
    Invoke-Kubectl 'get' 'nodes' '-o' 'wide'

    & $Helm upgrade --install cozystack oci://ghcr.io/cozystack/cozystack/cozy-installer --version $CozystackVersion --namespace cozy-system --create-namespace --wait --timeout 10m
    if ($LASTEXITCODE -ne 0) { throw 'Cozystack operator Helm installation failed' }

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

    Wait-Until -TimeoutSeconds 1800 -IntervalSeconds 15 -Description 'Cozystack LINSTOR controller deployment' -Condition {
        & $Kubectl get deployment -n cozy-linstor linstor-controller *> $null
        if ($LASTEXITCODE -ne 0) { return $false }
        $available = (& $Kubectl get deployment -n cozy-linstor linstor-controller -o jsonpath='{.status.availableReplicas}' 2>$null | Out-String).Trim()
        return ($available -match '^[1-9]')
    }
}

function Get-KubernetesNodeNameByIP([string]$IP) {
    $json = (& $Kubectl get nodes -o json | Out-String) | ConvertFrom-Json
    foreach ($item in $json.items) {
        foreach ($address in $item.status.addresses) {
            if ($address.type -eq 'InternalIP' -and $address.address -eq $IP) { return $item.metadata.name }
        }
    }
    throw "No Kubernetes node maps to InternalIP $IP"
}

function Invoke-Linstor([string[]]$Args) {
    & $Kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor @Args
    if ($LASTEXITCODE -ne 0) { throw "LINSTOR command failed: $($Args -join ' ')" }
}

function Configure-HCIStorage {
    Write-Section 'LINSTOR/ZFS ON /DEV/SDB'
    $nodeNames = @{}
    foreach ($node in $Nodes) { $nodeNames[$node.Name] = Get-KubernetesNodeNameByIP $node.IP }

    $physical = (& $Kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor physical-storage list 2>&1 | Out-String)
    $pools = (& $Kubectl exec -n cozy-linstor deploy/linstor-controller -- linstor storage-pool list 2>&1 | Out-String)
    foreach ($node in $Nodes) {
        $k8sName = $nodeNames[$node.Name]
        if ($pools -match "(?m).*\b$([regex]::Escape($k8sName))\b.*\bdata\b") {
            Write-Host "$k8sName already has LINSTOR data pool; preserving it."
            continue
        }
        if ($physical -notmatch [regex]::Escape("$k8sName[/dev/sdb]")) {
            throw "$k8sName does not expose blank /dev/sdb to LINSTOR and has no existing data pool; refusing destructive storage action"
        }
        Invoke-Linstor @('physical-storage','create-device-pool','zfs',$k8sName,'/dev/sdb','--pool-name','data','--storage-pool','data')
    }

    foreach ($node in $Nodes) {
        $k8sName = $nodeNames[$node.Name]
        & $Kubectl exec -n cozy-linstor "pod/linstor-satellite.$k8sName" -- zpool set failmode=continue data
        if ($LASTEXITCODE -ne 0) { throw "Failed to set ZFS failmode=continue on $k8sName" }
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
    Invoke-Linstor @('storage-pool','list')
    Invoke-Kubectl 'get' 'storageclass'
}

function Configure-NetworkingAndRootServices {
    Write-Section 'METALLB AND ROOT SERVICES'
    Wait-Until -TimeoutSeconds 900 -IntervalSeconds 10 -Description 'MetalLB CRDs' -Condition {
        & $Kubectl get crd ipaddresspools.metallb.io *> $null
        return ($LASTEXITCODE -eq 0)
    }

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
        & $Kubectl get -n tenant-root tenants.apps.cozystack.io root *> $null
        return ($LASTEXITCODE -eq 0)
    }
    Invoke-Kubectl 'patch' '-n' 'tenant-root' 'tenants.apps.cozystack.io' 'root' '--type=merge' '-p' '{"spec":{"ingress":true,"monitoring":true,"etcd":true}}'
}

function Final-ProductionLikeGates {
    Write-Section 'FINAL CLUSTER GATES'
    Invoke-Kubectl 'wait' '--for=condition=Ready' 'nodes' '--all' '--timeout=20m'

    Wait-Until -TimeoutSeconds 1800 -IntervalSeconds 20 -Description 'all Flux HelmReleases Ready=True' -Condition {
        $raw = & $Kubectl get hr -A -o json 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $obj = ($raw | Out-String) | ConvertFrom-Json
        if (-not $obj.items -or $obj.items.Count -eq 0) { return $false }
        foreach ($item in $obj.items) {
            $ready = $false
            foreach ($condition in @($item.status.conditions)) {
                if ($condition.type -eq 'Ready' -and $condition.status -eq 'True') { $ready = $true; break }
            }
            if (-not $ready) { Write-Host "Not ready: $($item.metadata.namespace)/$($item.metadata.name)"; return $false }
        }
        return $true
    }

    $sc = & $Kubectl get storageclass replicated -o jsonpath='{.provisioner}'
    if (($sc | Out-String).Trim() -ne 'linstor.csi.linbit.com') { throw 'replicated StorageClass is not backed by LINSTOR CSI' }

    Invoke-Kubectl 'get' 'nodes' '-o' 'wide'
    Invoke-Kubectl 'get' 'hr' '-A'
    Invoke-Kubectl 'get' 'pods' '-n' 'tenant-root'
    Invoke-Kubectl 'get' 'pvc' '-n' 'tenant-root'
    Invoke-Kubectl 'get' 'svc' '-n' 'tenant-root' 'root-ingress-controller' '-o' 'wide'
    Invoke-Kubectl 'get' 'kubevirt' '-A'
    Invoke-Kubectl 'get' 'storageclass'
}

function Write-Evidence {
    New-Item -ItemType Directory -Force -Path $DiagRoot | Out-Null
    $runId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { 'manual' }
    $path = Join-Path $DiagRoot "production-bootstrap-$runId.txt"
    @(
        "timestamp_utc=$([DateTime]::UtcNow.ToString('o'))"
        "head_sha=$env:GITHUB_SHA"
        "cluster=$ClusterName"
        "cluster_endpoint=$ClusterEndpoint"
        "talos_version=$TalosVersion"
        "cozystack_version=$CozystackVersion"
        "nodes=$($Nodes.IP -join ',')"
        "os_disk=/dev/sda"
        "data_disk=/dev/sdb"
        "storage=LINSTOR/ZFS + DRBD replicated"
        "metallb_pool=$MetalLBPool"
        "publishing_host=$PublishingHost"
        "NOTE=no kubeconfig, Talos secrets, tokens or private keys are stored in this evidence file"
    ) | Set-Content -Path $path -Encoding UTF8
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
    Write-Evidence
    Write-Host 'HCI bootstrap completed: Talos, Kubernetes, Cozystack, LINSTOR/ZFS, DRBD replicated storage, MetalLB and root services passed the configured gates.'
} catch {
    Write-Error $_
    try {
        Write-Section 'FAILURE DIAGNOSTICS'
        Get-VM -Name sen1,sen2,sen3 -ErrorAction SilentlyContinue | Format-Table Name,State,Status,CPUUsage,MemoryAssigned,Uptime -AutoSize
        foreach ($node in $Nodes) { Write-Host "$($node.IP) TCP50000=$(Test-TcpPort $node.IP 50000 1500) TCP6443=$(Test-TcpPort $node.IP 6443 1500)" }
        if ($script:Kubectl -and (Test-Path (Join-Path $StateRoot 'kubeconfig'))) {
            $env:KUBECONFIG = Join-Path $StateRoot 'kubeconfig'
            & $script:Kubectl get nodes -o wide 2>&1 | Select-Object -First 50 | ForEach-Object { Write-Host $_ }
            & $script:Kubectl get hr -A 2>&1 | Select-Object -First 100 | ForEach-Object { Write-Host $_ }
        }
    } catch { Write-Warning "Failure diagnostics also failed: $_" }
    Write-Evidence
    exit 1
}
