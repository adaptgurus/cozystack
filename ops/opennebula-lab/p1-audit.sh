#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
python3 -u - <<'PY'
import hashlib,json,pathlib,re,subprocess
root=pathlib.Path('/home/opc/.local/state/layersentry-runner');rid='d5db2181-14e4-4ab0-8464-493b643130b9'
r=json.loads((root/'state.json').read_text())['capability_runs'][rid];assert r['capability']=='P1-RKE2'
def read_ref(ref):
 p=pathlib.Path(ref['path']);p=p if p.is_absolute() else root/p
 p=p.resolve();assert p.is_relative_to(root)
 data=p.read_bytes();assert hashlib.sha256(data).hexdigest()==ref['sha256']
 return data
safe_fields=['result','capability','source_sha256','checks','hosts','rke2_version','artifacts','limitations','notes','tests','assertions','failures','errors','skips']
for test in r['verified_tests']:
 data=read_ref({'path':test['stdout'],'sha256':test['sha256']})
 try:
  report=json.loads(data);safe={k:report[k] for k in safe_fields if k in report}
 except ValueError:
  safe={'test_count_lines':[x for x in data.decode(errors='replace').splitlines() if re.search(r'(tests|assertions|failures|errors|passed|PASS|^OK$)',x,re.I) and len(x)<240][-12:]}
 print('VERIFIED_TEST_RECEIPT='+json.dumps({'id':test['id'],'kind':test['kind'],'sha256':test['sha256'],'hash_verified':True,'report':safe}))
review=json.loads(read_ref(r['final_review']));print('FINAL_REVIEW='+json.dumps({k:review.get(k) for k in ['decision','subject_sha256','rationale']}))
package=json.loads(read_ref(r['package']));binding=package['binding']
print('CENTRAL_PIN='+binding['central_commit'])
print('PUBLICATION_BASES='+json.dumps([{k:x[k] for k in ['repository','base_branch','target_commit']} for x in binding['repositories']]))
for ref in r['records']:
 record=json.loads(read_ref(ref))
 if record.get('label')!='github':continue
 print('GITHUB_PROCESS='+json.dumps({k:record.get('process',{}).get(k) for k in ['exit_code','started_at','finished_at','timed_out']}))
 for f in record.get('files',[]):
  data=read_ref(f)
  if not f['path'].endswith('.stderr'):continue
  text=data.decode(errors='replace')
  text=re.sub(r'(?i)(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)','[REDACTED]',text)
  text=re.sub(r'(?i)(authorization\s*[:=]\s*|token\s*[:=]\s*|password\s*[:=]\s*)\S+',r'\1[REDACTED]',text)
  print('PUBLICATION_ERROR='+text[-2500:])
gh=binding['tools']['gh'];assert hashlib.sha256(pathlib.Path(gh['path']).read_bytes()).hexdigest()==gh['sha256']
print('BOUND_GH='+json.dumps({'path':gh['path'],'sha256':gh['sha256']}))
print('GH_VERSION='+subprocess.check_output([gh['path'],'--version'],text=True,timeout=15).splitlines()[0])
central=pathlib.Path('/tmp/layersentry-execution-control-20260910')
print('CENTRAL_CHECKOUT='+subprocess.check_output(['git','-C',str(central),'rev-parse','HEAD'],text=True,timeout=15).strip())
print('READ_ONLY_RECEIPT_RECONCILIATION=PASS; NO_PUBLICATION_RETRY=true; SERVER_MUTATIONS=false')
PY
