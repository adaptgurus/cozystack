#!/usr/bin/env bash
set -euo pipefail
known=${1:?Provide the pinned public known_hosts path}
key="$HOME/.ssh/opennebula-admin"
[[ -r "$known" && -r "$key" ]] || exit 20
printf 'CENTRAL_AUTHORITY_COMMIT=%s\n' 9e58d78d6bfaaa923d24fb8b4912ae24e43dc0f7
printf 'CENTRAL_CAPABILITY_PR_HEAD=%s\n' ab55a25f4b1421a63718242d8a8f99359d2ab24e
printf 'WSL_HOST=%s WSL_USER=%s\n' "$(hostname)" "$(id -un)"
python3 - <<'LOCAL'
import os, pathlib, subprocess, json, re
home=pathlib.Path.home()
for base in (home, home/'.local/state/layersentry-runner'):
 if base.exists(): print('LOCAL_TOP_LEVEL='+json.dumps({'path':str(base),'names':sorted(p.name for p in base.iterdir())[:50]}))
prune={'.ssh','.kube','.codex','.cache','node_modules','vendor','.venv','datastores','.npm'}
for root,dirs,files in os.walk(home):
 depth=len(pathlib.Path(root).relative_to(home).parts)
 if '.git' in dirs or '.git' in files:
  def git(*a):
   p=subprocess.run(['git','-C',root,*a],capture_output=True,text=True,timeout=10)
   return p.stdout.strip() if p.returncode==0 else 'UNAVAILABLE'
  remote=git('remote','get-url','origin')
  remote=re.sub(r'(https?://)[^/@]+@',r'\1[REDACTED]@',remote)
  print('LOCAL_REPOSITORY='+json.dumps({'path':root,'head':git('rev-parse','HEAD'),'branch':git('branch','--show-current'),'remote':remote,'status':git('status','--short','--untracked-files=no')}))
  dirs[:]=[]
  continue
 dirs[:]=[d for d in dirs if d not in prune and not d.startswith('.') and depth<3]
state=home/'.local/state/layersentry-runner'
if state.exists():
 count=0
 for root,dirs,files in os.walk(state):
  depth=len(pathlib.Path(root).relative_to(state).parts)
  dirs[:]=[d for d in dirs if depth<3]
  for f in files:
   if f.endswith('.json') and count<45:
    print('STATE_FILE_METADATA='+str(pathlib.Path(root)/f)); count+=1
LOCAL
opts=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o ConnectTimeout=7 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes -o LogLevel=ERROR -o "UserKnownHostsFile=$known")
ssh "${opts[@]}" oneadmin@10.10.10.21 'bash --noprofile --norc -s' <<'ONECHECK'
set -euo pipefail
[[ $(id -un) == oneadmin && $(hostname -s) == rocky-01 ]] || exit 21
date -u +%FT%TZ
oned -v | head -1
onehost list
onevm list
python3 - <<'PY'
import json,os,pathlib,subprocess,xml.etree.ElementTree as E
for cmd in ['oneks','kubectl','oneflow','onevrouter','python3']:
 p=subprocess.run(['bash','-c','command -v "$1"','_',cmd],capture_output=True,text=True)
 print('FRONTEND_TOOL='+json.dumps({'tool':cmd,'path':p.stdout.strip()}))
for root in [pathlib.Path('/var/lib/one'),pathlib.Path('/var/lib/one/.one'),pathlib.Path('/opt')]:
 if root.is_dir(): print('FRONTEND_PATH_METADATA='+json.dumps({'path':str(root),'names':sorted(p.name for p in root.iterdir())[:70]}))
for verb in [('onehost','list'),('onevm','list')]:
 pool=E.fromstring(subprocess.check_output([*verb,'--xml'],text=True,timeout=20))
 if verb[0]=='onehost':
  for h in pool.findall('HOST'):
   print('HOST_CAPACITY='+json.dumps({k:h.findtext(k) for k in ['ID','NAME','STATE','HOST_SHARE/MAX_CPU','HOST_SHARE/CPU_USAGE','HOST_SHARE/MAX_MEM','HOST_SHARE/MEM_USAGE','HOST_SHARE/RUNNING_VMS']}))
 else:
  for v in pool.findall('VM'):
   print('VM_STATE='+json.dumps({'id':v.findtext('ID'),'name':v.findtext('NAME'),'state':v.findtext('STATE'),'lcm':v.findtext('LCM_STATE'),'cpu':v.findtext('TEMPLATE/CPU'),'vcpu':v.findtext('TEMPLATE/VCPU'),'memory':v.findtext('TEMPLATE/MEMORY'),'nics':[{k:n.findtext(k) for k in ['NETWORK_ID','IP']} for n in v.findall('TEMPLATE/NIC')]}))
for base in [pathlib.Path('/var/lib/one/.one'),pathlib.Path('/var/lib/one/.kube')]:
 if not base.exists(): continue
 for root,dirs,files in os.walk(base):
  depth=len(pathlib.Path(root).relative_to(base).parts)
  dirs[:]=[d for d in dirs if depth<3]
  for f in files:
   if any(x in f.lower() for x in ['kube','rke2','oneks','poc','handoff']): print('FRONTEND_CLUSTER_FILE_METADATA='+str(pathlib.Path(root)/f))
PY
if sudo -n true 2>/dev/null; then echo FRONTEND_PASSWORDLESS_SUDO=true; else echo FRONTEND_PASSWORDLESS_SUDO=false; fi
for host in rocky-02 rocky-03; do
 echo "COMPUTE=$host"
 onehost show "$host" | grep -A4 -i 'LOCAL SYSTEM' || true
 ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=7 "$host" 'hostname; virsh -c qemu:///system list --all; free -m; df -hT /var/lib/one/datastores'
done
for ip in 172.20.80.30 172.20.80.31 172.20.80.32; do
 echo "GUEST_READ_ONLY_PROBE=$ip"
 if ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=4 -o ConnectionAttempts=1 root@"$ip" 'hostname; id -un; systemctl is-active rke2-server rke2-agent; free -m' 2>&1; then
  echo "GUEST_SSH_SUCCESS=$ip"
 else echo "GUEST_SSH_UNAVAILABLE=$ip"; fi
done
echo 'P1_RECONCILE_READ_ONLY_COMPLETE; SERVER_MUTATIONS=false; KUBERNETES_HEALTH_VERIFIED=false'
ONECHECK
