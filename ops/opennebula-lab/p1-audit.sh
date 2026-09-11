#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
printf 'P1_FOLLOWUP_AUDIT_UTC=%s\n' "$(date -u +%FT%TZ)"
python3 -u - <<'PY'
import hashlib,json,pathlib,subprocess
root=pathlib.Path('/home/opc/.local/state/layersentry-runner');rid='d5db2181-14e4-4ab0-8464-493b643130b9'
r=json.loads((root/'state.json').read_text())['capability_runs'][rid];assert r['capability']=='P1-RKE2'
print('SUPERVISOR_STATE='+json.dumps({'id':rid,'state':r['state'],'reason':r.get('reason')}))
for name,rec in r['selected'].items():
 p=pathlib.Path(rec['worktree']);assert p==root/'capabilities'/rid/'source'/name.split('/')[1]
 def git(*args):return subprocess.check_output(['git','-C',str(p),*args],text=True,timeout=20).strip()
 print('SOURCE_BINDING='+json.dumps({'repository':name,'base':rec['base'],'head':git('rev-parse','HEAD'),'dirty_files':git('status','--porcelain')}))
for key in ['verified_tests','verified_snapshot','records','package','internal_evidence']:
 v=r.get(key);print('EVIDENCE_TYPE='+json.dumps({'field':key,'type':type(v).__name__,'keys':list(v)[:30] if isinstance(v,dict) else [],'count':len(v) if isinstance(v,(dict,list)) else None}))
 values=list(v.items()) if isinstance(v,dict) else list(enumerate(v)) if isinstance(v,list) else []
 for name,item in values[-12:]:
  if isinstance(item,dict):
   safe={k:item[k] for k in ['id','kind','result','state','status','exit_code','returncode','return_code','checks','source_sha256','sha256','path','stdout_path','stderr_path'] if k in item}
   safe['field_keys']=sorted(item);print('EVIDENCE_ENTRY='+json.dumps({'field':key,'entry':str(name),'metadata':safe}))
b=json.loads((root/'p1-capability'/'approved-p1-binding-v2.json').read_text());expected={i['path']:i['sha256'] for t in b['verification'] for i in t.get('inputs',[])}
for path in ['/tmp/ls-poc-kubectl','/tmp/ls-poc-kubectl-1.36.4','/tmp/ls-poc-p1-access']:
 assert path in expected and hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()==expected[path]
print('BOUND_HELPER_HASHES=PASS')
k='/tmp/ls-poc-kubectl'
c=json.loads(subprocess.check_output([k,'config','view','--minify','-o','json'],text=True,timeout=20));assert [x['cluster']['server'] for x in c['clusters']]==['https://10.10.10.117:6443']
assert not any('exec' in x.get('user',{}) for x in c.get('users',[]))
assert subprocess.check_output([k,'--request-timeout=15s','get','--raw=/readyz'],text=True,timeout=25).strip()=='ok';print('LIVE_API_READYZ=PASS')
for p in json.loads(subprocess.check_output([k,'--request-timeout=15s','get','pods','-n','capone-system','-o','json'],text=True,timeout=25))['items']:
 for c in p['status'].get('containerStatuses',[]):
  last=c.get('lastState',{}).get('terminated',{});print('CAPONE_HEALTH='+json.dumps({'name':p['metadata']['name'],'ready':c.get('ready'),'restart_count':c.get('restartCount'),'last_exit_reason':last.get('reason'),'last_exit_code':last.get('exitCode'),'last_exit_finished_at':last.get('finishedAt')}))
PY
for role in cp worker1 worker2; do
 echo "GUEST_ROLE=$role"
 timeout 40s /tmp/ls-poc-p1-access "$role" 'bash --noprofile --norc -s' <<'GUEST'
set -euo pipefail
hostname
rke2 --version | sed -n '1p'
free -m
awk '/^nameserver / { print "GUEST_NAMESERVER=" $2 }' /etc/resolv.conf
ip -4 route show default
ping -c 2 -W 2 10.10.10.1 >/dev/null
echo GATEWAY_PING=PASS
code=$(curl -fsS --max-time 10 --output /dev/null --write-out '%{http_code}' https://example.com)
[[ $code == 200 ]]
echo HTTPS_INTERNET=PASS
python3 - <<'DNS'
import socket,struct,json,secrets
for server in ['8.8.8.8','1.1.1.1']:
 ident=secrets.randbelow(65536);q=struct.pack('!HHHHHH',ident,0x0100,1,0,0,0)+b'\x07example\x03com\x00'+struct.pack('!HH',1,1)
 with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
  s.settimeout(4);s.sendto(q,(server,53));data,addr=s.recvfrom(4096)
 rid,flags,qd,an,ns,ar=struct.unpack('!HHHHHH',data[:12]);ok=rid==ident and addr[0]==server and (flags&15)==0 and an>0
 print('DIRECT_DNS='+json.dumps({'server':server,'answer_count':an,'rcode':flags&15,'passed':ok}));assert ok
DNS
GUEST
done
echo 'THREE_GUEST_NETWORK_AUDIT=PASS; NEW_WORKERS_CREATED=0; PRIVATE_KEYS_EXPORTED=false; SUPERVISOR_STATE_MODIFIED=false'
