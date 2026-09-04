#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

MODE="${1:-validate}"
BRIDGE='cloudbr0'
PHYS_IF='eth0'
IP='10.10.10.14'
PREFIX='24'
GATEWAY='10.10.10.1'
ROLLBACK_UNIT='layersentry-cloudbr0-rollback'

validate() {
  echo '===== NETWORK VALIDATION ====='
  ip -4 -br addr
  ip route
  nmcli -f NAME,TYPE,DEVICE,AUTOCONNECT connection show
  bridge link show
  ip -4 address show dev "$BRIDGE" | grep -F "inet ${IP}/${PREFIX}"
  if ip -4 address show dev "$PHYS_IF" | grep -q 'inet '; then
    echo "ERROR: $PHYS_IF still has an IPv4 address" >&2
    exit 1
  fi
  ip route show default | grep -E "default via ${GATEWAY} dev ${BRIDGE}( |$)"
  bridge link show | grep -E "${PHYS_IF}.*master ${BRIDGE}"
  ping -c 3 -W 2 "$GATEWAY"
  curl -fsS --max-time 15 http://127.0.0.1:8080/client/config.json | grep -q Layersentry
  curl -fsS --max-time 15 "http://${IP}:8080/client/config.json" | grep -q Layersentry
  systemctl is-active --quiet cloudstack-management
  echo 'RUNNER_NETWORK_VALIDATION=PASS'
}

finalize() {
  validate
  systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
  systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
  virsh net-destroy default >/dev/null 2>&1 || true
  virsh net-autostart default --disable >/dev/null 2>&1 || true
  systemctl enable cloudstack-agent >/dev/null 2>&1 || true
  systemctl start cloudstack-agent >/dev/null 2>&1 || true
  sleep 5
  echo '===== FINAL NETWORK ====='
  ip -4 -br addr
  ip route
  bridge link show
  nmcli -f NAME,TYPE,DEVICE,AUTOCONNECT connection show --active
  echo '===== AGENT ====='
  systemctl is-active cloudstack-agent || true
  systemctl is-enabled cloudstack-agent || true
  systemctl --no-pager --full status cloudstack-agent || true
  journalctl -u cloudstack-agent -n 120 --no-pager || true
  echo '===== LIBVIRT NETWORKS ====='
  virsh net-list --all || true
  echo 'CLOUDBR0_MIGRATION_COMPLETE'
}

case "$MODE" in
  validate) validate ;;
  finalize) finalize ;;
  *) echo "Usage: $0 validate|finalize" >&2; exit 2 ;;
esac
