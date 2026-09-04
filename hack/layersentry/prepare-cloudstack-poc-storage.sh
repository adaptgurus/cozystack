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
SYS_TMPLT_HTTPS='https://download.cloudstack.org/systemvm/4.22/systemvmtemplate-4.22.0-x86_64-kvm.qcow2.bz2'
SYS_TMPLT_HTTP='http://download.cloudstack.org/systemvm/4.22/systemvmtemplate-4.22.0-x86_64-kvm.qcow2.bz2'
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/layersentry-storage-prep-${STAMP}.log"
BACKUP="/var/backups/layersentry/storage-${STAMP}"
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
curl -fsS --max-time 15 http://127.0.0.1:8080/client/config.json | grep -q Layersentry || die 'Layersentry runtime config is not healthy.'
for pkg in cloudstack-management cloudstack-ui cloudstack-agent; do
  v="$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$pkg" 2>/dev/null || true)"
  [[ "$v" == '4.22.1.1-1' || "$v" == '4.22.1.1-1.'* ]] || die "$pkg is not exact 4.22.1.1-1: ${v:-missing}"
done

log '==> stopping unregistered CloudStack agent restart loop'
systemctl disable --now cloudstack-agent >/dev/null 2>&1 || true
systemctl reset-failed cloudstack-agent >/dev/null 2>&1 || true
sleep 2
agent_state="$(systemctl is-active cloudstack-agent 2>/dev/null || true)"
agent_enabled="$(systemctl is-enabled cloudstack-agent 2>/dev/null || true)"
[[ "$agent_state" != active && "$agent_state" != activating ]] || die 'cloudstack-agent did not stop.'
log "AGENT_STATE=$agent_state"
log "AGENT_ENABLED=$agent_enabled"

log '==> installing/validating NFS runtime'
dnf -y install nfs-utils rpcbind firewalld curl wget >/dev/null
install -d -m 0700 "$BACKUP"
if [[ -e "$EXPORTS_FILE" ]]; then cp -a "$EXPORTS_FILE" "$BACKUP/exports.before"; fi
firewall-cmd --permanent --zone=public --list-rich-rules >"$BACKUP/firewall-rich-rules.before" 2>/dev/null || true

install -d -m 0777 "$PRIMARY" "$SECONDARY"
cat >"$EXPORTS_FILE" <<EOF
$PRIMARY $EXPECTED_CIDR(rw,async,no_root_squash,no_subtree_check)
$SECONDARY $EXPECTED_CIDR(rw,async,no_root_squash,no_subtree_check)
EOF
chmod 0644 "$EXPORTS_FILE"

systemctl enable --now rpcbind >/dev/null
systemctl enable --now nfs-server >/dev/null
exportfs -rav | tee -a "$LOG"
exportfs -v | tee -a "$LOG"
exportfs -v | grep -Fq "$PRIMARY" || die 'Primary NFS export missing.'
exportfs -v | grep -Fq "$SECONDARY" || die 'Secondary NFS export missing.'

log '==> applying source-restricted NFS firewall rules'
systemctl enable --now firewalld >/dev/null
for svc in nfs mountd rpc-bind; do
  rule="rule family=\"ipv4\" source address=\"$EXPECTED_CIDR\" service name=\"$svc\" accept"
  firewall-cmd --permanent --zone=public --query-rich-rule="$rule" >/dev/null 2>&1 || \
    firewall-cmd --permanent --zone=public --add-rich-rule="$rule" >/dev/null
  firewall-cmd --permanent --zone=public --query-rich-rule="$rule" >/dev/null || die "Failed to persist source-restricted $svc rule."
done
firewall-cmd --reload >/dev/null
firewall-cmd --zone=public --list-rich-rules | tee -a "$LOG"

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
printf 'Layersentry NFS validation %s\n' "$STAMP" >"$probe"
sync
grep -Fq 'Layersentry NFS validation' "$probe" || die 'NFS write/read probe failed.'
rm -f "$probe"
umount "$TEST_MOUNT"
log "NFS_MOUNT_VALIDATION=PASS vers=$nfs_version"

log '==> seeding KVM System VM template if needed'
[[ -x "$SYS_TMPLT" ]] || die "System VM template helper missing: $SYS_TMPLT"
existing_props="$(find "$SECONDARY/template/tmpl" -type f -name template.properties -print -quit 2>/dev/null || true)"
if [[ -n "$existing_props" ]]; then
  log "INFO: Existing System VM template metadata found at $existing_props; preserving it."
else
  template_url=''
  if curl -fsSI --retry 3 --connect-timeout 15 --max-time 45 "$SYS_TMPLT_HTTPS" >/dev/null 2>&1; then
    template_url="$SYS_TMPLT_HTTPS"
  elif curl -fsSI --retry 3 --connect-timeout 15 --max-time 45 "$SYS_TMPLT_HTTP" >/dev/null 2>&1; then
    template_url="$SYS_TMPLT_HTTP"
  else
    die 'CloudStack 4.22 KVM System VM template URL is unreachable over HTTPS and HTTP.'
  fi
  log "SYSTEM_VM_TEMPLATE_URL=$template_url"
  "$SYS_TMPLT" -m "$SECONDARY" -u "$template_url" -h kvm 2>&1 | tee -a "$LOG"
fi

props="$(find "$SECONDARY/template/tmpl" -type f -name template.properties -print -quit 2>/dev/null || true)"
[[ -n "$props" && -s "$props" ]] || die 'System VM template.properties was not produced.'
qcow="$(find "$SECONDARY/template/tmpl" -type f -name '*.qcow2' -size +100M -print -quit 2>/dev/null || true)"
[[ -n "$qcow" && -s "$qcow" ]] || die 'System VM qcow2 image was not produced.'
log "SYSTEM_VM_TEMPLATE_PROPERTIES=$props"
log "SYSTEM_VM_TEMPLATE_IMAGE=$qcow"
ls -lh "$props" "$qcow" | tee -a "$LOG"

log '==> final storage validation'
systemctl is-active --quiet nfs-server || die 'nfs-server is not active.'
systemctl is-active --quiet rpcbind || die 'rpcbind is not active.'
systemctl is-active --quiet cloudstack-management || die 'cloudstack-management became inactive.'
agent_state="$(systemctl is-active cloudstack-agent 2>/dev/null || true)"
[[ "$agent_state" != active && "$agent_state" != activating ]] || die 'cloudstack-agent unexpectedly restarted.'

printf 'PRIMARY_NFS=nfs://%s%s\n' "$EXPECTED_IP" "$PRIMARY" | tee -a "$LOG"
printf 'SECONDARY_NFS=nfs://%s%s\n' "$EXPECTED_IP" "$SECONDARY" | tee -a "$LOG"
printf 'BACKUP=%s\n' "$BACKUP" | tee -a "$LOG"
printf 'AGENT_FINAL_STATE=%s\n' "$agent_state" | tee -a "$LOG"
log '[100%] Layersentry local NFS storage preparation completed'
