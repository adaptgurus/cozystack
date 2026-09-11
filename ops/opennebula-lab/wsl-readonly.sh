#!/usr/bin/env bash
set -euo pipefail
# The caller supplies a temporary COPY OF PUBLIC HOST KEYS, not an identity.
known=${1:?Provide the pinned public known_hosts path}
key="$HOME/.ssh/opennebula-admin"
[[ -r "$known" && -r "$key" ]] || { echo 'EXISTING_SSH_MATERIAL_UNAVAILABLE'; exit 20; }
printf 'WSL_HOST=%s WSL_USER=%s\n' "$(hostname)" "$(id -un)"
echo 'EXISTING_IDENTITY=opennebula-admin; PRIVATE_KEY_PRINTED=false'
opts=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$key" -o ConnectTimeout=8 -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes -o LogLevel=ERROR -o "UserKnownHostsFile=$known")
ssh -n "${opts[@]}" oneadmin@10.10.10.21 'hostname; whoami'
echo 'ROCKY01_ONEADMIN_SSH_AUTHENTICATED=true'
ssh "${opts[@]}" oneadmin@10.10.10.21 'bash --noprofile --norc -s' <<'ONECHECK'
set -euo pipefail
[[ $(id -un) == oneadmin && $(hostname -s) == rocky-01 ]] || exit 21
echo OPENNEBULA_READ_ONLY_BEGIN
date -u +%FT%TZ
hostname
whoami
oned -v
echo '=== Frontend services ==='
systemctl is-active opennebula opennebula-fireedge opennebula-scheduler opennebula-flow opennebula-gate || true
for command in onehost onedatastore onevnet oneimage onetemplate onevm; do
  echo "=== $command list ==="
  "$command" list
done
echo '=== Marketplace application 54 ==='
onemarketapp show 54 | head -70 || true
echo '=== POC-LAN ==='
onevnet show 0
for host in rocky-02 rocky-03; do
  echo "=== $host local system datastore ==="
  onehost show "$host" | grep -A8 -i 'LOCAL SYSTEM' || true
  ssh -n -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 "$host" 'hostname; virsh list --all; ip -br addr show br0; df -hT /var/lib/one/datastores'
done
echo 'OPENNEBULA_READ_ONLY_COMPLETE; SERVER_MUTATIONS=false'
ONECHECK
