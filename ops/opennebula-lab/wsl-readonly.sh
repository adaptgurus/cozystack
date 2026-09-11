#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
python3 -B -u - <<'PY'
import hashlib,json,pathlib,re
root=pathlib.Path('/home/opc/.local/state/layersentry-runner')
r=json.loads((root/'state.json').read_text())['capability_runs']['d5db2181-14e4-4ab0-8464-493b643130b9']
assert r['capability']=='P1-RKE2'
print('PUBLICATION_OBSERVED='+json.dumps({'state':r['state'],'reason':r.get('reason'),'publication':r['publication']}))
for ref in r['records'][-4:]:
 p=(root/ref['path']).resolve();assert p.is_relative_to(root.resolve())
 assert hashlib.sha256(p.read_bytes()).hexdigest()==ref['sha256']
 rec=json.loads(p.read_text())
 print('PUBLICATION_RECORD='+json.dumps({'label':rec.get('label'),'process_exit_code':rec.get('process',{}).get('exit_code')}))
 for f in rec.get('files',[]):
  if not f['path'].endswith('.stderr'):continue
  p=(root/f['path']).resolve();assert p.is_relative_to(root.resolve())
  assert hashlib.sha256(p.read_bytes()).hexdigest()==f['sha256']
  for line in p.read_text(errors='replace').splitlines()[:16]:
   line=re.sub(r'(?i)(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)','[REDACTED]',line)
   print('PUBLICATION_STDERR='+line[:600])
PY
echo 'READ_ONLY_DIAGNOSIS_COMPLETE; SERVER_MUTATIONS=false; SUPERVISOR_STATE_EDITED=false; PUBLICATION_RETRIED=false'
