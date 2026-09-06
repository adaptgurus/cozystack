#!/usr/bin/env bash
# Root-scheduled DC wrapper around the reviewed management UI deployment helper.
set -Eeuo pipefail
umask 077
[[ ${EUID:-$(id -u)} -eq 0 && $# -eq 2 ]] || exit 2
BUNDLE=$1
RUN_ID=$2
[[ "$RUN_ID" =~ ^[0-9]+-[0-9]+$ && "$BUNDLE" == "/run/layersentry-dr-ui-$RUN_ID" ]] || exit 2
HELPER="$BUNDLE/deploy-dr-cloudstack-ui.sh"
UI='dc58f76f67dac13aa886c8d45475944f31b0c039'
# Reuse the reviewed helper bytes without transforming its runtime/config logic.
[[ "$(sha256sum "$HELPER" | cut -d ' ' -f 1)" == 60fa2fe3142e6a8a9c01c3c33c2afab6187984294618d09eff86efeba0bb8f0d ]] || exit 2
command -v rsync >/dev/null # Prevent the helper's optional package installation.
python3 -I - <<'PY'
import json, os, pathlib, subprocess
assert os.geteuid() == 0
assert pathlib.Path('/sys/devices/virtual/dmi/id/product_uuid').read_text().strip().lower() == 'ccbcac90-c8e3-4091-90a0-7e2e8cf2f7e5'
links=json.loads(subprocess.check_output(['ip','-j','link','show','eth0'],timeout=10))
assert len(links)==1 and links[0]['address'].lower()=='00:15:5d:00:39:0a' and links[0]['master']=='cloudbr0'
addresses=json.loads(subprocess.check_output(['ip','-j','addr','show','cloudbr0'],timeout=10))
assert len(addresses)==1 and any(a.get('local')=='10.10.10.14' and a.get('prefixlen')==24 for a in addresses[0]['addr_info'])
PY
# Retain configuration bytes and metadata privately, including any native TLS setup.
python3 -I - "$BUNDLE" <<'PY'
import hashlib, json, os, pathlib, stat, sys
path=pathlib.Path('/etc/cloudstack/management/server.properties')
assert not any(p.is_symlink() for p in [path,*path.parents])
s=path.stat(); assert stat.S_ISREG(s.st_mode) and s.st_uid==0 and s.st_nlink==1 and not s.st_mode&0o022
content=path.read_bytes(); assert len(content)<=65536
receipt={'sha256':hashlib.sha256(content).hexdigest(),'uid':s.st_uid,'gid':s.st_gid,'mode':stat.S_IMODE(s.st_mode)}
root=pathlib.Path(sys.argv[1])
for name,value in [('dc-server.properties.before',content),('dc-server.properties.proof.json',json.dumps(receipt,sort_keys=True).encode())]:
 fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'wb') as f: f.write(value); f.flush(); os.fsync(f.fileno())
PY
set +e
bash "$HELPER" "$BUNDLE" "$UI" "$RUN_ID"
helper_exit=$?
set -e
python3 -I - "$BUNDLE" <<'PY'
import hashlib, json, pathlib, stat, sys
root=pathlib.Path(sys.argv[1]); path=pathlib.Path('/etc/cloudstack/management/server.properties')
assert not any(p.is_symlink() for p in [path,*path.parents])
s=path.stat(); content=path.read_bytes()
assert content==(root/'dc-server.properties.before').read_bytes()
assert {'sha256':hashlib.sha256(content).hexdigest(),'uid':s.st_uid,'gid':s.st_gid,'mode':stat.S_IMODE(s.st_mode)}==json.loads((root/'dc-server.properties.proof.json').read_text())
print('DC_SERVER_PROPERTIES_PRESERVATION=PASS')
PY
[[ $helper_exit -eq 0 ]] || exit "$helper_exit"
printf 'LAYERSENTRY_DC_UI_DEPLOYMENT=PASS\n'
