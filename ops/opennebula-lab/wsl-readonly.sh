#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
# Read-only continuation audit. Never print credentials or complete config/state.
python3 -u - <<'PY'
import concurrent.futures,datetime,hashlib,json,pathlib,subprocess,urllib.request
print('OBSERVED_UTC='+datetime.datetime.now(datetime.timezone.utc).isoformat())
root=pathlib.Path('/home/opc/.local/state/layersentry-runner')
rid='d5db2181-14e4-4ab0-8464-493b643130b9'
b=json.loads((root/'p1-capability/approved-p1-binding-v2.json').read_text())
expected={i['path']:i['sha256'] for t in b['verification'] for i in t.get('inputs',[])}
for name in ['/tmp/ls-poc-kubectl','/tmp/ls-poc-kubectl-1.36.4','/tmp/ls-poc-p1-access']:
 assert name in expected and hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()==expected[name], 'BOUND_HELPER_CHANGED:'+name
print('ORIGINAL_BOUND_HELPER_HASHES=PASS')
state=json.loads((root/'state.json').read_text());run=state['capability_runs'][rid]
assert run['capability']=='P1-RKE2'
print('SUPERVISOR_RUN='+json.dumps({'id':rid,'state':run['state'],'fields':list(run),'publication':{name:{k:p.get(k) for k in ['state','branch','commit','url']} for name,p in run.get('publication',{}).items()}}))
for name,sel in run['selected'].items():
 assert name in ['adaptgurus/one','adaptgurus/one-apps','adaptgurus/layersentry-platform']
 p=pathlib.Path(sel['worktree']);assert p==root/'capabilities'/rid/'source'/name.split('/')[1]
 def git(*args):return subprocess.check_output(['git','-C',str(p),*args],text=True,timeout=15).strip()
 assert git('remote','get-url','origin')=='https://github.com/'+name+'.git'
 print('SOURCE_WORKTREE='+json.dumps({'repo':name,'head':git('rev-parse','HEAD'),'branch':git('branch','--show-current'),'status':git('status','--porcelain'),'last_commit':git('log','-1','--format=%h %s')}))
for k in ['verification','final_review','discovery','design_review']:
 v=run.get(k)
 if isinstance(v,dict):
  print('SUPERVISOR_'+k.upper()+'='+json.dumps({x:v[x] for x in ['state','status','decision','path','sha256','passed','attempt','returncode'] if x in v}))
  rel=v.get('path')
  if rel:
   rp=(root/rel).resolve()
   if rp.is_relative_to(root.resolve()) and rp.is_file():
    try:
     item=json.loads(rp.read_text())
     print('RESULT_'+k.upper()+'='+json.dumps({x:item[x] for x in ['decision','status','summary','checks','blockers','evidence'] if x in item}))
    except (ValueError,UnicodeError): pass
 elif v is not None: print('SUPERVISOR_'+k.upper()+'_TYPE='+type(v).__name__)
print('BOUND_VERIFIER_METADATA='+json.dumps([{k:t.get(k) for k in ['id','name','kind','cwd','timeout_seconds']} for t in b['verification']]))
print('P1_LOCAL_REPORT_FILENAMES='+json.dumps(sorted(p.name for p in (root/'p1-capability').iterdir() if p.is_file() and p.suffix in ['.json','.sh','.py','.md'])[:60]))
central=pathlib.Path('/tmp/layersentry-execution-control-20260910')
print('LOCAL_AUTHORITY_HEAD='+subprocess.check_output(['git','-C',str(central),'rev-parse','HEAD'],text=True).strip())
# Public GitHub metadata only, no credential lookup and no writes.
def audit_repo(repo):
 def get(path):
  req=urllib.request.Request('https://api.github.com/repos/'+repo+path,headers={'Accept':'application/vnd.github+json','User-Agent':'LayerSentry-ReadOnly-POC-Audit'})
  with urllib.request.urlopen(req,timeout=15) as f:return json.load(f)
 try:
  info=get('');default=info['default_branch'];ref=get('/git/ref/heads/'+default)
  prs=get('/pulls?state=all&per_page=10')
  return {'repo':repo,'default_branch':default,'default_head':ref['object']['sha'],'prs':[{'number':p['number'],'state':p['state'],'merged_at':p['merged_at'],'head':p['head']['ref'],'head_sha':p['head']['sha'],'base':p['base']['ref'],'base_sha':p['base']['sha'],'merge_commit_sha':p.get('merge_commit_sha'),'url':p['html_url']} for p in prs if (repo=='adaptgurus/codexagentlogic' and p['number']==1) or 'p1-rke2' in p['head']['ref']]}
 except Exception as e:return {'repo':repo,'error':type(e).__name__}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
 for report in pool.map(audit_repo,['adaptgurus/codexagentlogic','adaptgurus/one','adaptgurus/one-apps','adaptgurus/layersentry-platform']):print('GITHUB_MERGE_AUDIT='+json.dumps(report))
kubectl='/tmp/ls-poc-kubectl'
r=subprocess.run([kubectl,'config','view','--minify','-o','json'],capture_output=True,text=True,timeout=15);assert r.returncode==0
c=json.loads(r.stdout);assert [x['cluster']['server'] for x in c.get('clusters',[])]==['https://10.10.10.117:6443']
assert not any('exec' in x.get('user',{}) for x in c.get('users',[]))
for command in [['get','--raw=/readyz'],['get','nodes','-o','json'],['get','pods','-A','-o','json']]:
 r=subprocess.run([kubectl,'--request-timeout=15s',*command],capture_output=True,text=True,timeout=25)
 assert r.returncode==0,'KUBERNETES_READ_FAILED:'+str(command)
 if command[1]=='--raw=/readyz':print('LIVE_API_READYZ='+r.stdout.strip());assert r.stdout.strip()=='ok'
 elif command[1]=='nodes':
  nodes=json.loads(r.stdout)['items']
  for n in nodes:
   s=n['status'];conds={c['type']:c['status'] for c in s.get('conditions',[])}
   print('LIVE_NODE='+json.dumps({'name':n['metadata']['name'],'providerID':n['spec'].get('providerID'),'version':s['nodeInfo']['kubeletVersion'],'conditions':conds,'allocatable':s.get('allocatable'),'addresses':s.get('addresses'),'unschedulable':n['spec'].get('unschedulable',False)}))
  print('LIVE_READY_NODE_COUNT='+str(sum(any(c['type']=='Ready' and c['status']=='True' for c in n['status']['conditions']) for n in nodes)))
 else:
  pods=json.loads(r.stdout)['items'];bad=[]
  for p in pods:
   cs=p['status'].get('containerStatuses',[])
   if p['status'].get('phase') not in ['Succeeded'] and (p['status'].get('phase')!='Running' or not cs or not all(c.get('ready') for c in cs)):bad.append(p['metadata']['namespace']+'/'+p['metadata']['name'])
  print('POD_HEALTH='+json.dumps({'total':len(pods),'not_healthy':bad,'namespaces':sorted(set(p['metadata']['namespace'] for p in pods))}))
print('PRIVATE_KUBECONFIG_EXPORTED=false')
PY
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$HOME/.ssh/opennebula-admin" rocky-01 'bash --noprofile --norc -s' <<'ONE'
set -euo pipefail
[[ $(hostname -s) == rocky-01 && $(id -un) == oneadmin ]] || exit 30
onehost list
onevm list
onehost list -x | python3 -c 'import sys,json,xml.etree.ElementTree as E;r=E.parse(sys.stdin).getroot();[print("HOST_CAPACITY="+json.dumps({k:h.findtext(k) for k in ["ID","NAME","STATE","HOST_SHARE/MAX_CPU","HOST_SHARE/CPU_USAGE","HOST_SHARE/MAX_MEM","HOST_SHARE/MEM_USAGE","HOST_SHARE/FREE_MEM"]})) for h in r.findall("HOST")]'
for host in rocky-02 rocky-03; do
 echo "HOST_STORAGE=$host"
 onehost show "$host" | grep -A4 'LOCAL SYSTEM DATASTORE'
 ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" 'hostname; free -m; df -hT /var/lib/one/datastores; virsh -c qemu:///system list --all'
done
ONE
echo 'CONTINUATION_AUDIT_COMPLETE; SERVER_MUTATIONS=false; NEW_WORKERS_CREATED=0; MERGES_PERFORMED=0'
