#!/usr/bin/env bash
set -euo pipefail
known=${1:?Provide the pinned public known_hosts path}
key="$HOME/.ssh/opennebula-admin"
[[ -r "$known" && -r "$key" ]] || { echo EXISTING_SSH_MATERIAL_UNAVAILABLE; exit 20; }
printf 'WSL_HOST=%s WSL_USER=%s\n' "$(hostname)" "$(id -un)"
echo 'EXISTING_IDENTITY=opennebula-admin; PRIVATE_KEY_PRINTED=false'
# Exercise the existing aliases with their original known_hosts; never change trust.
for host in rocky-01 rocky-02 rocky-03; do
  if result=$(ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" 'hostname -s; whoami' 2>&1); then
    printf 'DIRECT_WSL_ALIAS=%s AUTHENTICATED=true OUTPUT=%s\n' "$host" "${result//$'\n'/,}"
  else
    printf 'DIRECT_WSL_ALIAS=%s AUTHENTICATED=false ERROR=%s\n' "$host" "${result//$'\n'/,}"
  fi
done
opts=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes -o LogLevel=ERROR -o "UserKnownHostsFile=$known")
ssh "${opts[@]}" oneadmin@10.10.10.21 'bash --noprofile --norc -s' <<'ONECHECK'
set -euo pipefail
[[ $(id -un) == oneadmin && $(hostname -s) == rocky-01 ]] || exit 21
echo 'ROCKY01_ONEADMIN_SSH_AUTHENTICATED=true; OPENNEBULA_READ_ONLY_BEGIN'
date -u +%FT%TZ
oned -v | head -1
onehost list
echo '=== Actual frontend units ==='
systemctl list-units --all --type=service --no-pager --plain | grep -i opennebula || true
systemctl show opennebula-scheduler.service -p LoadState -p ActiveState -p UnitFileState -p FragmentPath
python3 - <<'PY'
import json
import subprocess
import xml.etree.ElementTree as ET

def xml(*args):
    return ET.fromstring(subprocess.check_output([*args, '--xml'], text=True, timeout=25))

def pick(node, names):
    return {name: node.findtext(name) for name in names if node.findtext(name) is not None}

image = xml('oneimage', 'show', '0')
print('ROCKY_IMAGE=' + json.dumps(pick(image, ['ID','NAME','STATE','DATASTORE_ID','RUNNING_VMS','SIZE','SOURCE','TEMPLATE/FROM_APP','TEMPLATE/IMPORT_ID','TEMPLATE/ORIGIN_ID','TEMPLATE/FORMAT']), sort_keys=True))
template = xml('onetemplate', 'show', '0')
t = template.find('TEMPLATE')
record = pick(template, ['ID','NAME'])
if t is not None:
    record['resources'] = pick(t, ['CPU','VCPU','MEMORY'])
    record['context_network'] = t.findtext('CONTEXT/NETWORK')
    record['context_ssh_public_key_configured'] = bool(t.findtext('CONTEXT/SSH_PUBLIC_KEY'))
    record['nics'] = [pick(n, ['NETWORK_ID','NETWORK','MODEL']) for n in t.findall('NIC')]
    record['disks'] = [pick(d, ['IMAGE_ID','SIZE','TARGET','DRIVER']) for d in t.findall('DISK')]
print('ROCKY_TEMPLATE=' + json.dumps(record, sort_keys=True))
for vm in xml('onevm', 'list').findall('VM'):
    record = pick(vm, ['ID','NAME','STATE','LCM_STATE','DEPLOY_ID'])
    history = vm.findall('HISTORY_RECORDS/HISTORY')
    if history:
        record['last_placement'] = pick(history[-1], ['HID','HOSTNAME','DS_ID','VM_MAD','TM_MAD'])
    record['nics'] = [pick(n, ['NETWORK_ID','NETWORK','IP','MAC','NIC_ID']) for n in vm.findall('TEMPLATE/NIC')]
    record['disks'] = [pick(d, ['DISK_ID','IMAGE_ID','DATASTORE_ID','SIZE','TYPE','TARGET']) for d in vm.findall('TEMPLATE/DISK')]
    print('VM_METADATA=' + json.dumps(record, sort_keys=True))
PY
for host in rocky-02 rocky-03; do
  echo "=== $host local datastore ==="
  onehost show "$host" | grep -A5 -i 'LOCAL SYSTEM' || true
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" 'bash --noprofile --norc -s' <<'COMPUTE'
set -euo pipefail
hostname
virsh -c qemu:///system list --all
for domain in $(virsh -c qemu:///system list --all --name | grep '^one-' || true); do
  echo "DOMAIN_DISK_PLACEMENT=$domain"
  virsh -c qemu:///system domblklist "$domain" --details
done
ip -br addr show br0
df -hT /var/lib/one/datastores
COMPUTE
done
echo 'OPENNEBULA_READ_ONLY_COMPLETE; SERVER_MUTATIONS=false; GUEST_NETWORK_TESTS_PERFORMED=false; KUBERNETES_HEALTH_VERIFIED=false'
ONECHECK
