#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
python3 -u - <<'PY'
import pathlib,json,re,subprocess,hashlib
s=pathlib.Path('/home/opc/.local/state/layersentry-runner');rid='d5db2181-14e4-4ab0-8464-493b643130b9';a=s/'artifacts'/rid

def redact(text):
 text=re.sub(r'-----BEGIN [^-]+-----.*?-----END [^-]+-----','[REDACTED_KEY_MATERIAL]',text,flags=re.S)
 text=re.sub(r'(https?://)[^/@\s]+@',r'\1[REDACTED]@',text)
 text=re.sub(r'(?i)((?:password|token|secret|authorization)\s*[:=]\s*)["\']?[^\s,"\']+',r'\1[REDACTED]',text)
 return text
for f in ['0009-verify-rke2-build.record.json','0010-verify-rke2-unit.record.json','0011-verify-rke2-live.record.json','0014-github.record.json']:
 x=json.loads((a/f).read_text());print('PROCESS_RECEIPT='+redact(json.dumps({'file':f,'process':x.get('process'),'files':x.get('files')})))
for f in ['0009-verify-rke2-build.stdout','0010-verify-rke2-unit.stdout','0011-verify-rke2-live.stdout','0014-github.stderr']:
 text=(a/f).read_text();print('HISTORICAL_RECEIPT_OUTPUT='+f+'\n'+redact(text[-15000:]))
root=pathlib.Path('/tmp/layersentry-execution-control-20260910')
for args in [['rev-parse','HEAD'],['status','--short'],['remote','get-url','origin']]:
 p=subprocess.run(['git','-C',str(root),*args],capture_output=True,text=True,timeout=10)
 print('CENTRAL_CHECKOUT='+redact(json.dumps({'query':args,'exit':p.returncode,'output':p.stdout.strip()})))
for f in ['/tmp/ls-poc-kubectl','/tmp/ls-poc-p1-access','/home/opc/.local/state/layersentry-runner/p1-capability/verify_live.py']:
 p=pathlib.Path(f)
 if not p.is_file():print('HELPER_MISSING='+f);continue
 data=p.read_bytes();print('HELPER_METADATA='+json.dumps({'path':f,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}))
 if data.startswith(b'#!') or f.endswith('.py'):
  lines=data.decode('utf-8','replace').splitlines()
  if 'verify_live' in f:
   relevant=[(i+1,line) for i,line in enumerate(lines) if any(w in line.lower() for w in ['kubectl','kubeconfig','subprocess','def main','argumentparser','ls-poc','def kub','def run'])]
  else:relevant=list(enumerate(lines,1))[:90]
  print('HELPER_SELECTED_SOURCE='+f)
  for i,line in relevant[:90]:print(str(i)+': '+redact(line))
print('READ_ONLY_RECEIPT_INSPECTION_COMPLETE; SERVER_MUTATIONS=false')
PY
