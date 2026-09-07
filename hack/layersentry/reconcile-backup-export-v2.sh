#!/usr/bin/env bash
set -euo pipefail

EXPECTED_FQDN='layersentry.lab.example'
EXPECTED_ADDRESS='10.10.10.14'
EXPECTED_EXPORT='/export/backup'
EXPECTED_CLIENT='10.10.10.0/24'
EXPORT_FILE='/etc/exports.d/layersentry-backup.exports'

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(hostname -f)" == "$EXPECTED_FQDN" ]] || fail 'FQDN mismatch'
[[ "$(systemctl is-active cloudstack-agent)" == 'active' ]] || fail 'cloudstack-agent is not active'
[[ "$(systemctl is-enabled cloudstack-agent)" == 'enabled' ]] || fail 'cloudstack-agent is not enabled'
[[ "$(systemctl is-active nfs-server)" == 'active' ]] || fail 'nfs-server is not active'

install -d -m 0755 "$EXPECTED_EXPORT"
install -d -m 0755 /etc/exports.d
printf '%s\n' "$EXPECTED_EXPORT $EXPECTED_CLIENT(rw,async,no_root_squash,no_subtree_check)" > "$EXPORT_FILE"
chmod 0644 "$EXPORT_FILE"
exportfs -ra

exportfs -v | grep -F "$EXPECTED_EXPORT" >/dev/null || fail 'backup export not active'
[[ "$(systemctl is-active cloudstack-agent)" == 'active' ]] || fail 'cloudstack-agent changed state during export reconciliation'
[[ "$(systemctl is-enabled cloudstack-agent)" == 'enabled' ]] || fail 'cloudstack-agent enablement changed during export reconciliation'

probe_dir="$(mktemp -d /mnt/layersentry-backup-probe.XXXXXX)"
cleanup() {
  umount "$probe_dir" >/dev/null 2>&1 || true
  rmdir "$probe_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mount -t nfs -o vers=4.2 "$EXPECTED_ADDRESS:$EXPECTED_EXPORT" "$probe_dir"
probe_file="$probe_dir/.layersentry-write-test-$$"
printf 'layersentry-backup-export-v2\n' > "$probe_file"
[[ "$(cat "$probe_file")" == 'layersentry-backup-export-v2' ]] || fail 'NFS write/read validation failed'
rm -f "$probe_file"
umount "$probe_dir"
trap - EXIT
rmdir "$probe_dir"

[[ "$(systemctl is-active cloudstack-agent)" == 'active' ]] || fail 'cloudstack-agent not active after mount validation'
[[ "$(systemctl is-enabled cloudstack-agent)" == 'enabled' ]] || fail 'cloudstack-agent not enabled after mount validation'

printf 'LAYERSENTRY_BACKUP_EXPORT_V2_COMPLETE\n'
printf 'EXPORT=%s\n' "$EXPECTED_EXPORT"
printf 'CLIENT=%s\n' "$EXPECTED_CLIENT"
printf 'NFS_V42_MOUNT_WRITE_TEST=true\n'
printf 'CLOUDSTACK_AGENT_PRESERVED=true\n'
