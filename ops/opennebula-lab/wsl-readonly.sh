#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
py=/tmp/layersentry-python-runtime/cpython-3.12.14-linux-x86_64-gnu/bin/python3.12
"$py" -B -u - <<'PY'
import datetime,hashlib,json,pathlib,re,subprocess,sys
root=pathlib.Path('/home/opc/.local/state/layersentry-runner')
auth=pathlib.Path('/tmp/layersentry-execution-control-20260910')
sys.path.insert(0,str(auth/'tools'))
from capability_control import CapabilitySupervisor
s=CapabilitySupervisor(auth,root)
with s.locked() as state:
 r=state['capability_runs']['d5db2181-14e4-4ab0-8464-493b643130b9']
 s.integrity(r)
 print('FINAL_AUDIT_UTC='+datetime.datetime.now(datetime.timezone.utc).isoformat())
 print('NATIVE_P1_STATE='+r['state'])
 print('NATIVE_P1_REASON='+str(r.get('reason')))
 print('NATIVE_PUBLICATION='+json.dumps(r['publication']))
 review=s.read_artifact(r['final_review'])
 print('FINAL_REVIEW='+json.dumps({k:review[k] for k in ['decision','rationale','subject_sha256']}))
 assert r['state']=='PUBLISHED_STOPPED','PUBLICATION_NOT_COMPLETED'
 receipt=s.accepted(state,'T3.5')
 assert receipt and receipt['evidence_level']=='LIVE_VERIFIED'
 print('NATIVE_P1_MILESTONE='+json.dumps({k:receipt.get(k) for k in ['task','attempt','evidence_level','capability_run']}))
 for rec_ref in r['records']:
  rec=s.read_artifact(rec_ref)
  if rec.get('label','').startswith('verify-rke2-'):
   p=rec.get('process',{})
   print('NATIVE_VERIFIER_PROCESS='+json.dumps({'label':rec['label'],**{k:p.get(k) for k in ['exit_code','timed_out','started_at','ended_at']}}))
 for t in r['verified_tests']:
  p=pathlib.Path(t['stdout']);assert p.resolve().is_relative_to(root.resolve())
  assert hashlib.sha256(p.read_bytes()).hexdigest()==t['sha256']
  text=p.read_text()
  report={'id':t['id'],'kind':t['kind'],'sha256':t['sha256']}
  try:
   j=json.loads(text)
   report.update({k:j[k] for k in ['result','capability','source_sha256','checks','rke2_version','safe_to_retry'] if k in j})
   report['artifact_count']=len(j.get('artifacts',[]))
  except ValueError:
   report['summary_lines']=[l for l in text.splitlines() if re.fullmatch(r'(Ran \d+ tests in [0-9.]+s|OK|\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips)',l.strip())]
  print('PINNED_VERIFIED_TEST='+json.dumps(report))
 package=s.read_artifact(r['package'])
 b=package['binding']
 expected={i['path']:i['sha256'] for t in b['verification'] for i in t.get('inputs',[])}
 for name in ['/tmp/ls-poc-kubectl','/tmp/ls-poc-kubectl-1.36.4','/tmp/ls-poc-p1-access']:
  assert hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()==expected[name]
for args in [['get','--raw=/readyz'],['get','nodes','-o','json'],['get','pods','-A','-o','json']]:
 p=subprocess.run(['/tmp/ls-poc-kubectl','--request-timeout=15s',*args],capture_output=True,text=True,timeout=25)
 assert p.returncode==0,'LIVE_READ_FAILED'
 if args[1]=='--raw=/readyz':print('FINAL_API_READYZ='+p.stdout.strip());assert p.stdout.strip()=='ok'
 elif args[1]=='nodes':
  nodes=json.loads(p.stdout)['items']
  for n in nodes:
   print('FINAL_NODE='+json.dumps({'name':n['metadata']['name'],'providerID':n['spec'].get('providerID'),'version':n['status']['nodeInfo']['kubeletVersion'],'conditions':{c['type']:c['status'] for c in n['status']['conditions']}}))
 else:
  pods=json.loads(p.stdout)['items'];bad=[]
  for pod in pods:
   cs=pod['status'].get('containerStatuses',[])
   if pod['status'].get('phase')!='Succeeded' and (pod['status'].get('phase')!='Running' or not cs or not all(c.get('ready') for c in cs)):bad.append(pod['metadata']['namespace']+'/'+pod['metadata']['name'])
  print('FINAL_PODS='+json.dumps({'count':len(pods),'unhealthy':bad}));assert not bad
PY
echo 'FINAL_AUDIT_COMPLETE; SERVER_MUTATIONS=false; NEW_WORKERS=0; MERGES=0; PRIVATE_KEYS_OR_KUBECONFIG_EXPORTED=false'
