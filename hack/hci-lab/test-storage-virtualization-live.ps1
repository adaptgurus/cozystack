# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$Kubeconfig = 'C:\hci-state\cozystack-hci-lab\kubeconfig',
    [string]$KubectlPath = 'C:\hci-tools\kubectl.exe',
    [string]$EvidenceRoot = 'C:\hci-diagnostics'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

function Invoke-KubectlText {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments $Arguments
    if ($probe.ExitCode -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed with exit code $($probe.ExitCode): $($probe.Text)"
    }
    return $probe.Text
}

function Wait-Until {
    param(
        [Parameter(Mandatory=$true)][scriptblock]$Condition,
        [Parameter(Mandatory=$true)][int]$TimeoutSeconds,
        [int]$IntervalSeconds=3,
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

function Test-PodReady([object]$Pod) {
    if ($Pod.status.phase -ne 'Running') { return $false }
    $containers = @($Pod.status.containerStatuses)
    if ($containers.Count -lt 1) { return $false }
    foreach ($container in $containers) {
        if (-not [bool]$container.ready) { return $false }
    }
    return $true
}

if (-not (Test-Path $KubectlPath)) { throw "kubectl not found: $KubectlPath" }
if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig not found: $Kubeconfig" }
$env:KUBECONFIG = $Kubeconfig

$runId = if ($env:GITHUB_RUN_ID -match '^\d+$') { $env:GITHUB_RUN_ID } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString() }
$attempt = if ($env:GITHUB_RUN_ATTEMPT -match '^\d+$') { $env:GITHUB_RUN_ATTEMPT } else { '1' }
$namespace = "hci-e2e-storage-$runId-$attempt".ToLowerInvariant()
if ($namespace.Length -gt 63) { $namespace = $namespace.Substring(0,63).TrimEnd('-') }
$pvcName = 'replicated-data'
$writerName = 'storage-writer'
$readerName = 'storage-reader'
$evidenceDir = Join-Path $EvidenceRoot "storage-virtualization-$runId-$attempt"
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$payload = [guid]::NewGuid().ToString('N')
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $payloadHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))).Replace('-','').ToLowerInvariant()
} finally {
    $sha.Dispose()
}

$pvName = $null
$volumeHandle = $null
$primaryError = $null
$cleanupError = $null

try {
    # Baseline: exact three-node Ready cluster.
    $nodes = (Invoke-KubectlText 'get' 'nodes' '-o' 'json' | ConvertFrom-Json)
    $nodeItems = @($nodes.items)
    if ($nodeItems.Count -ne 3) { throw "Expected exactly 3 Kubernetes nodes; found $($nodeItems.Count)" }
    $nodeNames = @()
    foreach ($node in $nodeItems) {
        $nodeNames += [string]$node.metadata.name
        $ready = @($node.status.conditions | Where-Object { $_.type -eq 'Ready' })
        if ($ready.Count -ne 1 -or $ready[0].status -ne 'True') {
            throw "Node $($node.metadata.name) is not Ready"
        }
    }

    # StorageClass must prove the intended 3-way DRBD placement contract before creating data.
    $sc = (Invoke-KubectlText 'get' 'storageclass' 'replicated' '-o' 'json' | ConvertFrom-Json)
    if ([string]$sc.provisioner -ne 'linstor.csi.linbit.com') { throw 'replicated StorageClass is not LINSTOR CSI' }
    $parameters = $sc.parameters
    if ([string]$parameters.'linstor.csi.linbit.com/storagePool' -ne 'data') { throw 'replicated StorageClass does not target pool data' }
    if ([string]$parameters.'linstor.csi.linbit.com/autoPlace' -ne '3') { throw 'replicated StorageClass is not configured for 3 replicas' }
    $layers = [string]$parameters.'linstor.csi.linbit.com/layerList'
    if ($layers -notmatch '(?i)\bdrbd\b' -or $layers -notmatch '(?i)\bstorage\b') {
        throw "replicated StorageClass layerList is not DRBD + storage: $layers"
    }

    # Virtualization prerequisites: deployed KubeVirt/CDI and one ready Multus pod per node.
    $kubeVirtPhase = (Invoke-KubectlText 'get' 'kubevirt' '-n' 'cozy-kubevirt' 'kubevirt' '-o' 'jsonpath={.status.phase}').Trim()
    if ($kubeVirtPhase -ne 'Deployed') { throw "KubeVirt phase is $kubeVirtPhase, expected Deployed" }
    $cdiPhase = (Invoke-KubectlText 'get' 'cdi' 'cdi' '-o' 'jsonpath={.status.phase}').Trim()
    if ($cdiPhase -ne 'Deployed') { throw "CDI phase is $cdiPhase, expected Deployed" }
    $multus = (Invoke-KubectlText 'get' 'pods' '-n' 'cozy-multus' '-o' 'json' | ConvertFrom-Json)
    $multusPods = @($multus.items)
    if ($multusPods.Count -lt 3) { throw "Expected at least 3 Multus pods; found $($multusPods.Count)" }
    foreach ($nodeName in $nodeNames) {
        $onNode = @($multusPods | Where-Object { $_.spec.nodeName -eq $nodeName -and (Test-PodReady $_) })
        if ($onNode.Count -lt 1) { throw "No Ready Multus pod found on $nodeName" }
    }

    # Create a uniquely-owned disposable namespace. Never reuse or delete a pre-existing namespace.
    $existingNs = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','namespace',$namespace,'-o','name')
    if ($existingNs.ExitCode -eq 0) { throw "Refusing to reuse existing test namespace $namespace" }
    Invoke-KubectlText 'create' 'namespace' $namespace | Out-Null
    Invoke-KubectlText 'label' 'namespace' $namespace 'layersentry.io/e2e=storage-virtualization' "layersentry.io/run-id=$runId" '--overwrite' | Out-Null

    $pvcManifest = @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvcName
  namespace: $namespace
  labels:
    layersentry.io/e2e: storage-virtualization
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: replicated
  resources:
    requests:
      storage: 1Gi
"@
    $pvcFile = Join-Path $evidenceDir 'pvc.yaml'
    Set-Content -Path $pvcFile -Value $pvcManifest -Encoding UTF8
    Invoke-KubectlText 'apply' '-f' $pvcFile | Out-Null

    Wait-Until -TimeoutSeconds 240 -Description 'replicated PVC Bound' -Condition {
        $phase = (Invoke-KubectlText 'get' 'pvc' '-n' $namespace $pvcName '-o' 'jsonpath={.status.phase}').Trim()
        return ($phase -eq 'Bound')
    }
    $pvName = (Invoke-KubectlText 'get' 'pvc' '-n' $namespace $pvcName '-o' 'jsonpath={.spec.volumeName}').Trim()
    if (-not $pvName) { throw 'Bound PVC has no volumeName' }
    $volumeHandle = (Invoke-KubectlText 'get' 'pv' $pvName '-o' 'jsonpath={.spec.csi.volumeHandle}').Trim()
    if (-not $volumeHandle) { throw "PV $pvName has no CSI volumeHandle" }

    $writerManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $writerName
  namespace: $namespace
  labels:
    layersentry.io/e2e: storage-virtualization
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36.1
      imagePullPolicy: IfNotPresent
      command: ['sh','-c','printf %s "$payload" > /data/evidence.txt && sync']
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $pvcName
"@
    $writerFile = Join-Path $evidenceDir 'writer.yaml'
    Set-Content -Path $writerFile -Value $writerManifest -Encoding UTF8
    Invoke-KubectlText 'apply' '-f' $writerFile | Out-Null
    Wait-Until -TimeoutSeconds 240 -Description 'writer pod completion' -Condition {
        $phase = (Invoke-KubectlText 'get' 'pod' '-n' $namespace $writerName '-o' 'jsonpath={.status.phase}').Trim()
        if ($phase -eq 'Failed') { throw "Writer pod failed: $(Invoke-KubectlText 'logs' '-n' $namespace $writerName)" }
        return ($phase -eq 'Succeeded')
    }
    Invoke-KubectlText 'delete' 'pod' '-n' $namespace $writerName '--wait=true' '--timeout=120s' | Out-Null

    $readerManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $readerName
  namespace: $namespace
  labels:
    layersentry.io/e2e: storage-virtualization
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36.1
      imagePullPolicy: IfNotPresent
      command: ['sh','-c','cat /data/evidence.txt']
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $pvcName
"@
    $readerFile = Join-Path $evidenceDir 'reader.yaml'
    Set-Content -Path $readerFile -Value $readerManifest -Encoding UTF8
    Invoke-KubectlText 'apply' '-f' $readerFile | Out-Null
    Wait-Until -TimeoutSeconds 240 -Description 'reader pod completion' -Condition {
        $phase = (Invoke-KubectlText 'get' 'pod' '-n' $namespace $readerName '-o' 'jsonpath={.status.phase}').Trim()
        if ($phase -eq 'Failed') { throw "Reader pod failed: $(Invoke-KubectlText 'logs' '-n' $namespace $readerName)" }
        return ($phase -eq 'Succeeded')
    }
    $readBack = (Invoke-KubectlText 'logs' '-n' $namespace $readerName).Trim()
    if ($readBack -ne $payload) { throw 'Replicated PVC write/read integrity mismatch' }

    # Prove the concrete LINSTOR resource exists on every Kubernetes node.
    $resourceProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @(
        'exec','-n','cozy-linstor','deploy/linstor-controller','--',
        'linstor','resource','list','--resources',$volumeHandle
    )
    if ($resourceProbe.ExitCode -ne 0) {
        throw "LINSTOR resource lookup failed for CSI volumeHandle $volumeHandle: $($resourceProbe.Text)"
    }
    $resourceText = $resourceProbe.Text
    foreach ($nodeName in $nodeNames) {
        if ($resourceText -notmatch [regex]::Escape($nodeName)) {
            throw "LINSTOR resource $volumeHandle is not present on $nodeName"
        }
    }
    if ($resourceText -notmatch [regex]::Escape($volumeHandle)) {
        throw "LINSTOR output does not identify expected resource $volumeHandle"
    }

    $summary = @(
        "status=PASS",
        "run_id=$runId",
        "namespace=$namespace",
        "node_count=$($nodeNames.Count)",
        "nodes=$($nodeNames -join ',')",
        "storageclass=replicated",
        "provisioner=$($sc.provisioner)",
        "autoplace=$($parameters.'linstor.csi.linbit.com/autoPlace')",
        "layer_list=$layers",
        "pv=$pvName",
        "volume_handle=$volumeHandle",
        "payload_sha256=$payloadHash",
        "write_read_integrity=PASS",
        "linstor_three_node_presence=PASS",
        "kubevirt_phase=$kubeVirtPhase",
        "cdi_phase=$cdiPhase",
        "multus_ready_nodes=$($nodeNames.Count)",
        "NOTE=payload content suppressed; no kubeconfig, credentials, tokens or private keys are stored"
    )
    $summary | Set-Content -Path (Join-Path $evidenceDir 'summary.txt') -Encoding UTF8
    $resourceText | Set-Content -Path (Join-Path $evidenceDir 'linstor-resource.txt') -Encoding UTF8
    Invoke-KubectlText 'get' 'pvc,pod' '-n' $namespace '-o' 'wide' | Set-Content -Path (Join-Path $evidenceDir 'workload.txt') -Encoding UTF8
    Write-Host "Replicated storage + KubeVirt/CDI/Multus live proof PASSED; payload SHA256=$payloadHash"
} catch {
    $primaryError = $_.Exception
    "status=FAIL`nerror=$($primaryError.Message)" | Set-Content -Path (Join-Path $evidenceDir 'failure.txt') -Encoding UTF8
} finally {
    # Cleanup is constrained to the uniquely-created e2e namespace and its dynamically provisioned PV.
    $nsProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','namespace',$namespace,'-o','name')
    if ($nsProbe.ExitCode -eq 0) {
        $deleteProbe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('delete','namespace',$namespace,'--wait=false')
        if ($deleteProbe.ExitCode -ne 0) {
            $cleanupError = "Failed to request deletion of e2e namespace $namespace: $($deleteProbe.Text)"
        } else {
            try {
                Wait-Until -TimeoutSeconds 240 -IntervalSeconds 5 -Description "namespace $namespace deletion" -Condition {
                    $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','namespace',$namespace,'-o','name')
                    return ($probe.ExitCode -ne 0)
                }
            } catch {
                $cleanupError = $_.Exception.Message
            }
        }
    }
    if ($pvName) {
        try {
            Wait-Until -TimeoutSeconds 240 -IntervalSeconds 5 -Description "PV $pvName reclamation" -Condition {
                $probe = Invoke-NativeText -FilePath $KubectlPath -Arguments @('get','pv',$pvName,'-o','name')
                return ($probe.ExitCode -ne 0)
            }
        } catch {
            if (-not $cleanupError) { $cleanupError = $_.Exception.Message }
        }
    }
}

if ($primaryError) {
    if ($cleanupError) { throw "$($primaryError.Message) | cleanup: $cleanupError" }
    throw $primaryError
}
if ($cleanupError) { throw $cleanupError }
