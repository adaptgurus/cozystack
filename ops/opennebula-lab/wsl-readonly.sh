#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
python3 -u - <<'PY'
import hashlib,json,pathlib,re,subprocess
root=pathlib.Path('/home/opc/.local/state/layersentry-runner')
rid='d5db2181-14e4-4ab0-8464-493b643130b9'
r=json.loads((root/'state.json').read_text())['capability_runs'][rid]
assert r['capability']=='P1-RKE2'
print('PUBLICATION_DIAGNOSIS='+json.dumps({'state':r['state'],'reason':r.get('reason')}))
b=json.loads((root/'p1-capability/approved-p1-binding-v2.json').read_text())
print('BOUND_TOOL_METADATA='+json.dumps({name:{k:t.get(k) for k in ['path','sha256']} for name,t in b['tools'].items()}))
for field in ['verified_tests','design','final_review','verified_snapshot']:
 v=r.get(field)
 print('RUN_FIELD_'+field.upper()+'='+json.dumps(v))
 if isinstance(v,dict) and 'path' in v and field in ['design','final_review']:
  p=(root/v['path']).resolve();assert p.is_relative_to(root.resolve())
  assert hashlib.sha256(p.read_bytes()).hexdigest()==v['sha256']
  d=json.loads(p.read_text())
  print('REVIEW_DETAILS='+json.dumps({k:d.get(k) for k in ['decision','rationale','subject_sha256']}))
for ref in r['records'][-8:]:
 p=(root/ref['path']).resolve();assert p.is_relative_to(root.resolve())
 assert hashlib.sha256(p.read_bytes()).hexdigest()==ref['sha256']
 rec=json.loads(p.read_text())
 print('EXECUTION_RECORD='+json.dumps({k:rec.get(k) for k in ['label','phase','kind','exit_code','argv','command','files','started_at','ended_at']}))
 for f in rec.get('files',[]):
  p=(root/f['path']).resolve();assert p.is_relative_to(root.resolve())
  assert hashlib.sha256(p.read_bytes()).hexdigest()==f['sha256']
  if any(s in f['path'].lower() for s in ['github','publish']):
   text=p.read_text(errors='replace')
   for line in text.splitlines():
    if re.search(r'Unknown JSON field|unknown flag|HTTP [45][0-9][0-9]|Resource not accessible|not logged|GraphQL|authentication|To get started|Available fields|headRefOid|error:',line,re.I):
     line=re.sub(r'(?i)(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)','[REDACTED]',line)
     print('PUBLICATION_ERROR_LINE='+line[:600])
gh=b['tools']['gh'];p=pathlib.Path(gh['path']);assert hashlib.sha256(p.read_bytes()).hexdigest()==gh['sha256']
x=subprocess.run([str(p),'--version'],capture_output=True,text=True,timeout=15)
print('BOUND_GH_VERSION='+x.stdout.splitlines()[0] if x.stdout else 'BOUND_GH_VERSION_UNAVAILABLE')
print('BOUND_REPOSITORIES='+json.dumps([{k:v.get(k) for k in ['repository','path','base_branch','target_commit','source_scope']} for v in b['repositories']]))
print('VERIFIER_ARGV='+json.dumps([{k:t.get(k) for k in ['id','kind','argv','cwd','inputs']} for t in b['verification']]))
PY
echo 'PUBLICATION_DIAGNOSIS_COMPLETE; SOURCE_MUTATIONS=false; SERVER_MUTATIONS=false; SUPERVISOR_STATE_EDITED=false; PUBLICATION_RETRIED=false'
