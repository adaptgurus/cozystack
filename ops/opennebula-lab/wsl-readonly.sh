#!/usr/bin/env bash
set -euo pipefail
known=${1:?Provide pinned public known_hosts}
key="$HOME/.ssh/opennebula-admin"
[[ -r "$known" && -r "$key" ]] || exit 20
echo CENTRAL_AUTHORITY_COMMIT=9e58d78d6bfaaa923d24fb8b4912ae24e43dc0f7
python3 -u - <<'LOCAL'
import pathlib,subprocess,json,re
h=pathlib.Path.home();s=h/'.local/state/layersentry-runner';rid='d5db2181-14e4-4ab0-8464-493b643130b9'
def git(root,*args):
 p=subprocess.run(['git','-C',str(root),*args],capture_output=True,text=True,timeout=12);return p.stdout.strip() if p.returncode==0 else 'UNAVAILABLE'
old=s/'worktrees/bca780bd-53af-435b-ab1d-a7a80ad5818c'
print('CENTRAL_COMMON_GIT_DIR='+git(old,'rev-parse','--git-common-dir'))
print('CENTRAL_PR_OBJECT_AVAILABLE='+str(git(old,'rev-parse','--verify','ab55a25f4b1421a63718242d8a8f99359d2ab24e^{commit}')!='UNAVAILABLE'))
state=json.loads((s/'state.json').read_text());r=state['capability_runs'][rid]
print('LATEST_RUN='+json.dumps({k:r.get(k) for k in ['state','status','phase','reason','updated_at','central_commit']}))
for name,info in r.get('selected',{}).items():
 p=pathlib.Path(info['worktree'])
 print('P1_SELECTED_SOURCE='+json.dumps({'repository':name,'path':str(p),'head':git(p,'rev-parse','HEAD'),'branch':git(p,'branch','--show-current'),'status':git(p,'status','--short'),'base':info.get('base')}))
for name,info in r.get('publication',{}).items():
 print('P1_PUBLICATION='+json.dumps({'repository':name,**{k:info.get(k) for k in ['branch','commit','pushed','pr','pr_url','state','status']}}))
art=s/'artifacts'/rid
print('LATEST_ARTIFACT_NAMES='+json.dumps(sorted(p.name for p in art.iterdir())))
for f in ['final-review.json','0011-verify-rke2-live.record.json','0010-verify-rke2-unit.record.json','0009-verify-rke2-build.record.json','0014-github.record.json']:
 p=art/f
 if p.is_file():
  x=json.loads(p.read_text())
  print('P1_RECEIPT='+json.dumps({'file':f,'fields':{k:x.get(k) for k in ['decision','rationale','result','outcome','exit_code','returncode','status','command','argv','stdout_path','stderr_path','source_sha256'] if k in x},'keys':list(x.keys())}))
b=json.loads((s/'p1-capability/approved-p1-binding-v2.json').read_text())
print('BOUND_SOURCE_PATHS='+json.dumps([{k:v for k,v in r.items() if k in ['repository','root','checkout','source','path','base','base_ref','base_commit','local_path']} for r in b['repositories']]))
LOCAL
opts=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o ConnectTimeout=7 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known")
ssh "${opts[@]}" oneadmin@10.10.10.21 'python3 -u -' <<'ONE'
import json,subprocess,shlex,time,base64,socket
assert socket.gethostname().split('.')[0]=='rocky-01'
common='''set -u
hostname
printf 'OS='; . /etc/os-release; echo "$PRETTY_NAME"
/usr/local/bin/rke2 --version 2>/dev/null | head -2
free -m
ip -4 route
printf 'DEFAULT_DNS='; getent ahostsv4 example.com | head -2
printf 'HTTPS_INTERNET='; curl --silent --show-error --output /dev/null --max-time 10 --write-out '%{http_code}\\n' https://example.com
'''
cp=common+'''systemctl show rke2-server -p ActiveState -p SubState -p NRestarts
K=/var/lib/rancher/rke2/bin/kubectl
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
$K --request-timeout=10s get --raw=/readyz
$K --request-timeout=10s get nodes -o wide
$K --request-timeout=10s get pods -A -o wide
$K --request-timeout=10s get nodes -o 'custom-columns=NAME:.metadata.name,PROVIDER:.spec.providerID,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory'
'''
worker=common+'''systemctl show rke2-agent -p ActiveState -p SubState -p NRestarts
printf 'WORKER_ENDPOINT_TCP='
python3 - <<'NET'
import socket,json
r=[]
for port in [6443,9345]:
 try:
  s=socket.create_connection(('10.10.10.117',port),3);s.close();r.append({'port':port,'connected':True})
 except OSError:r.append({'port':port,'connected':False})
print(json.dumps(r))
NET
'''
targets=[('rocky-02','one-36','174267d3-0771-4f85-b7d1-7ced6ed126b2',cp),('rocky-03','one-38','09e44517-00ef-41bf-8714-12e124985b68',worker),('rocky-03','one-39','52206bda-6941-4bc4-9537-1690436600d4',worker)]
def remote(host,cmd):
 p=subprocess.run(['ssh','-n','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5',host,cmd],capture_output=True,text=True,timeout=15)
 if p.returncode:raise RuntimeError('COMPUTE_COMMAND_FAILED:'+p.stderr[:250])
 return p.stdout.strip()
def qga(host,vm,obj):
 return json.loads(remote(host,'timeout 10s virsh -c qemu:///system qemu-agent-command '+shlex.quote(vm)+' '+shlex.quote(json.dumps(obj))))['return']
for host,vm,uuid,script in targets:
 print('GUEST_HEALTH_TARGET='+host+'/'+vm,flush=True)
 try:
  assert remote(host,'virsh -c qemu:///system domuuid '+vm)==uuid,'VM_UUID_MISMATCH'
  pid=qga(host,vm,{'execute':'guest-exec','arguments':{'path':'/usr/bin/timeout','arg':['45s','/bin/bash','-c',script],'capture-output':True}})['pid']
  deadline=time.monotonic()+52
  while time.monotonic()<deadline:
   result=qga(host,vm,{'execute':'guest-exec-status','arguments':{'pid':pid}})
   if result.get('exited'):
    for name in ['out-data','err-data']:
     if result.get(name):print(base64.b64decode(result[name]).decode('utf-8','replace')[:22000],flush=True)
    print('GUEST_HEALTH_EXIT='+str(result.get('exitcode')),flush=True);break
   time.sleep(1)
  else:print('GUEST_HEALTH=UNKNOWN_TIMEOUT',flush=True)
 except Exception as e:print('GUEST_HEALTH_ERROR='+str(e)[:300],flush=True)
print('READ_ONLY_GUEST_HEALTH_FINISHED; SERVER_MUTATIONS=false; KUBECONFIG_EXPORTED=false')
ONE
