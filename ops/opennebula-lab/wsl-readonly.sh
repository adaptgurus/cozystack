#!/usr/bin/env bash
set -euo pipefail
known=${1:?Provide pinned public known_hosts}
key="$HOME/.ssh/opennebula-admin"
[[ -r "$known" && -r "$key" ]] || exit 20
echo CENTRAL_AUTHORITY_COMMIT=9e58d78d6bfaaa923d24fb8b4912ae24e43dc0f7
python3 - <<'LOCAL'
import os,pathlib,subprocess,json,re,shutil
h=pathlib.Path.home()
def run(a,t=15):
 p=subprocess.run(a,capture_output=True,text=True,timeout=t)
 return p.returncode,p.stdout.strip(),p.stderr.strip()
for base in [h/'layersentry',h/'layersentry-live-evidence',h/'.local/state/layersentry-runner/capabilities',h/'.local/state/layersentry-runner/p1-capability',h/'.kube']:
 if base.is_dir(): print('PATH_METADATA='+json.dumps({'path':str(base),'names':sorted(p.name for p in base.iterdir())[:65]}))
for base in [h/'layersentry',h/'.local/state/layersentry-runner/worktrees']:
 if not base.is_dir():continue
 for root,dirs,files in os.walk(base):
  depth=len(pathlib.Path(root).relative_to(base).parts)
  if '.git' in dirs or '.git' in files:
   def git(*a):
    rc,out,err=run(['git','-C',root,*a]);return out if rc==0 else 'UNAVAILABLE'
   remote=re.sub(r'(https?://)[^/@]+@',r'\1[REDACTED]@',git('remote','get-url','origin'))
   print('SOURCE_REPO='+json.dumps({'path':root,'head':git('rev-parse','HEAD'),'branch':git('branch','--show-current'),'remote':remote,'tracked_changes':git('status','--short','--untracked-files=no')}))
   if git('rev-parse','HEAD')!='UNAVAILABLE':dirs[:]=[];continue
  dirs[:]=[d for d in dirs if d not in {'.git','.cache','vendor','node_modules','.venv','go'} and depth<4]
allowed={'status','phase','capability','capability_id','run_id','task_id','central_commit','central_sha','repository','repository_full_name','path','repo_path','worktree','worktree_path','branch','base','base_sha','head','commit','commit_sha','publication_status','exit_code','returncode','outcome','result','reason','blocker','next_action','error','summary','affected_repositories','allowed_paths','source_repositories','artifact_dir','updated_at'}
def safe(x,prefix='',out=None):
 if out is None:out={}
 if isinstance(x,dict):
  for k,v in x.items():
   if re.search('secret|password|credential|token|private|kubeconfig|stdout|stderr|prompt|environment',k,re.I):continue
   path=prefix+'.'+k
   if k in allowed and isinstance(v,(str,int,float,bool,type(None))):
    value=v
    if isinstance(v,str):
     value=re.sub(r'(https?://)[^/@\s]+@',r'\1[REDACTED]@',v)
     value=re.sub(r'(?i)(token|password|secret)\s*[:=]\s*\S+',r'\1=[REDACTED]',value)[:1000]
    out[path]=value
   elif isinstance(v,(dict,list)):safe(v,path,out)
 elif isinstance(x,list):
  for i,v in enumerate(x[:15]):safe(v,prefix+f'[{i}]',out)
 return out
state=h/'.local/state/layersentry-runner'
candidates=[state/'state.json']
for sub in ['capabilities','p1-capability']:
 b=state/sub
 if b.exists():candidates+=list(b.glob('*.json'))+list(b.glob('*/*.json'))
for f in sorted(set(candidates))[:12]:
 if f.is_file() and f.stat().st_size<2000000:
  try:print('SAVED_P1_STATE='+json.dumps({'file':str(f),'fields':safe(json.loads(f.read_text()))}))
  except Exception as e:print('STATE_READ_ERROR='+type(e).__name__)
k=shutil.which('kubectl')
print('WSL_KUBECTL='+str(k))
if k and (h/'.kube/config').is_file():
 rc,out,err=run([k,'config','view','--minify','-o','json'])
 if rc==0:
  c=json.loads(out);servers=[x.get('cluster',{}).get('server') for x in c.get('clusters',[])]
  print('DEFAULT_KUBE_TARGET='+json.dumps({'servers':servers,'context':c.get('current-context'),'exec_auth':any('exec' in x.get('user',{}) for x in c.get('users',[]))}))
  if servers==['https://10.10.10.117:6443'] and not any('exec' in x.get('user',{}) for x in c.get('users',[])):
   for cmd in [['get','--raw=/readyz'],['get','nodes','-o','wide'],['get','pods','-A','-o','wide']]:
    rc,out,err=run([k,'--request-timeout=12s',*cmd],20)
    print('BOUND_KUBE_CHECK='+json.dumps({'command':cmd,'exit':rc,'output':out[:16000],'error':err[:1000]}))
LOCAL
opts=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o ConnectTimeout=7 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known")
ssh "${opts[@]}" oneadmin@10.10.10.21 'bash --noprofile --norc -s' <<'ONE'
set -euo pipefail
[[ $(hostname -s) == rocky-01 && $(id -un) == oneadmin ]] || exit 21
python3 - <<'PY'
import os,pathlib,json
for base in ['/var/lib/one/oneks','/var/lib/one/.one/layersentry-p1','/var/lib/one/layersentry-p1-jobs']:
 b=pathlib.Path(base)
 if b.is_dir():
  print('FRONTEND_TARGET_DIR='+json.dumps({'path':base,'names':sorted(p.name for p in b.iterdir())[:55]}))
  for root,dirs,files in os.walk(b):
   depth=len(pathlib.Path(root).relative_to(b).parts)
   dirs[:]=[d for d in dirs if depth<2 and d not in {'node_modules','.git','vendor'}]
   for f in files:
    if any(w in f.lower() for w in ['kubeconfig','handoff','verify','readme','status']): print('FRONTEND_TARGET_FILE='+str(pathlib.Path(root)/f))
PY
for row in 'rocky-02 one-36' 'rocky-03 one-38' 'rocky-03 one-39'; do
 read -r host domain <<<"$row"
 echo "QEMU_GUEST_AGENT_CHECK=$host/$domain"
 ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=7 "$host" "virsh -c qemu:///system qemu-agent-command $domain '{\"execute\":\"guest-info\"}'" 2>&1 || true
done
echo 'READ_ONLY_RECONCILIATION_COMPLETE; SERVER_MUTATIONS=false'
ONE
