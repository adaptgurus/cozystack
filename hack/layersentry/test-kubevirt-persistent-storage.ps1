[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$Namespace = 'layersentry-validation',
    [string]$VmName = 'layersentry-storage-vm',
    [string]$PvcName = 'layersentry-storage-vm-disk',
    [string]$SourceVmName = 'layersentry-smoke-vm',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-kubevirt-storage-validation'),
    [ValidateRange(10, 90)]
    [int]$TimeoutMinutes = 35
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($command in @('ssh.exe','ssh-keygen.exe')) {
    if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
        throw "Required Windows OpenSSH command is missing: $command"
    }
}
if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Credential file is missing: $CredentialPath"
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$TimelinePath = Join-Path $OutputDirectory 'storage-timeline.jsonl'
$ResultPath = Join-Path $OutputDirectory 'storage-result.json'
$StatusPath = Join-Path $OutputDirectory 'STATUS.md'
$Start = (Get-Date).ToUniversalTime()
$Deadline = $Start.AddMinutes($TimeoutMinutes)
$Failure = $null
$Passed = $false
$Token = $null
$LoginUser = $null
$StorageClassName = $null
$ContainerDiskImage = $null
$NodePort = $null
$SshAddressBefore = $null
$SshAddressAfter = $null
$Marker = 'LAYERSENTRY-PERSISTENCE-' + [Guid]::NewGuid().ToString('N').ToUpperInvariant()
$MarkerHash = $null
$VmiUidBefore = $null
$VmiUidAfter = $null
$VmiNodeBefore = $null
$VmiNodeAfter = $null
$Pvc = $null
$PersistentVolume = $null
$LonghornVolume = $null
$WriteOutput = $null
$ReadOutput = $null
$KeyDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-storage-ssh-' + [Guid]::NewGuid().ToString('N'))
$PrivateKeyPath = Join-Path $KeyDirectory 'id_ed25519'
$PublicKeyPath = "$PrivateKeyPath.pub"

function Write-Timeline {
    param([Parameter(Mandatory = $true)][object]$Record)
    $ordered = [ordered]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o') }
    foreach ($property in $Record.PSObject.Properties) {
        $ordered[$property.Name] = $property.Value
    }
    ($ordered | ConvertTo-Json -Compress -Depth 20) |
        Add-Content -LiteralPath $TimelinePath -Encoding UTF8
}

function Get-PropertyValue {
    param([object]$Object, [string[]]$Names)
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties |
            Where-Object { $_.Name -ieq $name } |
            Select-Object -First 1
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return $null
}

function Invoke-JsonRequest {
    param(
        [ValidateSet('GET','POST','PATCH','DELETE')][string]$Method,
        [string]$Uri,
        [object]$Body = $null,
        [string]$BearerToken = $null,
        [int]$TimeoutSeconds = 45,
        [switch]$AllowHttpError
    )
    $headers = @{ Accept = 'application/json'; 'User-Agent' = 'LayerSentry-Storage-Validation/1.0' }
    if ($BearerToken) { $headers.Authorization = "Bearer $BearerToken" }
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        UseBasicParsing = $true
        TimeoutSec = $TimeoutSeconds
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.ContentType = if ($Method -eq 'PATCH') { 'application/merge-patch+json' } else { 'application/json' }
        $parameters.Body = ($Body | ConvertTo-Json -Depth 35 -Compress)
    }
    try {
        $response = Invoke-WebRequest @parameters
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$response.Content)) {
            $value = $response.Content | ConvertFrom-Json
        }
        return [pscustomobject]@{ statusCode = [int]$response.StatusCode; body = $value; error = $null }
    }
    catch [System.Net.WebException] {
        $exception = $_.Exception
        $statusCode = $null
        $responseText = $null
        if ($null -ne $exception.Response) {
            $statusCode = [int]$exception.Response.StatusCode
            $stream = $exception.Response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try { $responseText = $reader.ReadToEnd() }
                finally { $reader.Dispose(); $stream.Dispose() }
            }
        }
        if (-not $AllowHttpError) {
            $message = if ($responseText) { $responseText } else { $exception.Message }
            throw "HTTP $Method $Uri failed with status $statusCode: $message"
        }
        $value = $null
        if ($responseText) {
            try { $value = $responseText | ConvertFrom-Json } catch { $value = $null }
        }
        return [pscustomobject]@{ statusCode = $statusCode; body = $value; error = $exception.Message }
    }
}

function Test-TcpPort {
    param([string]$Address, [int]$Port, [int]$TimeoutMilliseconds = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-ReachableAddress {
    param([int]$Port)
    foreach ($address in @('10.10.10.11','10.10.10.12','10.10.10.13')) {
        if (Test-TcpPort -Address $address -Port $Port) { return $address }
    }
    return $null
}

function Get-ReadyCondition {
    param([object]$Vmi)
    $condition = @($Vmi.status.conditions |
        Where-Object { [string]$_.type -eq 'Ready' } |
        Select-Object -Last 1)
    if ($condition.Count -eq 0) { return $null }
    return [string]$condition[0].status
}

function Invoke-SshCommand {
    param(
        [string]$Address,
        [int]$Port,
        [string]$Command,
        [int]$TimeoutSeconds = 45
    )
    $stdout = Join-Path $KeyDirectory ('ssh-stdout-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $stderr = Join-Path $KeyDirectory ('ssh-stderr-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $arguments = @(
        '-i', $PrivateKeyPath,
        '-p', [string]$Port,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'GlobalKnownHostsFile=NUL',
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=3',
        "cirros@$Address",
        $Command
    )
    $process = Start-Process -FilePath 'ssh.exe' -ArgumentList $arguments `
        -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        throw "SSH command timed out after $TimeoutSeconds seconds."
    }
    $outText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue } else { '' }
    $errText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue } else { '' }
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        exitCode = $process.ExitCode
        stdout = [string]$outText
        stderr = [string]$errText
    }
}

function Wait-ForSsh {
    param([int]$Port, [DateTime]$Until)
    do {
        $address = Get-ReachableAddress -Port $Port
        if ($address) {
            $probe = Invoke-SshCommand -Address $address -Port $Port -Command 'printf LAYERSENTRY-SSH-READY' -TimeoutSeconds 30
            if ($probe.exitCode -eq 0 -and $probe.stdout -match 'LAYERSENTRY-SSH-READY') {
                return $address
            }
        }
        if ((Get-Date).ToUniversalTime() -ge $Until) { return $null }
        Start-Sleep -Seconds 10
    } while ($true)
}

New-Item -Path $KeyDirectory -ItemType Directory -Force | Out-Null
$keygen = Start-Process -FilePath 'ssh-keygen.exe' `
    -ArgumentList @('-q','-t','ed25519','-N','""','-f',('"' + $PrivateKeyPath + '"')) `
    -NoNewWindow -Wait -PassThru
if ($keygen.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $PrivateKeyPath) -or -not (Test-Path -LiteralPath $PublicKeyPath)) {
    throw 'Failed to generate the temporary Ed25519 validation key.'
}
$publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw -Encoding ASCII).Trim()
if ($publicKey -notmatch '^ssh-ed25519\s+[A-Za-z0-9+/=]+') {
    throw 'Generated validation public key has an unexpected format.'
}
$MarkerHash = [BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($Marker)
    )
).Replace('-', '').ToLowerInvariant()

$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$password = Get-PropertyValue -Object $credentials -Names @(
    'nodePassword','NodePassword','password','Password','rancherPassword','RancherPassword'
)
if (-not $password) { throw 'No node/Rancher password was found in the protected credential file.' }

$previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

try {
    foreach ($candidateUser in @('admin','rancher')) {
        $login = Invoke-JsonRequest -Method POST `
            -Uri "$ClusterUrl/v3-public/localProviders/local?action=login" `
            -Body ([ordered]@{ username = $candidateUser; password = $password; responseType = 'token' }) `
            -AllowHttpError
        if ($login.statusCode -ge 200 -and $login.statusCode -lt 300 -and $null -ne $login.body) {
            $candidateToken = Get-PropertyValue -Object $login.body -Names @('token')
            if ($candidateToken) { $Token = $candidateToken; $LoginUser = $candidateUser; break }
        }
    }
    if (-not $Token) { throw 'Harvester/Rancher authentication failed.' }

    $proxy = "$ClusterUrl/k8s/clusters/local"
    $sourceVmUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$SourceVmName"
    $sourceVm = (Invoke-JsonRequest -Method GET -Uri $sourceVmUri -BearerToken $Token).body
    $containerDisks = @($sourceVm.spec.template.spec.volumes | Where-Object { $null -ne $_.containerDisk })
    if ($containerDisks.Count -ne 1) {
        throw "Source VM $SourceVmName does not contain exactly one containerDisk volume."
    }
    $ContainerDiskImage = [string]$containerDisks[0].containerDisk.image
    if ($ContainerDiskImage -notmatch '@sha256:[0-9a-f]{64}$') {
        throw 'Source VM container disk is not pinned to an immutable SHA-256 digest.'
    }

    $storageClasses = (Invoke-JsonRequest -Method GET `
        -Uri "$proxy/apis/storage.k8s.io/v1/storageclasses" `
        -BearerToken $Token).body.items
    $defaults = @($storageClasses | Where-Object {
        [string]$_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' -or
        [string]$_.metadata.annotations.'storageclass.beta.kubernetes.io/is-default-class' -eq 'true'
    })
    if ($defaults.Count -ne 1) {
        throw "Expected exactly one default StorageClass; found $($defaults.Count)."
    }
    $StorageClassName = [string]$defaults[0].metadata.name
    if ([string]::IsNullOrWhiteSpace($StorageClassName)) { throw 'Default StorageClass has no name.' }

    $vmUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines/$VmName"
    $vmiUri = "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachineinstances/$VmName"
    $serviceUri = "$proxy/api/v1/namespaces/$Namespace/services/$VmName-ssh"
    $pvcUri = "$proxy/api/v1/namespaces/$Namespace/persistentvolumeclaims/$PvcName"

    foreach ($resource in @(
        [pscustomobject]@{ uri = $vmUri; name = 'VirtualMachine' },
        [pscustomobject]@{ uri = $serviceUri; name = 'Service' },
        [pscustomobject]@{ uri = $pvcUri; name = 'PersistentVolumeClaim' }
    )) {
        $existing = Invoke-JsonRequest -Method GET -Uri $resource.uri -BearerToken $Token -AllowHttpError
        if ($existing.statusCode -ge 200 -and $existing.statusCode -lt 300) {
            Invoke-JsonRequest -Method DELETE -Uri $resource.uri -BearerToken $Token | Out-Null
            Write-Timeline -Record ([pscustomobject]@{ event = 'previous-resource-deleted'; kind = $resource.name })
        }
    }
    $cleanupDeadline = (Get-Date).ToUniversalTime().AddMinutes(8)
    do {
        $vmGone = (Invoke-JsonRequest -Method GET -Uri $vmUri -BearerToken $Token -AllowHttpError).statusCode -eq 404
        $vmiGone = (Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token -AllowHttpError).statusCode -eq 404
        $serviceGone = (Invoke-JsonRequest -Method GET -Uri $serviceUri -BearerToken $Token -AllowHttpError).statusCode -eq 404
        $pvcGone = (Invoke-JsonRequest -Method GET -Uri $pvcUri -BearerToken $Token -AllowHttpError).statusCode -eq 404
        if ($vmGone -and $vmiGone -and $serviceGone -and $pvcGone) { break }
        if ((Get-Date).ToUniversalTime() -gt $cleanupDeadline) {
            throw 'Timed out removing previous storage-validation resources.'
        }
        Start-Sleep -Seconds 5
    } while ($true)

    $pvcDocument = [ordered]@{
        apiVersion = 'v1'
        kind = 'PersistentVolumeClaim'
        metadata = [ordered]@{
            name = $PvcName
            namespace = $Namespace
            labels = [ordered]@{
                'layersentry.io/validation' = 'persistent-vm-disk'
                'layersentry.io/retained' = 'true'
            }
            annotations = [ordered]@{
                'layersentry.io/test-class' = 'poc-storage-not-production-approval'
            }
        }
        spec = [ordered]@{
            accessModes = @('ReadWriteOnce')
            volumeMode = 'Block'
            storageClassName = $StorageClassName
            resources = [ordered]@{ requests = [ordered]@{ storage = '2Gi' } }
        }
    }
    Invoke-JsonRequest -Method POST `
        -Uri "$proxy/api/v1/namespaces/$Namespace/persistentvolumeclaims" `
        -BearerToken $Token -Body $pvcDocument | Out-Null
    Write-Timeline -Record ([pscustomobject]@{
        event = 'pvc-created'
        pvc = $PvcName
        storageClass = $StorageClassName
        requestedStorage = '2Gi'
        volumeMode = 'Block'
    })

    do {
        $Pvc = (Invoke-JsonRequest -Method GET -Uri $pvcUri -BearerToken $Token).body
        Write-Timeline -Record ([pscustomobject]@{
            event = 'pvc-probe'
            phase = [string]$Pvc.status.phase
            volumeName = [string]$Pvc.spec.volumeName
            capacity = [string]$Pvc.status.capacity.storage
        })
        if ([string]$Pvc.status.phase -eq 'Bound') { break }
        if ((Get-Date).ToUniversalTime() -ge $Deadline) {
            throw "PVC $PvcName did not become Bound within $TimeoutMinutes minutes."
        }
        Start-Sleep -Seconds 5
    } while ($true)

    $labels = [ordered]@{
        'layersentry.io/validation' = 'persistent-storage-vm'
        'layersentry.io/retained' = 'true'
        app = $VmName
    }
    $cloudConfig = @"
#cloud-config
hostname: layersentry-storage
manage_etc_hosts: true
ssh_pwauth: false
ssh_authorized_keys:
  - $publicKey
"@
    $vmDocument = [ordered]@{
        apiVersion = 'kubevirt.io/v1'
        kind = 'VirtualMachine'
        metadata = [ordered]@{
            name = $VmName
            namespace = $Namespace
            labels = $labels
            annotations = [ordered]@{
                'layersentry.io/test-class' = 'persistent-storage-restart-validation'
                'layersentry.io/container-disk' = $ContainerDiskImage
            }
        }
        spec = [ordered]@{
            runStrategy = 'Always'
            template = [ordered]@{
                metadata = [ordered]@{ labels = $labels }
                spec = [ordered]@{
                    terminationGracePeriodSeconds = 0
                    domain = [ordered]@{
                        cpu = [ordered]@{ cores = 1; sockets = 1; threads = 1 }
                        resources = [ordered]@{
                            requests = [ordered]@{ memory = '256Mi' }
                            limits = [ordered]@{ memory = '512Mi' }
                        }
                        devices = [ordered]@{
                            disks = @(
                                [ordered]@{ name = 'containerdisk'; disk = [ordered]@{ bus = 'virtio' } },
                                [ordered]@{ name = 'persistentdisk'; disk = [ordered]@{ bus = 'virtio' } },
                                [ordered]@{ name = 'cloudinitdisk'; disk = [ordered]@{ bus = 'virtio' } }
                            )
                            interfaces = @(
                                [ordered]@{
                                    name = 'default'
                                    masquerade = [ordered]@{}
                                    model = 'virtio'
                                    ports = @([ordered]@{ name = 'ssh'; port = 22; protocol = 'TCP' })
                                }
                            )
                            rng = [ordered]@{}
                        }
                    }
                    networks = @([ordered]@{ name = 'default'; pod = [ordered]@{} })
                    volumes = @(
                        [ordered]@{
                            name = 'containerdisk'
                            containerDisk = [ordered]@{ image = $ContainerDiskImage; imagePullPolicy = 'IfNotPresent' }
                        },
                        [ordered]@{
                            name = 'persistentdisk'
                            persistentVolumeClaim = [ordered]@{ claimName = $PvcName }
                        },
                        [ordered]@{
                            name = 'cloudinitdisk'
                            cloudInitNoCloud = [ordered]@{ userData = $cloudConfig }
                        }
                    )
                }
            }
        }
    }
    Invoke-JsonRequest -Method POST `
        -Uri "$proxy/apis/kubevirt.io/v1/namespaces/$Namespace/virtualmachines" `
        -BearerToken $Token -Body $vmDocument | Out-Null

    $serviceDocument = [ordered]@{
        apiVersion = 'v1'
        kind = 'Service'
        metadata = [ordered]@{ name = "$VmName-ssh"; namespace = $Namespace; labels = $labels }
        spec = [ordered]@{
            type = 'NodePort'
            selector = [ordered]@{ 'layersentry.io/validation' = 'persistent-storage-vm' }
            ports = @([ordered]@{ name = 'ssh'; protocol = 'TCP'; port = 22; targetPort = 22 })
        }
    }
    Invoke-JsonRequest -Method POST `
        -Uri "$proxy/api/v1/namespaces/$Namespace/services" `
        -BearerToken $Token -Body $serviceDocument | Out-Null
    Write-Timeline -Record ([pscustomobject]@{
        event = 'storage-vm-created'
        vm = $VmName
        pvc = $PvcName
        containerDisk = $ContainerDiskImage
    })

    do {
        $vmiResponse = Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token -AllowHttpError
        $serviceResponse = Invoke-JsonRequest -Method GET -Uri $serviceUri -BearerToken $Token -AllowHttpError
        if ($serviceResponse.statusCode -ge 200 -and $serviceResponse.statusCode -lt 300 -and @($serviceResponse.body.spec.ports).Count -gt 0) {
            $NodePort = [int]$serviceResponse.body.spec.ports[0].nodePort
        }
        if ($vmiResponse.statusCode -ge 200 -and $vmiResponse.statusCode -lt 300) {
            $vmi = $vmiResponse.body
            $phase = [string]$vmi.status.phase
            $ready = Get-ReadyCondition -Vmi $vmi
            Write-Timeline -Record ([pscustomobject]@{
                event = 'vmi-before-restart-probe'
                uid = [string]$vmi.metadata.uid
                phase = $phase
                ready = $ready
                nodeName = [string]$vmi.status.nodeName
                nodePort = $NodePort
            })
            if ($phase -eq 'Failed') { throw 'Storage validation VMI entered phase Failed.' }
            if ($phase -eq 'Running' -and $ready -eq 'True' -and $null -ne $NodePort) {
                $VmiUidBefore = [string]$vmi.metadata.uid
                $VmiNodeBefore = [string]$vmi.status.nodeName
                break
            }
        }
        if ((Get-Date).ToUniversalTime() -ge $Deadline) {
            throw 'Storage validation VM did not become Running and Ready before timeout.'
        }
        Start-Sleep -Seconds 10
    } while ($true)

    $SshAddressBefore = Wait-ForSsh -Port $NodePort -Until $Deadline
    if (-not $SshAddressBefore) { throw 'Storage validation guest did not accept SSH before timeout.' }

    $markerLength = $Marker.Length
    $writeCommand = "printf '$Marker' | sudo dd of=/dev/vdb bs=1 conv=fsync 2>/dev/null && sudo dd if=/dev/vdb bs=1 count=$markerLength 2>/dev/null"
    $writeResult = Invoke-SshCommand -Address $SshAddressBefore -Port $NodePort -Command $writeCommand -TimeoutSeconds 60
    $WriteOutput = $writeResult.stdout.Trim()
    if ($writeResult.exitCode -ne 0 -or $WriteOutput -ne $Marker) {
        throw "Failed to write and immediately read the persistent block marker. SSH exit=$($writeResult.exitCode); stderr=$($writeResult.stderr)"
    }
    Write-Timeline -Record ([pscustomobject]@{
        event = 'marker-written'
        markerSha256 = $MarkerHash
        markerLength = $markerLength
        guestDevice = '/dev/vdb'
        sshNodeAddress = $SshAddressBefore
        nodePort = $NodePort
    })

    Invoke-JsonRequest -Method DELETE -Uri $vmiUri -BearerToken $Token | Out-Null
    Write-Timeline -Record ([pscustomobject]@{
        event = 'vmi-deleted-for-restart'
        oldUid = $VmiUidBefore
        oldNode = $VmiNodeBefore
    })

    do {
        $vmiResponse = Invoke-JsonRequest -Method GET -Uri $vmiUri -BearerToken $Token -AllowHttpError
        if ($vmiResponse.statusCode -ge 200 -and $vmiResponse.statusCode -lt 300) {
            $vmi = $vmiResponse.body
            $uid = [string]$vmi.metadata.uid
            $phase = [string]$vmi.status.phase
            $ready = Get-ReadyCondition -Vmi $vmi
            Write-Timeline -Record ([pscustomobject]@{
                event = 'vmi-after-restart-probe'
                uid = $uid
                phase = $phase
                ready = $ready
                nodeName = [string]$vmi.status.nodeName
            })
            if ($phase -eq 'Failed') { throw 'Recreated storage VMI entered phase Failed.' }
            if ($uid -and $uid -ne $VmiUidBefore -and $phase -eq 'Running' -and $ready -eq 'True') {
                $VmiUidAfter = $uid
                $VmiNodeAfter = [string]$vmi.status.nodeName
                break
            }
        }
        if ((Get-Date).ToUniversalTime() -ge $Deadline) {
            throw 'Storage VMI did not restart with a new UID and Ready=True before timeout.'
        }
        Start-Sleep -Seconds 10
    } while ($true)

    $SshAddressAfter = Wait-ForSsh -Port $NodePort -Until $Deadline
    if (-not $SshAddressAfter) { throw 'Recreated storage guest did not accept SSH before timeout.' }
    $readCommand = "sudo dd if=/dev/vdb bs=1 count=$markerLength 2>/dev/null"
    $readResult = Invoke-SshCommand -Address $SshAddressAfter -Port $NodePort -Command $readCommand -TimeoutSeconds 60
    $ReadOutput = $readResult.stdout.Trim()
    if ($readResult.exitCode -ne 0 -or $ReadOutput -ne $Marker) {
        throw "Persistent block marker did not survive VMI restart. SSH exit=$($readResult.exitCode); stderr=$($readResult.stderr)"
    }
    Write-Timeline -Record ([pscustomobject]@{
        event = 'marker-verified-after-restart'
        markerSha256 = $MarkerHash
        oldVmiUid = $VmiUidBefore
        newVmiUid = $VmiUidAfter
        oldNode = $VmiNodeBefore
        newNode = $VmiNodeAfter
        sshNodeAddress = $SshAddressAfter
    })

    $Pvc = (Invoke-JsonRequest -Method GET -Uri $pvcUri -BearerToken $Token).body
    $pvName = [string]$Pvc.spec.volumeName
    if ([string]::IsNullOrWhiteSpace($pvName)) { throw 'Bound PVC has no PersistentVolume name.' }
    $PersistentVolume = (Invoke-JsonRequest -Method GET `
        -Uri "$proxy/api/v1/persistentvolumes/$pvName" `
        -BearerToken $Token).body
    $volumeHandle = [string]$PersistentVolume.spec.csi.volumeHandle
    if ([string]::IsNullOrWhiteSpace($volumeHandle)) { throw 'PersistentVolume has no CSI volumeHandle.' }

    $longhornResponse = Invoke-JsonRequest -Method GET `
        -Uri "$proxy/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes/$volumeHandle" `
        -BearerToken $Token `
        -AllowHttpError
    if ($longhornResponse.statusCode -ge 200 -and $longhornResponse.statusCode -lt 300) {
        $LonghornVolume = $longhornResponse.body
        if ([string]$LonghornVolume.status.robustness -ne 'healthy') {
            throw "Longhorn volume robustness is '$($LonghornVolume.status.robustness)' instead of healthy."
        }
        if ([int]$LonghornVolume.spec.numberOfReplicas -lt 2) {
            throw "Longhorn volume has only $($LonghornVolume.spec.numberOfReplicas) configured replicas."
        }
    }
    else {
        throw "Longhorn volume resource $volumeHandle could not be read."
    }

    $Passed = $true
}
catch {
    $Failure = $_.Exception.Message
    Write-Timeline -Record ([pscustomobject]@{ event = 'failure'; error = $Failure })
    throw
}
finally {
    $finished = (Get-Date).ToUniversalTime()
    $longhornSummary = if ($null -ne $LonghornVolume) {
        [ordered]@{
            name = [string]$LonghornVolume.metadata.name
            state = [string]$LonghornVolume.status.state
            robustness = [string]$LonghornVolume.status.robustness
            currentNodeId = [string]$LonghornVolume.status.currentNodeID
            ownerId = [string]$LonghornVolume.status.ownerID
            numberOfReplicas = [int]$LonghornVolume.spec.numberOfReplicas
            sizeBytes = [int64]$LonghornVolume.spec.size
            frontend = [string]$LonghornVolume.spec.frontend
            accessMode = [string]$LonghornVolume.spec.accessMode
        }
    } else { $null }
    $pvcSummary = if ($null -ne $Pvc) {
        [ordered]@{
            namespace = [string]$Pvc.metadata.namespace
            name = [string]$Pvc.metadata.name
            uid = [string]$Pvc.metadata.uid
            phase = [string]$Pvc.status.phase
            storageClassName = [string]$Pvc.spec.storageClassName
            volumeMode = [string]$Pvc.spec.volumeMode
            accessModes = @($Pvc.spec.accessModes)
            requestedStorage = [string]$Pvc.spec.resources.requests.storage
            capacity = [string]$Pvc.status.capacity.storage
            persistentVolume = [string]$Pvc.spec.volumeName
        }
    } else { $null }
    $pvSummary = if ($null -ne $PersistentVolume) {
        [ordered]@{
            name = [string]$PersistentVolume.metadata.name
            phase = [string]$PersistentVolume.status.phase
            capacity = [string]$PersistentVolume.spec.capacity.storage
            storageClassName = [string]$PersistentVolume.spec.storageClassName
            volumeMode = [string]$PersistentVolume.spec.volumeMode
            csiDriver = [string]$PersistentVolume.spec.csi.driver
            volumeHandle = [string]$PersistentVolume.spec.csi.volumeHandle
            reclaimPolicy = [string]$PersistentVolume.spec.persistentVolumeReclaimPolicy
        }
    } else { $null }
    $result = [ordered]@{
        schemaVersion = '1.0'
        startedAtUtc = $Start.ToString('o')
        finishedAtUtc = $finished.ToString('o')
        durationSeconds = [int64]($finished - $Start).TotalSeconds
        authenticated = -not [string]::IsNullOrWhiteSpace($Token)
        authenticatedUser = $LoginUser
        credentialValuesRetained = $false
        temporaryPrivateKeyRetained = $false
        namespace = $Namespace
        virtualMachine = $VmName
        retainedForUserInspection = $true
        containerDiskImage = $ContainerDiskImage
        storageClassName = $StorageClassName
        pvc = $pvcSummary
        persistentVolume = $pvSummary
        longhornVolume = $longhornSummary
        markerSha256 = $MarkerHash
        markerLength = $Marker.Length
        markerValueRetained = $false
        writeVerifiedBeforeRestart = $null -ne $WriteOutput -and $WriteOutput -eq $Marker
        readVerifiedAfterRestart = $null -ne $ReadOutput -and $ReadOutput -eq $Marker
        oldVmiUid = $VmiUidBefore
        newVmiUid = $VmiUidAfter
        vmiRecreated = $VmiUidBefore -and $VmiUidAfter -and $VmiUidBefore -ne $VmiUidAfter
        oldNode = $VmiNodeBefore
        newNode = $VmiNodeAfter
        sshNodeAddressBefore = $SshAddressBefore
        sshNodeAddressAfter = $SshAddressAfter
        nodePort = $NodePort
        passed = $Passed
        failure = $Failure
        persistentVmStorageQualified = $Passed
        liveMigrationWithPersistentDiskQualified = $false
        haFailureRecoveryQualified = $false
        trueAirgapQualified = $false
        productionReleaseApproved = $false
    }
    $result | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8

    @"
# LayerSentry KubeVirt persistent-storage validation

- VM: $Namespace/$VmName
- PVC: $Namespace/$PvcName
- StorageClass: $StorageClassName
- PVC phase: $($result.pvc.phase)
- CSI driver: $($result.persistentVolume.csiDriver)
- Longhorn robustness: $($result.longhornVolume.robustness)
- Configured Longhorn replicas: $($result.longhornVolume.numberOfReplicas)
- VMI UID before restart: $VmiUidBefore
- VMI UID after restart: $VmiUidAfter
- Marker write verified before restart: $($result.writeVerifiedBeforeRestart)
- Marker read verified after restart: $($result.readVerifiedAfterRestart)
- Persistent VM storage qualified: $($result.persistentVmStorageQualified)
- Validation VM and PVC retained: **true**
- Live migration with persistent disk qualified: **false**
- HA failure recovery qualified: **false**
- True air-gap qualified: **false**
- Production release approved: **false**
- Failure: $($result.failure)
"@ | Set-Content -LiteralPath $StatusPath -Encoding UTF8

    $Token = $null
    $password = $null
    $credentials = $null
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    if (Test-Path -LiteralPath $KeyDirectory) {
        Remove-Item -LiteralPath $KeyDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
