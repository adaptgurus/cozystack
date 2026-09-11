#!/usr/bin/env bash
set -euo pipefail
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
python3 -u - <<'PY'
import hashlib,json,pathlib,subprocess
base=pathlib.Path('/home/opc/.local/state/layersentry-runner/p1-capability')
b=json.loads((base/'approved-p1-binding-v2.json').read_text());expected={i['path']:i['sha256'] for t in b['verification'] for i in t.get('inputs',[])}
for name in ['/tmp/ls-poc-kubectl','/tmp/ls-poc-kubectl-1.36.4','/tmp/ls-poc-p1-access']:
 assert name in expected and hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()==expected[name], 'BOUND_HELPER_CHANGED:'+name
print('ORIGINAL_BOUND_HELPER_HASHES=PASS')
r=subprocess.run(['/tmp/ls-poc-kubectl','config','view','--minify','-o','json'],capture_output=True,text=True,timeout=15)
assert r.returncode==0,'KUBECONFIG_METADATA_FAILED'
c=json.loads(r.stdout);servers=[x['cluster']['server'] for x in c.get('clusters',[])]
assert servers==['https://10.10.10.117:6443'], 'UNEXPECTED_CLUSTER_TARGET'
assert not any('exec' in x.get('user',{}) for x in c.get('users',[])), 'UNEXPECTED_EXEC_AUTH'
print('BOUND_CLUSTER_ENDPOINT=https://10.10.10.117:6443')
checks=[['get','--raw=/readyz'],['get','nodes','-o','json'],['get','pods','-A','-o','json']]
for command in checks:
 r=subprocess.run(['/tmp/ls-poc-kubectl','--request-timeout=15s',*command],capture_output=True,text=True,timeout=25)
 assert r.returncode==0,'KUBERNETES_READ_FAILED:'+str(command)+':'+r.stderr[:300]
 if command[1]=='--raw=/readyz': print('LIVE_API_READYZ='+r.stdout.strip());assert r.stdout.strip()=='ok'
 elif command[1]=='nodes':
  nodes=json.loads(r.stdout)['items'];assert len(nodes)==3,'UNEXPECTED_NODE_COUNT'
  providers=set()
  for n in nodes:
   s=n['status'];conds={c['type']:c['status'] for c in s.get('conditions',[])};providers.add(n['spec'].get('providerID'))
   print('LIVE_NODE='+json.dumps({'name':n['metadata']['name'],'providerID':n['spec'].get('providerID'),'version':s['nodeInfo']['kubeletVersion'],'conditions':conds,'allocatable':s.get('allocatable'),'addresses':s.get('addresses'),'unschedulable':n['spec'].get('unschedulable',False)}))
   assert conds.get('Ready')=='True','NODE_NOT_READY'
  assert providers=={'one://36','one://38','one://39'},'UNEXPECTED_PROVIDER_SET'
 else:
  for p in json.loads(r.stdout)['items']:
   print('LIVE_POD='+json.dumps({'namespace':p['metadata']['namespace'],'name':p['metadata']['name'],'node':p['spec'].get('nodeName'),'phase':p['status'].get('phase'),'containers':[{'name':c['name'],'ready':c.get('ready'),'restarts':c.get('restartCount')} for c in p['status'].get('containerStatuses',[])]}))
print('LIVE_THREE_NODE_READINESS=PASS; PRIVATE_KUBECONFIG_EXPORTED=false')
PY
for role in cp worker1 worker2; do
 echo "READ_ONLY_GUEST_ROLE=$role"
 timeout 30s /tmp/ls-poc-p1-access "$role" 'bash --noprofile --norc -s' <<'GUEST'
set -u
hostname
id -un
command -v rke2
rke2 --version 2>/dev/null | head -1
systemctl is-active rke2-server rke2-agent || true
free -m
ip -4 route
ping -c 2 -W 2 10.10.10.1 || true
curl -sS --max-time 8 --output /dev/null --write-out 'HTTPS_INTERNET_STATUS=%{http_code}\n' https://example.com || true
python3 - <<'DNS'
import socket,struct,json,secrets
for server in ['8.8.8.8','1.1.1.1']:
 ident=secrets.randbelow(65536);query=struct.pack('!HHHHHH',ident,0x0100,1,0,0,0)+b'\x07example\x03com\x00'+struct.pack('!HH',1,1)
 try:
  with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
   s.settimeout(3);s.sendto(query,(server,53));data,addr=s.recvfrom(4096)
  rid,flags,qd,an,ns,ar=struct.unpack('!HHHHHH',data[:12]);ok=rid==ident and (flags&15)==0 and an>0
  print('DIRECT_DNS='+json.dumps({'server':server,'answer_count':an,'rcode':flags&15,'passed':ok}))
 except Exception as e:print('DIRECT_DNS='+json.dumps({'server':server,'passed':False,'error':type(e).__name__}))
DNS
GUEST
done
echo 'CURRENT_P1_READ_ONLY_CHECKS_COMPLETE; SERVER_MUTATIONS=false; NEW_WORKERS_CREATED=0'
