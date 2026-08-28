# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$Kubeconfig = 'C:\hci-state\cozystack-hci-lab\kubeconfig',
    [string]$KubectlPath = 'C:\hci-tools\kubectl.exe',
    [string]$TenantNamespace = 'tenant-root',
    [string]$EvidenceRoot = 'C:\hci-diagnostics'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-NativeText {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments=@(),
        [string]$StdinText=$null
    )
    $saved = $ErrorActionPreference
    $exitCode = 1
    $output = @()
    try {
        $ErrorActionPreference = 'Continue'
        if ($null -ne $StdinText) {
            $output = @($StdinText | & $FilePath @Arguments 2>&1)
        } else {
            $output = @(& $FilePath @Arguments 2>&1)
        }
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

function Invoke-KubectlText {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments $Arguments
    if ($probe.ExitCode -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed with exit code $($probe.ExitCode): $($probe.Text)"
    }
    return $probe.Text
}

function Test-KubectlObjectAbsent {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments $Arguments
    return ($probe.ExitCode -ne 0)
}

function Wait-Until {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Condition,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
        [int]$IntervalSeconds=5,
        [string]$Description='condition'
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            if (& $Condition) { return }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    if ($lastError) { throw "Timed out waiting for $Description. Last error: $lastError" }
    throw "Timed out waiting for $Description"
}

function Get-HelmReleaseReady([string]$Name) {
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','helmrelease.helm.toolkit.fluxcd.io','-n',$TenantNamespace,$Name,'-o','json')
    if ($probe.ExitCode -ne 0) { return $false }
    $hr = $probe.Text | ConvertFrom-Json
    $ready = @($hr.status.conditions | Where-Object { $_.type -eq 'Ready' })
    return ($ready.Count -ge 1 -and $ready[0].status -eq 'True')
}

function Get-VMI {
    param([string]$Name)
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','virtualmachineinstance.kubevirt.io','-n',$TenantNamespace,$Name,'-o','json')
    if ($probe.ExitCode -ne 0) { return $null }
    return ($probe.Text | ConvertFrom-Json)
}

function Test-VMIReady([object]$Vmi) {
    if ($null -eq $Vmi -or $Vmi.status.phase -ne 'Running') { return $false }
    $ready = @($Vmi.status.conditions | Where-Object { $_.type -eq 'Ready' })
    return ($ready.Count -ge 1 -and $ready[0].status -eq 'True')
}

function Test-ThreeNodeLinstorResource {
    param(
        [Parameter(Mandatory=$true)][string]$VolumeHandle,
        [Parameter(Mandatory=$true)][string[]]$NodeNames,
        [string]$EvidencePath=$null
    )
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @(
        'exec','-n','cozy-linstor','deploy/linstor-controller','--',
        'linstor','resource','list','--resources',$VolumeHandle
    )
    if ($probe.ExitCode -ne 0) {
        throw "LINSTOR resource lookup failed for ${VolumeHandle}: $($probe.Text)"
    }
    if ($probe.Text -notmatch [regex]::Escape($VolumeHandle)) {
        throw "LINSTOR output does not identify expected resource $VolumeHandle"
    }
    foreach ($nodeName in $NodeNames) {
        if ($probe.Text -notmatch [regex]::Escape($nodeName)) {
            throw "LINSTOR resource $VolumeHandle is not present on $nodeName"
        }
    }
    $upToDateMatches = [regex]::Matches($probe.Text,'(?im)\bUpToDate\b')
    if ($upToDateMatches.Count -lt $NodeNames.Count) {
        throw "LINSTOR resource $VolumeHandle does not show UpToDate on all expected replicas"
    }
    if ($EvidencePath) { $probe.Text | Set-Content -Path $EvidencePath -Encoding UTF8 }
    return $true
}

if (-not (Test-Path $KubectlPath)) { throw "kubectl not found: $KubectlPath" }
if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig not found: $Kubeconfig" }
$env:KUBECONFIG = $Kubeconfig

$runId = if ($env:GITHUB_RUN_ID -match '^\d+$') { $env:GITHUB_RUN_ID } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() }
$attempt = if ($env:GITHUB_RUN_ATTEMPT -match '^\d+$') { $env:GITHUB_RUN_ATTEMPT } else { '1' }
$shortId = if ($runId.Length -gt 8) { $runId.Substring($runId.Length - 8) } else { $runId }
$vmLogicalName = "e2elinux$shortId"
$diskLogicalName = "${vmLogicalName}osdisk"
$vmRuntimeName = "vm-instance-$vmLogicalName"
$diskRuntimeName = "vm-disk-$diskLogicalName"
$vmHelmRelease = $vmRuntimeName
$diskHelmRelease = $diskRuntimeName
$evidenceDir = Join-Path $EvidenceRoot "linux-vm-product-$runId-$attempt"
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$primaryError = $null
$cleanupErrors = New-Object System.Collections.Generic.List[string]
$vmCreated = $false
$diskCreated = $false
$diskPvName = $null
$diskVolumeHandle = $null
$initialVmiUid = $null
$restartVmiUid = $null
$startVmiUid = $null
$selectedImage = $null
$selectedProfile = $null
$selectedInstanceType = $null
$tpmPvcName = $null
$tpmPvName = $null
$tpmVolumeHandle = $null
$tpmPvcUid = $null
$cloudInitSecretName = $null

try {
    # Fail closed unless this is the already-proven root tenant namespace and all three nodes are Ready.
    Invoke-KubectlText 'get' 'namespace' $TenantNamespace '-o' 'name' | Out-Null
    $nodes = (Invoke-KubectlText 'get' 'nodes' '-o' 'json' | ConvertFrom-Json)
    $nodeItems = @($nodes.items)
    if ($nodeItems.Count -ne 3) { throw "Expected exactly 3 Kubernetes nodes; found $($nodeItems.Count)" }
    $nodeNames = @()
    foreach ($node in $nodeItems) {
        $nodeNames += [string]$node.metadata.name
        $ready = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' })
        if ($ready.Count -ne 1 -or $ready[0].status -ne 'True') { throw "Node $($node.metadata.name) is not Ready" }
    }

    # Cozystack application resources are served through an aggregated APIService,
    # not conventional CRDs. Prove the live API discovery shape before mutation.
    $apiService = (Invoke-KubectlText 'get' 'apiservice.apiregistration.k8s.io' 'v1alpha1.apps.cozystack.io' '-o' 'json' | ConvertFrom-Json)
    $apiAvailable = @($apiService.status.conditions | Where-Object { $_.type -eq 'Available' })
    if ($apiAvailable.Count -lt 1 -or $apiAvailable[0].status -ne 'True') {
        throw 'Aggregated APIService v1alpha1.apps.cozystack.io is not Available'
    }
    $discovery = (Invoke-KubectlText 'get' '--raw=/apis/apps.cozystack.io/v1alpha1' | ConvertFrom-Json)
    $resourceNames = @($discovery.resources | ForEach-Object { [string]$_.name })
    if ($resourceNames -notcontains 'vmdisks') { throw 'Aggregated apps.cozystack.io API does not advertise vmdisks' }
    if ($resourceNames -notcontains 'vminstances') { throw 'Aggregated apps.cozystack.io API does not advertise vminstances' }

    # Persistent vTPM backend state must already be enabled on shared replicated storage.
    $kubeVirt = (Invoke-KubectlText 'get' 'kubevirt.kubevirt.io' '-n' 'cozy-kubevirt' 'kubevirt' '-o' 'json' | ConvertFrom-Json)
    if ([string]$kubeVirt.status.phase -ne 'Deployed') { throw "KubeVirt phase is $($kubeVirt.status.phase), expected Deployed" }
    $featureGates = @($kubeVirt.spec.configuration.developerConfiguration.featureGates)
    if ($featureGates -notcontains 'VMPersistentState') { throw 'KubeVirt VMPersistentState feature gate is not enabled' }
    if ([string]$kubeVirt.spec.configuration.vmStateStorageClass -ne 'replicated') {
        throw "KubeVirt vmStateStorageClass is '$($kubeVirt.spec.configuration.vmStateStorageClass)', expected replicated"
    }

    # Refuse to reuse any logical or generated runtime resource with our unique names.
    $collisionChecks = @(
        @('get','vmdisk.apps.cozystack.io','-n',$TenantNamespace,$diskLogicalName,'-o','name'),
        @('get','vminstance.apps.cozystack.io','-n',$TenantNamespace,$vmLogicalName,'-o','name'),
        @('get','datavolume.cdi.kubevirt.io','-n',$TenantNamespace,$diskRuntimeName,'-o','name'),
        @('get','virtualmachine.kubevirt.io','-n',$TenantNamespace,$vmRuntimeName,'-o','name')
    )
    foreach ($check in $collisionChecks) {
        $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments $check
        if ($probe.ExitCode -eq 0) { throw "Refusing to reuse pre-existing test resource: $($probe.Text)" }
    }

    # Discover an existing Bound public Linux image used by the product's VMDisk source.image path.
    $publicPvcs = (Invoke-KubectlText 'get' 'pvc' '-n' 'cozy-public' '-o' 'json' | ConvertFrom-Json)
    $candidates = @($publicPvcs.items | Where-Object {
        $_.status.phase -eq 'Bound' -and $_.metadata.name -like 'vm-default-images-*'
    })
    if ($candidates.Count -lt 1) { throw 'No Bound platform image PVC matching vm-default-images-* exists in cozy-public' }
    $preferred = @($candidates | Where-Object { $_.metadata.name -match '(?i)(ubuntu|debian|rocky|alma|fedora|centos|alpine)' })
    $imagePvc = if ($preferred.Count -gt 0) { $preferred[0] } else { $candidates[0] }
    $selectedImage = [string]$imagePvc.metadata.name
    $imageLogicalName = $selectedImage.Substring('vm-default-images-'.Length)
    if (-not $imageLogicalName) { throw "Unable to derive product image name from $selectedImage" }
    $imageStorage = [string]$imagePvc.spec.resources.requests.storage
    if (-not $imageStorage) { $imageStorage = '10Gi' }

    # Discover compatible current KubeVirt instance type and preference; prefer product defaults.
    $instanceTypes = (Invoke-KubectlText 'get' 'virtualmachineclusterinstancetype.instancetype.kubevirt.io' '-o' 'json' | ConvertFrom-Json)
    $typeNames = @($instanceTypes.items | ForEach-Object { [string]$_.metadata.name })
    if ($typeNames.Count -lt 1) { throw 'No VirtualMachineClusterInstancetype objects are installed' }
    $selectedInstanceType = if ($typeNames -contains 'u1.medium') { 'u1.medium' } else { $typeNames[0] }

    $profiles = (Invoke-KubectlText 'get' 'virtualmachineclusterpreference.instancetype.kubevirt.io' '-o' 'json' | ConvertFrom-Json)
    $profileNames = @($profiles.items | ForEach-Object { [string]$_.metadata.name })
    if ($profileNames.Count -lt 1) { throw 'No VirtualMachineClusterPreference objects are installed' }
    if ($profileNames -contains 'ubuntu' -and $selectedImage -match '(?i)ubuntu') {
        $selectedProfile = 'ubuntu'
    } elseif ($profileNames -contains 'linux') {
        $selectedProfile = 'linux'
    } else {
        $selectedProfile = $profileNames[0]
    }

    $diskManifest = @"
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
metadata:
  name: $diskLogicalName
  namespace: $TenantNamespace
  labels:
    layersentry.io/e2e: linux-vm-product
    layersentry.io/run-id: "$runId"
spec:
  source:
    image:
      name: $imageLogicalName
  optical: false
  displayName: "LayerSentry Linux E2E OS Disk"
  osFamily: "Linux"
  architecture: "amd64"
  storage: $imageStorage
  storageClass: replicated
"@
    $diskFile = Join-Path $evidenceDir 'vmdisk.yaml'
    Set-Content -Path $diskFile -Value $diskManifest -Encoding UTF8
    Invoke-KubectlText 'apply' '-f' $diskFile | Out-Null
    $diskCreated = $true

    Wait-Until -TimeoutSeconds 600 -Description "VMDisk HelmRelease $diskHelmRelease Ready" -Condition {
        return (Get-HelmReleaseReady $diskHelmRelease)
    }
    Wait-Until -TimeoutSeconds 900 -Description "DataVolume $diskRuntimeName Succeeded" -Condition {
        $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','datavolume.cdi.kubevirt.io','-n',$TenantNamespace,$diskRuntimeName,'-o','jsonpath={.status.phase}')
        if ($probe.ExitCode -ne 0) { return $false }
        if ($probe.Text.Trim() -eq 'Failed') { throw "DataVolume $diskRuntimeName entered Failed phase" }
        return ($probe.Text.Trim() -eq 'Succeeded')
    }
    $diskPvc = (Invoke-KubectlText 'get' 'pvc' '-n' $TenantNamespace $diskRuntimeName '-o' 'json' | ConvertFrom-Json)
    if ($diskPvc.status.phase -ne 'Bound') { throw "OS disk PVC $diskRuntimeName is not Bound" }
    $diskPvName = [string]$diskPvc.spec.volumeName
    if (-not $diskPvName) { throw "OS disk PVC $diskRuntimeName has no volumeName" }
    $diskVolumeHandle = (Invoke-KubectlText 'get' 'pv' $diskPvName '-o' 'jsonpath={.spec.csi.volumeHandle}').Trim()
    if (-not $diskVolumeHandle) { throw "OS disk PV $diskPvName has no CSI volumeHandle" }
    [void](Test-ThreeNodeLinstorResource -VolumeHandle $diskVolumeHandle -NodeNames $nodeNames -EvidencePath (Join-Path $evidenceDir 'linstor-osdisk.txt'))

    $cloudInit = @'
#cloud-config
write_files:
  - path: /var/lib/layersentry-e2e
    permissions: '0644'
    content: |
      LayerSentry Linux VM product lifecycle E2E
runcmd:
  - [ sh, -c, 'echo LayerSentry-Linux-E2E-booted > /dev/ttyS0 || true' ]
'@
    $cloudInitIndented = (($cloudInit -split "`r?`n") | ForEach-Object { "    $_" }) -join "`n"
    $vmManifest = @"
apiVersion: apps.cozystack.io/v1alpha1
kind: VMInstance
metadata:
  name: $vmLogicalName
  namespace: $TenantNamespace
  labels:
    layersentry.io/e2e: linux-vm-product
    layersentry.io/run-id: "$runId"
spec:
  external: false
  runStrategy: Always
  instanceType: $selectedInstanceType
  instanceProfile: $selectedProfile
  disks:
    - name: $diskLogicalName
  tpm:
    enabled: true
    persistent: true
  cloudInit: |
$cloudInitIndented
  cloudInitSeed: "$runId-$attempt"
"@
    $vmFile = Join-Path $evidenceDir 'vminstance.yaml'
    Set-Content -Path $vmFile -Value $vmManifest -Encoding UTF8
    Invoke-KubectlText 'apply' '-f' $vmFile | Out-Null
    $vmCreated = $true

    Wait-Until -TimeoutSeconds 600 -Description "VMInstance HelmRelease $vmHelmRelease Ready" -Condition {
        return (Get-HelmReleaseReady $vmHelmRelease)
    }
    Wait-Until -TimeoutSeconds 600 -Description "VirtualMachine $vmRuntimeName ready" -Condition {
        $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','virtualmachine.kubevirt.io','-n',$TenantNamespace,$vmRuntimeName,'-o','json')
        if ($probe.ExitCode -ne 0) { return $false }
        $vm = $probe.Text | ConvertFrom-Json
        return ([bool]$vm.status.ready -and [string]$vm.spec.runStrategy -eq 'Always')
    }
    Wait-Until -TimeoutSeconds 600 -Description "VirtualMachineInstance $vmRuntimeName Running and Ready" -Condition {
        return (Test-VMIReady (Get-VMI $vmRuntimeName))
    }

    $initialVmi = Get-VMI $vmRuntimeName
    $initialVmiUid = [string]$initialVmi.metadata.uid
    if (-not $initialVmiUid) { throw 'Initial VMI has no UID' }

    $runtimeVm = (Invoke-KubectlText 'get' 'virtualmachine.kubevirt.io' '-n' $TenantNamespace $vmRuntimeName '-o' 'json' | ConvertFrom-Json)
    if (-not [bool]$runtimeVm.spec.template.spec.domain.devices.tpm.persistent) {
        throw 'Generated KubeVirt VM does not request persistent TPM state'
    }
    $cloudInitVolumes = @($runtimeVm.spec.template.spec.volumes | Where-Object { $_.name -eq 'cloudinitdisk' })
    if ($cloudInitVolumes.Count -ne 1) { throw 'Generated KubeVirt VM does not contain exactly one cloudinitdisk volume' }
    $cloudInitSecretName = [string]$cloudInitVolumes[0].cloudInitNoCloud.secretRef.name
    if (-not $cloudInitSecretName) { throw 'cloudinitdisk does not reference a Secret' }
    Invoke-KubectlText 'get' 'secret' '-n' $TenantNamespace $cloudInitSecretName '-o' 'name' | Out-Null

    Wait-Until -TimeoutSeconds 300 -Description 'persistent TPM backend PVC Bound' -Condition {
        $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','pvc','-n',$TenantNamespace,'-l',"persistent-state-for=$vmRuntimeName",'-o','json')
        if ($probe.ExitCode -ne 0) { return $false }
        $list = $probe.Text | ConvertFrom-Json
        $bound = @($list.items | Where-Object { $_.status.phase -eq 'Bound' -and -not $_.metadata.deletionTimestamp })
        return ($bound.Count -eq 1)
    }
    $tpmPvcs = (Invoke-KubectlText 'get' 'pvc' '-n' $TenantNamespace '-l' "persistent-state-for=$vmRuntimeName" '-o' 'json' | ConvertFrom-Json)
    $tpmItems = @($tpmPvcs.items | Where-Object { $_.status.phase -eq 'Bound' -and -not $_.metadata.deletionTimestamp })
    if ($tpmItems.Count -ne 1) { throw "Expected exactly one Bound persistent-state PVC; found $($tpmItems.Count)" }
    $tpmPvc = $tpmItems[0]
    $tpmPvcName = [string]$tpmPvc.metadata.name
    $tpmPvcUid = [string]$tpmPvc.metadata.uid
    if ([string]$tpmPvc.spec.storageClassName -ne 'replicated') { throw "Persistent TPM PVC $tpmPvcName is not on replicated StorageClass" }
    $tpmPvName = [string]$tpmPvc.spec.volumeName
    if (-not $tpmPvName) { throw "Persistent TPM PVC $tpmPvcName has no bound PV" }
    $tpmVolumeHandle = (Invoke-KubectlText 'get' 'pv' $tpmPvName '-o' 'jsonpath={.spec.csi.volumeHandle}').Trim()
    if (-not $tpmVolumeHandle) { throw "Persistent TPM PV $tpmPvName has no CSI volumeHandle" }
    [void](Test-ThreeNodeLinstorResource -VolumeHandle $tpmVolumeHandle -NodeNames $nodeNames -EvidencePath (Join-Path $evidenceDir 'linstor-tpm-state.txt'))

    $volumes = @($initialVmi.spec.volumes)
    $osVolume = @($volumes | Where-Object { $_.dataVolume.name -eq $diskRuntimeName })
    if ($osVolume.Count -lt 1) { throw "VMI does not attach expected product OS DataVolume $diskRuntimeName" }

    Wait-Until -TimeoutSeconds 300 -Description 'VMI default NIC with IP address' -Condition {
        $vmi = Get-VMI $vmRuntimeName
        if ($null -eq $vmi) { return $false }
        $interfaces = @($vmi.status.interfaces)
        foreach ($iface in $interfaces) {
            if ($iface.name -eq 'default' -and $iface.mac -and ($iface.ipAddress -or @($iface.ipAddresses).Count -gt 0)) { return $true }
        }
        return $false
    }
    $networkVmi = Get-VMI $vmRuntimeName
    $defaultInterface = @($networkVmi.status.interfaces | Where-Object { $_.name -eq 'default' })[0]
    $initialNode = [string]$networkVmi.status.nodeName

    # Product-level stop: change desired state on VMInstance and require generated VM/VMI convergence.
    Invoke-KubectlText 'patch' 'vminstance.apps.cozystack.io' '-n' $TenantNamespace $vmLogicalName '--type=merge' '-p' '{"spec":{"runStrategy":"Halted"}}' | Out-Null
    Wait-Until -TimeoutSeconds 300 -Description 'product VM stop convergence' -Condition {
        $vmProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','virtualmachine.kubevirt.io','-n',$TenantNamespace,$vmRuntimeName,'-o','json')
        if ($vmProbe.ExitCode -ne 0) { return $false }
        $vm = $vmProbe.Text | ConvertFrom-Json
        $vmiAbsent = Test-KubectlObjectAbsent @('get','virtualmachineinstance.kubevirt.io','-n',$TenantNamespace,$vmRuntimeName,'-o','name')
        return ([string]$vm.spec.runStrategy -eq 'Halted' -and $vmiAbsent)
    }

    # Product-level start: restore Always and prove a fresh VMI reaches Running/Ready.
    Invoke-KubectlText 'patch' 'vminstance.apps.cozystack.io' '-n' $TenantNamespace $vmLogicalName '--type=merge' '-p' '{"spec":{"runStrategy":"Always"}}' | Out-Null
    Wait-Until -TimeoutSeconds 600 -Description 'product VM start convergence' -Condition {
        $vmi = Get-VMI $vmRuntimeName
        return (Test-VMIReady $vmi)
    }
    $startedVmi = Get-VMI $vmRuntimeName
    $startVmiUid = [string]$startedVmi.metadata.uid
    if (-not $startVmiUid -or $startVmiUid -eq $initialVmiUid) { throw 'Product stop/start did not create a fresh VMI UID' }
    $tpmAfterStart = (Invoke-KubectlText 'get' 'pvc' '-n' $TenantNamespace $tpmPvcName '-o' 'json' | ConvertFrom-Json)
    if ([string]$tpmAfterStart.metadata.uid -ne $tpmPvcUid -or $tpmAfterStart.status.phase -ne 'Bound') {
        throw 'Persistent TPM backend PVC identity did not survive product stop/start'
    }

    # Reboot through the official KubeVirt VM restart subresource and require another fresh Running VMI.
    $restartPath = "/apis/subresources.kubevirt.io/v1/namespaces/$TenantNamespace/virtualmachines/$vmRuntimeName/restart"
    $restartBody = Join-Path $evidenceDir 'restart-options.json'
    '{}' | Set-Content -Path $restartBody -Encoding ASCII
    $restartProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('replace',"--raw=$restartPath",'-f',$restartBody)
    if ($restartProbe.ExitCode -ne 0) { throw "KubeVirt restart subresource failed: $($restartProbe.Text)" }
    Wait-Until -TimeoutSeconds 600 -Description 'KubeVirt VM restart convergence' -Condition {
        $vmi = Get-VMI $vmRuntimeName
        if (-not (Test-VMIReady $vmi)) { return $false }
        return ([string]$vmi.metadata.uid -ne $startVmiUid)
    }
    $restartedVmi = Get-VMI $vmRuntimeName
    $restartVmiUid = [string]$restartedVmi.metadata.uid
    $restartNode = [string]$restartedVmi.status.nodeName
    $tpmAfterRestart = (Invoke-KubectlText 'get' 'pvc' '-n' $TenantNamespace $tpmPvcName '-o' 'json' | ConvertFrom-Json)
    if ([string]$tpmAfterRestart.metadata.uid -ne $tpmPvcUid -or $tpmAfterRestart.status.phase -ne 'Bound') {
        throw 'Persistent TPM backend PVC identity did not survive KubeVirt restart'
    }

    $productEvidence = @(
        (Invoke-KubectlText 'get' 'vmdisk.apps.cozystack.io' '-n' $TenantNamespace $diskLogicalName '-o' 'wide'),
        (Invoke-KubectlText 'get' 'vminstance.apps.cozystack.io' '-n' $TenantNamespace $vmLogicalName '-o' 'wide')
    )
    $productEvidence | Set-Content -Path (Join-Path $evidenceDir 'product-resources.txt') -Encoding UTF8
    $runtimeEvidence = @(
        (Invoke-KubectlText 'get' 'virtualmachine.kubevirt.io' '-n' $TenantNamespace $vmRuntimeName '-o' 'wide'),
        (Invoke-KubectlText 'get' 'virtualmachineinstance.kubevirt.io' '-n' $TenantNamespace $vmRuntimeName '-o' 'wide'),
        (Invoke-KubectlText 'get' 'datavolume.cdi.kubevirt.io' '-n' $TenantNamespace $diskRuntimeName '-o' 'wide'),
        (Invoke-KubectlText 'get' 'pvc' '-n' $TenantNamespace $diskRuntimeName $tpmPvcName '-o' 'wide')
    )
    $runtimeEvidence | Set-Content -Path (Join-Path $evidenceDir 'runtime-resources.txt') -Encoding UTF8

    $summary = @(
        'status=PASS',
        "run_id=$runId",
        "tenant_namespace=$TenantNamespace",
        "product_vm=$vmLogicalName",
        "runtime_vm=$vmRuntimeName",
        "product_disk=$diskLogicalName",
        "runtime_disk=$diskRuntimeName",
        "platform_image_pvc=$selectedImage",
        "instance_type=$selectedInstanceType",
        "instance_profile=$selectedProfile",
        "osdisk_pv=$diskPvName",
        "osdisk_volume_handle=$diskVolumeHandle",
        'osdisk_three_node_drbd=PASS',
        'vm_create_boot=PASS',
        'vm_disk_attachment=PASS',
        'persistent_tpm_enabled=PASS',
        'persistent_tpm_storageclass=replicated',
        "persistent_tpm_pvc=$tpmPvcName",
        "persistent_tpm_pv=$tpmPvName",
        "persistent_tpm_volume_handle=$tpmVolumeHandle",
        'persistent_tpm_three_node_drbd=PASS',
        'persistent_tpm_identity_stop_start=PASS',
        'persistent_tpm_identity_restart=PASS',
        "cloud_init_secret=$cloudInitSecretName",
        'cloud_init_cluster_portable=PASS',
        'vm_default_nic=PASS',
        "vm_default_mac=$($defaultInterface.mac)",
        "vm_default_ip=$($defaultInterface.ipAddress)",
        "initial_node=$initialNode",
        "initial_vmi_uid=$initialVmiUid",
        'product_stop=PASS',
        'product_start=PASS',
        "started_vmi_uid=$startVmiUid",
        'kubevirt_restart=PASS',
        "restart_vmi_uid=$restartVmiUid",
        "restart_node=$restartNode",
        'console_interaction=NOT_RUN',
        'NOTE=serial/VNC console interaction requires a virtctl websocket client and is intentionally not inferred from VMI readiness',
        'NOTE=no kubeconfig, credentials, SSH private keys or guest secrets are stored in evidence'
    )
    $summary | Set-Content -Path (Join-Path $evidenceDir 'summary.txt') -Encoding UTF8
    Write-Host "Linux VM product lifecycle proof PASSED: vm=$vmLogicalName disk=$diskLogicalName image=$imageLogicalName"
} catch {
    $primaryError = $_.Exception
    "status=FAIL`nerror=$($primaryError.Message)" | Set-Content -Path (Join-Path $evidenceDir 'failure.txt') -Encoding UTF8
} finally {
    # Cleanup is restricted to the unique product resources created by this run.
    if ($vmCreated) {
        $deleteVm = Invoke-NativeText -FilePath $KubectlPath -Arguments @('delete','vminstance.apps.cozystack.io','-n',$TenantNamespace,$vmLogicalName,'--wait=false')
        if ($deleteVm.ExitCode -ne 0) { $cleanupErrors.Add("VMInstance delete request failed: $($deleteVm.Text)") }
        try {
            Wait-Until -TimeoutSeconds 420 -Description "runtime VM $vmRuntimeName cleanup" -Condition {
                $crAbsent = Test-KubectlObjectAbsent @('get','vminstance.apps.cozystack.io','-n',$TenantNamespace,$vmLogicalName,'-o','name')
                $vmAbsent = Test-KubectlObjectAbsent @('get','virtualmachine.kubevirt.io','-n',$TenantNamespace,$vmRuntimeName,'-o','name')
                $vmiAbsent = Test-KubectlObjectAbsent @('get','virtualmachineinstance.kubevirt.io','-n',$TenantNamespace,$vmRuntimeName,'-o','name')
                return ($crAbsent -and $vmAbsent -and $vmiAbsent)
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }

    if ($tpmPvcName) {
        try {
            Wait-Until -TimeoutSeconds 420 -Description "persistent TPM PVC $tpmPvcName cleanup" -Condition {
                return (Test-KubectlObjectAbsent @('get','pvc','-n',$TenantNamespace,$tpmPvcName,'-o','name'))
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
        if ($tpmPvName) {
            try {
                Wait-Until -TimeoutSeconds 300 -Description "persistent TPM PV $tpmPvName reclamation" -Condition {
                    return (Test-KubectlObjectAbsent @('get','pv',$tpmPvName,'-o','name'))
                }
            } catch { $cleanupErrors.Add($_.Exception.Message) }
        }
    }

    if ($diskCreated) {
        $deleteDisk = Invoke-NativeText -FilePath $KubectlPath -Arguments @('delete','vmdisk.apps.cozystack.io','-n',$TenantNamespace,$diskLogicalName,'--wait=false')
        if ($deleteDisk.ExitCode -ne 0) { $cleanupErrors.Add("VMDisk delete request failed: $($deleteDisk.Text)") }
        try {
            Wait-Until -TimeoutSeconds 600 -Description "runtime disk $diskRuntimeName cleanup" -Condition {
                $crAbsent = Test-KubectlObjectAbsent @('get','vmdisk.apps.cozystack.io','-n',$TenantNamespace,$diskLogicalName,'-o','name')
                $dvAbsent = Test-KubectlObjectAbsent @('get','datavolume.cdi.kubevirt.io','-n',$TenantNamespace,$diskRuntimeName,'-o','name')
                $pvcAbsent = Test-KubectlObjectAbsent @('get','pvc','-n',$TenantNamespace,$diskRuntimeName,'-o','name')
                return ($crAbsent -and $dvAbsent -and $pvcAbsent)
            }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
        if ($diskPvName) {
            try {
                Wait-Until -TimeoutSeconds 300 -Description "PV $diskPvName reclamation" -Condition {
                    return (Test-KubectlObjectAbsent @('get','pv',$diskPvName,'-o','name'))
                }
            } catch { $cleanupErrors.Add($_.Exception.Message) }
        }
    }
}

if ($primaryError) {
    if ($cleanupErrors.Count -gt 0) { throw "$($primaryError.Message) | cleanup: $($cleanupErrors -join ' | ')" }
    throw $primaryError
}
if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join ' | ') }
