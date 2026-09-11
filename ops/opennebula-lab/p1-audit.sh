#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
printf 'P1_AUDIT_UTC=%s\n' "$(date -u +%FT%TZ)"
python3 -u - <<'PY'
import hashlib,json,pathlib,subprocess
root=pathlib.Path('/home/opc/.local/state/layersentry-runner')
rid='d5db2181-14e4-4ab0-8464-493b643130b9'
s=json.loads((root/'state.json').read_text()); r=s['capability_runs'][rid]
assert r['capability']=='P1-RKE2'
print('SUPERVISOR_STATE='+json.dumps({'id':rid,'state':r['state'],'reason':r.get('reason'),'keys':sorted(r)}))
expected={'adaptgurus/one','adaptgurus/one-apps','adaptgurus/layersentry-platform'}
assert set(r['selected'])==expected
for name,rec in r['selected'].items():
 p=pathlib.Path(rec['worktree']);assert p==root/'capabilities'/rid/'source'/name.split('/')[1]
 def git(*args): return subprocess.check_output(['git','-C',str(p),*args],text=True,timeout=20).strip()
 print('LOCAL_SOURCE='+json.dumps({'repository':name,'worktree':str(p),'head':git('rev-parse','HEAD'),'branch':git('branch','--show-current'),'dirty_files':git('status','--porcelain'),'selected_keys':sorted(rec)}))
for name,p in r.get('publication',{}).items():
 print('PUBLICATION='+json.dumps({'repository':name,**{k:p.get(k) for k in ['state','branch','commit','url']}}))
for key in ['verification','final_review','reviews','phase','evidence']:
 value=r.get(key)
 if isinstance(value,dict):
  print('RECORD_METADATA='+json.dumps({'type':key,'keys':sorted(value),**{k:value.get(k) for k in ['path','sha256','status','state','decision'] if k in value}}))
 elif isinstance(value,list):
  for v in value:
   if isinstance(v,dict): print('RECORD_METADATA='+json.dumps({'type':key,**{k:v.get(k) for k in ['id','name','kind','path','sha256','status','state','exit_code','returncode','coverage','test'] if k in v}}))
 if key=='final_review' and isinstance(value,dict) and value.get('path'):
  p=(root/value['path']).resolve();assert p.is_relative_to(root)
  review=json.loads(p.read_text());print('FINAL_REVIEW='+json.dumps({k:review.get(k) for k in ['decision','summary','blockers']}))
b=json.loads((root/'p1-capability'/'approved-p1-binding-v2.json').read_text())
expected_hash={i['path']:i['sha256'] for t in b['verification'] for i in t.get('inputs',[])}
for path in ['/tmp/ls-poc-kubectl','/tmp/ls-poc-kubectl-1.36.4','/tmp/ls-poc-p1-access']:
 assert path in expected_hash and hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()==expected_hash[path], 'BOUND_HELPER_CHANGED'
print('BOUND_HELPER_HASHES=PASS')
for t in b['verification']:
 print('BOUND_VERIFIER='+json.dumps({k:t.get(k) for k in ['id','name','kind','coverage','covers'] if k in t}))
PY
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 rocky-01 'test "$(hostname -s)" = rocky-01 && test "$(id -un)" = oneadmin && oned -v | head -1; onehost list; onedatastore list; onevm list; onehost show rocky-02 | grep -A5 "LOCAL SYSTEM"; onehost show rocky-03 | grep -A5 "LOCAL SYSTEM"'
python3 -u - <<'PY'
import json,subprocess
k='/tmp/ls-poc-kubectl'
def run(*args):
 r=subprocess.run([k,'--request-timeout=15s',*args],capture_output=True,text=True,timeout=25)
 assert r.returncode==0,'KUBERNETES_READ_FAILED:'+str(args)+':'+r.stderr[:300]
 return r.stdout
c=json.loads(run('config','view','--minify','-o','json'))
assert [x['cluster']['server'] for x in c.get('clusters',[])]==['https://10.10.10.117:6443']
assert not any('exec' in x.get('user',{}) for x in c.get('users',[]))
print('BOUND_CLUSTER_ENDPOINT=https://10.10.10.117:6443')
assert run('get','--raw=/readyz').strip()=='ok';print('LIVE_API_READYZ=PASS')
nodes=json.loads(run('get','nodes','-o','json'))['items'];providers=set()
for n in nodes:
 s=n['status']; conds={c['type']:c['status'] for c in s.get('conditions',[])};providers.add(n['spec'].get('providerID'))
 print('NODE='+json.dumps({'name':n['metadata']['name'],'providerID':n['spec'].get('providerID'),'version':s['nodeInfo']['kubeletVersion'],'conditions':conds,'capacity':s.get('capacity'),'allocatable':s.get('allocatable'),'addresses':s.get('addresses'),'unschedulable':n['spec'].get('unschedulable',False)}))
 assert conds.get('Ready')=='True','NODE_NOT_READY'
assert providers=={'one://36','one://38','one://39'},'NODE_SET_CHANGED_RECONCILE_BEFORE_MUTATION'
for p in json.loads(run('get','pods','-A','-o','json'))['items']:
 print('POD='+json.dumps({'namespace':p['metadata']['namespace'],'name':p['metadata']['name'],'node':p['spec'].get('nodeName'),'phase':p['status'].get('phase'),'containers':[{'name':c['name'],'ready':c.get('ready'),'restarts':c.get('restartCount'),'image':c.get('image'),'imageID':c.get('imageID')} for c in p['status'].get('containerStatuses',[])]}))
print('THREE_NODE_READINESS=PASS')
PY
for role in cp worker1 worker2; do
 echo "GUEST_ROLE=$role"
 timeout 40s /tmp/ls-poc-p1-access "$role" 'bash --noprofile --norc -s' <<'GUEST'
set -euo pipefail
hostname
id -un
rke2 --version | head -1
free -m
awk '/^nameserver / { print "GUEST_NAMESERVER=" $2 }' /etc/resolv.conf
ip -4 route
ping -c 2 -W 2 10.10.10.1 >/dev/null && echo GATEWAY_PING=PASS
code=$(curl -fsS --max-time 10 --output /dev/null --write-out '%{http_code}' https://example.com)
[[ $code == 200 ]] && echo HTTPS_INTERNET=PASS
python3 - <<'DNS'
import socket,struct,json,secrets
for server in ['8.8.8.8','1.1.1.1']:
 ident=secrets.randbelow(65536);q=struct.pack('!HHHHHH',ident,0x0100,1,0,0,0)+b'\x07example\x03com\x00'+struct.pack('!HH',1,1)
 with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
  s.settimeout(4);s.sendto(q,(server,53));data,addr=s.recvfrom(4096)
 rid,flags,qd,an,ns,ar=struct.unpack('!HHHHHH',data[:12]);ok=rid==ident and addr[0]==server and (flags&15)==0 and an>0
 print('DIRECT_DNS='+json.dumps({'server':server,'answer_count':an,'rcode':flags&15,'passed':ok}))
 assert ok,'DNS_TEST_FAILED'
DNS
GUEST
done
echo 'READ_ONLY_AUDIT=PASS; NEW_WORKERS_CREATED=0; PRIVATE_KEYS_EXPORTED=false; SUPERVISOR_STATE_MODIFIED=false'
