#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

EXPECTED_FQDN='layersentry.lab.example'
EXPECTED_IP='10.10.10.14'
EXPECTED_CIDR='10.10.10.0/24'
EXPECTED_GATEWAY='10.10.10.1'
BRIDGE='cloudbr0'
PRIMARY='/export/primary'
SECONDARY='/export/secondary'
EXPORTS_FILE='/etc/exports.d/layersentry-cloudstack.exports'
SYS_TMPLT='/usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt'
SYS_TMPLT_URL='https://download.cloudstack.org/systemvm/4.22/systemvmtemplate-4.22.0-x86_64-kvm.qcow2.bz2'
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/layersentry-storage-reconcile-${STAMP}.log"
BACKUP="/var/backups/layersentry/storage-reconcile-${STAMP}"
TEST_MOUNT='/mnt/layersentry-nfs-validation'

log(){ printf '%s\n' "$*" | tee -a "$LOG"; }
die(){ log "ERROR: $*" >&2; exit 1; }
cleanup(){ umount "$TEST_MOUNT" >/dev/null 2>&1 || true; rmdir "$TEST_MOUNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ -r /etc/os-release ]] || die '/etc/os-release missing.'
. /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID%%.*}" == 9 ]] || die "Rocky Linux 9 required; found ${PRETTY_NAME:-unknown}."
[[ "$(hostname -f)" == "$EXPECTED_FQDN" ]] || die "Unexpected FQDN: $(hostname -f)"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "$BRIDGE is missing."
ip -4 address show dev "$BRIDGE" | grep -Fq "inet ${EXPECTED_IP}/24" || die "$EXPECTED_IP/24 is not on $BRIDGE."
ip route show default | grep -Eq "default via ${EXPECTED_GATEWAY} dev ${BRIDGE}( |$)" || die 'Unexpected default route.'
[[ -c /dev/kvm ]] || die '/dev/kvm is missing.'
systemctl is-active --quiet cloudstack-management || die 'cloudstack-management is not active.'
systemctl is-active --quiet cloudstack-agent || die 'cloudstack-agent must already be active; refusing to alter a non-healthy registered host.'
for pkg in cloudstack-management cloudstack-agent; do
  v="$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$pkg" 2>/dev/null || true)"
  [[ "$v" == '4.22.1.1-1' || "$v" == '4.22.1.1-1.'* ]] || die "$pkg is not exact 4.22.1.1-1: ${v:-missing}"
done

log '==> preserving registered CloudStack agent'
AGENT_BEFORE="$(systemctl is-active cloudstack-agent)"
AGENT_ENABLED_BEFORE="$(systemctl is-enabled cloudstack-agent 2>/dev/null || true)"
log "AGENT_BEFORE=$AGENT_BEFORE"
log "AGENT_ENABLED_BEFORE=$AGENT_ENABLED_BEFORE"

missing=()
for pkg in nfs-utils rpcbind firewalld curl; do
  rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done
if ((${#missing[@]})); then
  log "==> installing missing NFS prerequisites: ${missing[*]}"
  dnf -y install "${missing[@]}" | tee -a "$LOG"
else
  log '==> NFS prerequisites already installed'
fi

install -d -m 0700 "$BACKUP"
install -d -m 0777 "$PRIMARY" "$SECONDARY"
if [[ -e "$EXPORTS_FILE" ]]; then
  cp -a "$EXPORTS_FILE" "$BACKUP/exports.before"
fi

expected_exports="$(cat <<EOT
$PRIMARY $EXPECTED_CIDR(rw,async,no_root_squash,no_subtree_check)
$SECONDARY $EXPECTED_CIDR(rw,async,no_root_squash,no_subtree_check)
EOT
)"
current_exports="$(cat "$EXPORTS_FILE" 2>/dev/null || true)"
if [[ "$current_exports" != "$expected_exports" ]]; then
  log '==> reconciling dedicated LayerSentry NFS exports file'
  tmp="$(mktemp /etc/exports.d/.layersentry-cloudstack.exports.XXXXXX)"
  printf '%s\n' "$expected_exports" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$EXPORTS_FILE"
else
  log '==> LayerSentry NFS exports already match requested state'
fi

systemctl enable --now rpcbind >/dev/null
systemctl enable --now nfs-server >/dev/null
exportfs -rav | tee -a "$LOG"
exportfs -v | tee -a "$LOG"
exportfs -v | grep -Fq "$PRIMARY" || die 'Primary NFS export missing.'
exportfs -v | grep -Fq "$SECONDARY" || die 'Secondary NFS export missing.'

log '==> reconciling source-restricted NFS firewall rules'
systemctl enable --now firewalld >/dev/null
for svc in nfs mountd rpc-bind; do
  rule="rule family=\"ipv4\" source address=\"$EXPECTED_CIDR\" service name=\"$svc\" accept"
  firewall-cmd --permanent --zone=public --query-rich-rule="$rule" >/dev/null 2>&1 || \
    firewall-cmd --permanent --zone=public --add-rich-rule="$rule" >/dev/null
  firewall-cmd --permanent --zone=public --query-rich-rule="$rule" >/dev/null || die "Failed to persist source-restricted $svc rule."
done
firewall-cmd --reload >/dev/null

log '==> validating primary NFS through the management address'
install -d -m 0755 "$TEST_MOUNT"
if mount -t nfs -o vers=4.2,timeo=5,retrans=2 "${EXPECTED_IP}:${PRIMARY}" "$TEST_MOUNT"; then
  nfs_version='4.2'
else
  umount "$TEST_MOUNT" >/dev/null 2>&1 || true
  mount -t nfs -o vers=3,timeo=5,retrans=2 "${EXPECTED_IP}:${PRIMARY}" "$TEST_MOUNT"
  nfs_version='3'
fi
probe="$TEST_MOUNT/.layersentry-nfs-probe-${STAMP}"
printf 'LayerSentry NFS validation %s\n' "$STAMP" >"$probe"
sync
grep -Fq 'LayerSentry NFS validation' "$probe" || die 'NFS write/read probe failed.'
rm -f "$probe"
umount "$TEST_MOUNT"
log "NFS_MOUNT_VALIDATION=PASS vers=$nfs_version"

log '==> ensuring KVM System VM template is seeded on secondary storage'
[[ -x "$SYS_TMPLT" ]] || die "System VM template helper missing: $SYS_TMPLT"
props="$(find "$SECONDARY/template/tmpl" -type f -name template.properties -print -quit 2>/dev/null || true)"
qcow="$(find "$SECONDARY/template/tmpl" -type f -name '*.qcow2' -size +100M -print -quit 2>/dev/null || true)"
if [[ -z "$props" || -z "$qcow" ]]; then
  curl -fsSI --retry 3 --connect-timeout 15 --max-time 45 "$SYS_TMPLT_URL" >/dev/null || die 'CloudStack 4.22 KVM System VM template URL is unreachable.'
  "$SYS_TMPLT" -m "$SECONDARY" -u "$SYS_TMPLT_URL" -h kvm -F 2>&1 | tee -a "$LOG"
  props="$(find "$SECONDARY/template/tmpl" -type f -name template.properties -print -quit 2>/dev/null || true)"
  qcow="$(find "$SECONDARY/template/tmpl" -type f -name '*.qcow2' -size +100M -print -quit 2>/dev/null || true)"
else
  log '==> existing KVM System VM template artifacts found; preserving them'
fi
[[ -n "$props" && -s "$props" ]] || die 'System VM template.properties missing after reconciliation.'
[[ -n "$qcow" && -s "$qcow" ]] || die 'System VM qcow2 missing after reconciliation.'

systemctl is-active --quiet cloudstack-management || die 'cloudstack-management became inactive.'
systemctl is-active --quiet cloudstack-agent || die 'cloudstack-agent became inactive.'
AGENT_AFTER="$(systemctl is-active cloudstack-agent)"
AGENT_ENABLED_AFTER="$(systemctl is-enabled cloudstack-agent 2>/dev/null || true)"
[[ "$AGENT_AFTER" == "$AGENT_BEFORE" ]] || die 'cloudstack-agent active state changed unexpectedly.'
[[ "$AGENT_ENABLED_AFTER" == "$AGENT_ENABLED_BEFORE" ]] || die 'cloudstack-agent enablement changed unexpectedly.'

printf 'PRIMARY_NFS=nfs://%s%s\n' "$EXPECTED_IP" "$PRIMARY" | tee -a "$LOG"
printf 'SECONDARY_NFS=nfs://%s%s\n' "$EXPECTED_IP" "$SECONDARY" | tee -a "$LOG"
printf 'SYSTEM_VM_TEMPLATE_PROPERTIES=%s\n' "$props" | tee -a "$LOG"
printf 'SYSTEM_VM_TEMPLATE_IMAGE=%s\n' "$qcow" | tee -a "$LOG"
printf 'BACKUP=%s\n' "$BACKUP" | tee -a "$LOG"
printf 'AGENT_AFTER=%s\n' "$AGENT_AFTER" | tee -a "$LOG"
log '[100%] LayerSentry non-disruptive NFS storage reconciliation completed'
