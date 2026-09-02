[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-cluster-machine-plan-diagnostic')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    [System.IO.File]::WriteAllText(
        $Path,
        $Value,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Protect-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    foreach ($identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        [void]$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            $fullControl,
            $inheritance,
            $propagation,
            $allow
        )))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
    throw "Diagnostic request is missing: $RequestPath"
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$request.operation -ne 'READ_ONLY_CLUSTER_MACHINE_PLAN_DIAGNOSTIC') {
    throw "Unsupported operation: $($request.operation)"
}
if ([string]$request.authorization -ne 'USER_GRANTED_FULL_POWERSHELL_AND_INSTALL_PERMISSION') {
    throw 'The request is missing the user authorization marker.'
}
if ([string]$request.primaryNodeAddress -ne '10.10.10.11') {
    throw 'The diagnostic primary node must be 10.10.10.11.'
}
if ([bool]$request.modifyClusterState -or [bool]$request.writeCredentialValuesToEvidence) {
    throw 'This machine-plan diagnostic must be read-only and sanitized.'
}

if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
    throw "Protected credential file is missing: $CredentialPath"
}
$credentials = Get-Content -LiteralPath $CredentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nodePassword = [string]$credentials.nodePassword
if ([string]::IsNullOrWhiteSpace($nodePassword)) {
    throw 'Protected node password is missing.'
}
[string[]]$sensitiveValues = @(
    [string]$credentials.nodePassword,
    [string]$credentials.clusterToken,
    [string]$credentials.adminPassword
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
$temporaryDirectory = Join-Path $env:RUNNER_TEMP ('layersentry-machine-plan-secure-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $temporaryDirectory -ItemType Directory -Force | Out-Null
Protect-Directory -Path $temporaryDirectory

function Protect-Text {
    param([AllowNull()][string]$Text)
    $safe = [string]$Text
    foreach ($secret in $sensitiveValues) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $safe = $safe.Replace($secret, '[REDACTED]')
        }
    }
    $safe = [regex]::Replace(
        $safe,
        '(?i)K10[a-z0-9]{20,}::server:[a-z0-9]{20,}',
        '[REDACTED-RKE2-TOKEN]'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?im)^(\s*(?:token|password|authorization|credential|rke2_token)\s*[:=]).+$',
        '$1 [REDACTED]'
    )
    return $safe
}

$ssh = Get-Command -Name 'ssh.exe' -ErrorAction Stop | Select-Object -First 1
$passwordPath = Join-Path $temporaryDirectory 'node-password.txt'
$askPassPath = Join-Path $temporaryDirectory 'askpass.cmd'
Write-Utf8NoBom -Path $passwordPath -Value ($nodePassword + "`r`n")
Write-Utf8NoBom -Path $askPassPath -Value ("@echo off`r`ntype `"$passwordPath`"`r`n")
$oldAskPass = [Environment]::GetEnvironmentVariable('SSH_ASKPASS')
$oldAskPassRequire = [Environment]::GetEnvironmentVariable('SSH_ASKPASS_REQUIRE')
$oldDisplay = [Environment]::GetEnvironmentVariable('DISPLAY')
$env:SSH_ASKPASS = $askPassPath
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'LayerSentry'
$nodePasswordB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($nodePassword))

$remoteTemplate = @'
set -Eeuo pipefail
umask 077
work=$(mktemp -d /tmp/layersentry-machine-plan.XXXXXX)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
printf '%s' '{{NODE_PASSWORD_B64}}' | base64 -d > "$work/node-password"
printf '\n' >> "$work/node-password"
chmod 0600 "$work/node-password"
if ! sudo -n true >/dev/null 2>&1; then
  sudo -S -p '' -v < "$work/node-password"
fi
kubectl_path=''
for candidate in /var/lib/rancher/rke2/bin/kubectl /opt/rke2/bin/kubectl /usr/local/bin/kubectl /usr/bin/kubectl; do
  if [ -x "$candidate" ]; then kubectl_path="$candidate"; break; fi
done
if [ -z "$kubectl_path" ]; then
  echo 'LAYERSENTRY_MACHINE_PLAN_ERROR:kubectl-not-found'
  exit 81
fi
kubeconfig=/etc/rancher/rke2/rke2.yaml
K="sudo -n $kubectl_path --kubeconfig $kubeconfig"
echo '===cluster-identity==='
hostname
date -u
echo "kubectl=${kubectl_path}"
$K version --output=json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"clientVersion":d.get("clientVersion"),"serverVersion":d.get("serverVersion")},sort_keys=True))'
echo '===node-role-summary==='
$K get nodes -o json > "$work/nodes.json"
python3 - "$work/nodes.json" <<'PY'
import json,sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
for item in obj.get('items',[]):
    md=item.get('metadata') or {}
    labels=md.get('labels') or {}
    conditions={c.get('type'):c.get('status') for c in (item.get('status') or {}).get('conditions',[]) if isinstance(c,dict)}
    selected={k:v for k,v in labels.items() if k.startswith('node-role.kubernetes.io/') or k in ('kubernetes.io/hostname','rke.cattle.io/machine','rke.cattle.io/control-plane-role','rke.cattle.io/etcd-role','rke.cattle.io/worker-role')}
    print(json.dumps({'node':md.get('name'),'labels':selected,'ready':conditions.get('Ready')},sort_keys=True))
PY
echo '===api-resources==='
$K api-resources --verbs=list --namespaced=true 2>/dev/null | grep -Ei 'machine|rkecontrol|bootstrap|plan' || true
echo '===provisioning-machines==='
if ! $K get machines.provisioning.cattle.io -A -o json > "$work/provisioning-machines.json" 2>/dev/null; then echo '{"items":[]}' > "$work/provisioning-machines.json"; fi
if ! $K get machines.cluster.x-k8s.io -A -o json > "$work/capi-machines.json" 2>/dev/null; then echo '{"items":[]}' > "$work/capi-machines.json"; fi
if ! $K get rkecontrolplanes.rke.cattle.io -A -o json > "$work/rkecontrolplanes.json" 2>/dev/null; then echo '{"items":[]}' > "$work/rkecontrolplanes.json"; fi
python3 - "$work/provisioning-machines.json" "$work/capi-machines.json" "$work/rkecontrolplanes.json" <<'PY'
import json,sys,re
safe_key=re.compile(r'(role|node.?name|machine.?name|plan|cluster.?name|infrastructure.?ref|bootstrap|provider.?id)',re.I)
def selected(value,depth=0):
    if depth>8:return None
    if isinstance(value,dict):
        out={}
        for k,v in value.items():
            if re.search(r'token|password|secret|credential|kubeconfig',k,re.I):
                continue
            if safe_key.search(k):
                out[k]=v if not isinstance(v,(dict,list)) else selected(v,depth+1)
            elif isinstance(v,(dict,list)):
                nested=selected(v,depth+1)
                if nested not in (None,{},[]):out[k]=nested
        return out
    if isinstance(value,list):
        return [x for x in (selected(v,depth+1) for v in value) if x not in (None,{},[])]
    return value
for path,kind in zip(sys.argv[1:],('provisioning.cattle.io/Machine','cluster.x-k8s.io/Machine','rke.cattle.io/RKEControlPlane')):
    obj=json.load(open(path,encoding='utf-8'))
    for item in obj.get('items',[]):
        md=item.get('metadata') or {}
        print(json.dumps({'kind':kind,'namespace':md.get('namespace'),'name':md.get('name'),'labels':selected(md.get('labels') or {}),'annotations':selected(md.get('annotations') or {}),'spec':selected(item.get('spec') or {}),'status':selected(item.get('status') or {})},sort_keys=True,default=str))
PY
echo '===machine-plan-secrets==='
$K -n fleet-local get secrets -o json > "$work/secrets.json"
python3 - "$work/secrets.json" <<'PY'
import base64,hashlib,json,re,sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
def collect_type(value,path='$'):
    found=[]
    if isinstance(value,dict):
        for k,v in value.items():
            np=f'{path}.{k}'
            if str(k).upper()=='INSTALL_RKE2_TYPE':found.append({'path':np,'value':v})
            found.extend(collect_type(v,np))
    elif isinstance(value,list):
        for i,v in enumerate(value):found.extend(collect_type(v,f'{path}[{i}]'))
    return found
def safe_meta(d):
    out={}
    for k,v in (d or {}).items():
        if re.search(r'token|password|secret|credential|kubeconfig',str(k),re.I):continue
        out[k]=v
    return out
for item in obj.get('items',[]):
    md=item.get('metadata') or {}
    name=md.get('name','')
    if not name.endswith('-machine-plan'):continue
    data=item.get('data') or {}
    encoded=data.get('plan','')
    raw=b''
    plan=None
    error=None
    try:
        raw=base64.b64decode(encoded)
        plan=json.loads(raw.decode('utf-8'))
    except Exception as exc:error=type(exc).__name__+': '+str(exc)
    instructions=[]
    if isinstance(plan,dict):
        for ins in plan.get('instructions') or []:
            if not isinstance(ins,dict):continue
            env=ins.get('env') or {}
            selected_env={k:v for k,v in env.items() if re.search(r'(INSTALL_RKE2_TYPE|INSTALL_RKE2_VERSION|RKE2_DATA_DIR|CATTLE_ROLE)',str(k),re.I)} if isinstance(env,dict) else {}
            instructions.append({'name':ins.get('name'),'command':ins.get('command'),'args':ins.get('args'),'selectedEnv':selected_env})
    result={
        'name':name,
        'creationTimestamp':md.get('creationTimestamp'),
        'ownerReferences':md.get('ownerReferences') or [],
        'labels':safe_meta(md.get('labels')),
        'annotations':safe_meta(md.get('annotations')),
        'resourceVersion':md.get('resourceVersion'),
        'dataKeys':sorted(data.keys()),
        'planSha256':hashlib.sha256(raw).hexdigest() if raw else None,
        'installRke2TypeOccurrences':collect_type(plan) if plan is not None else [],
        'instructions':instructions,
        'decodeError':error,
    }
    print(json.dumps(result,sort_keys=True,default=str))
PY
echo '===target-plan-feedback==='
$K -n fleet-local get secret custom-81a2c5e94b13-machine-plan -o json > "$work/target.json"
python3 - "$work/target.json" <<'PY'
import base64,hashlib,json,re,sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
md=obj.get('metadata') or {}
data=obj.get('data') or {}
out={'name':md.get('name'),'namespace':md.get('namespace'),'ownerReferences':md.get('ownerReferences') or [],'labels':md.get('labels') or {},'annotations':{k:v for k,v in (md.get('annotations') or {}).items() if not re.search(r'token|password|secret|credential',k,re.I)},'data':{}}
for key,value in data.items():
    try:raw=base64.b64decode(value)
    except Exception:raw=b''
    out['data'][key]={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest() if raw else None}
    if key in ('appliedChecksum','checksum','failureCount','probeStatus'):
        try:out['data'][key]['text']=raw.decode('utf-8')[:2000]
        except Exception:pass
print(json.dumps(out,sort_keys=True,default=str))
PY
echo '===diagnostic-complete==='
'@
$remoteScript = $remoteTemplate.Replace('{{NODE_PASSWORD_B64}}', $nodePasswordB64)
$scriptPath = Join-Path $temporaryDirectory 'machine-plan.sh'
$stdoutPath = Join-Path $temporaryDirectory 'machine-plan.stdout.raw'
$stderrPath = Join-Path $temporaryDirectory 'machine-plan.stderr.raw'
Write-Utf8NoBom -Path $scriptPath -Value ($remoteScript -replace "`r`n", "`n")

try {
    $arguments = @(
        '-T',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'PreferredAuthentications=password,keyboard-interactive',
        '-o', 'PubkeyAuthentication=no',
        '-o', 'NumberOfPasswordPrompts=1',
        '-o', 'ConnectTimeout=15',
        'rancher@10.10.10.11',
        'bash', '-s'
    )
    $process = Start-Process `
        -FilePath $ssh.Source `
        -ArgumentList $arguments `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardInput $scriptPath `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath
    $stdout = [string](Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
    $stderr = [string](Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
    $safe = Protect-Text -Text ($stdout + "`n===ssh-stderr===`n" + $stderr)
    Write-Utf8NoBom -Path (Join-Path $OutputDirectory 'cluster-machine-plans.txt') -Value $safe
    [ordered]@{
        schemaVersion = '1.0'
        capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        primaryNode = '10.10.10.11'
        sshExitCode = [int]$process.ExitCode
        targetPlanSecret = 'fleet-local/custom-81a2c5e94b13-machine-plan'
        diagnosticCompleted = ($stdout -match '===diagnostic-complete===')
        clusterStateModified = $false
        credentialValuesWrittenToEvidence = $false
        productionReleaseApproved = $false
    } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'summary.json') -Encoding UTF8
    if ($process.ExitCode -ne 0 -or $stdout -notmatch '===diagnostic-complete===') {
        throw "Machine-plan diagnostic failed with SSH exit code $($process.ExitCode)."
    }
}
finally {
    [Environment]::SetEnvironmentVariable('SSH_ASKPASS', $oldAskPass)
    [Environment]::SetEnvironmentVariable('SSH_ASKPASS_REQUIRE', $oldAskPassRequire)
    [Environment]::SetEnvironmentVariable('DISPLAY', $oldDisplay)
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $nodePassword = $null
    $credentials = $null
}
