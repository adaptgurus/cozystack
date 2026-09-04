#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

EXPECTED_FQDN='layersentry.lab.example'
EXPECTED_IP='10.10.10.14'
PREFIX='24'
GATEWAY='10.10.10.1'
DNS='1.1.1.1,8.8.8.8'
DNS_SEARCH='lab.example'
PHYS_IF='eth0'
OLD_CONN='eth0'
BRIDGE='cloudbr0'
PORT_CONN='cloudbr0-eth0'
ROLLBACK_UNIT='layersentry-cloudbr0-rollback'
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/layersentry-cloudbr0-${STAMP}.log"
BACKUP="/var/backups/layersentry/network-${STAMP}"
ROLLBACK='/root/layersentry-cloudbr0-rollback.sh'

log(){ printf '%s\n' "$*" | tee -a "$LOG"; }
die(){ log "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ "$(hostname -f)" == "$EXPECTED_FQDN" ]] || die "Unexpected FQDN: $(hostname -f)"
primary="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')"
[[ "$primary" == "$EXPECTED_IP" ]] || die "Unexpected primary IPv4: ${primary:-none}"
ip link show "$PHYS_IF" >/dev/null 2>&1 || die "$PHYS_IF is missing."
nmcli -t -f NAME connection show | grep -Fxq "$OLD_CONN" || die "NetworkManager connection '$OLD_CONN' is missing."
[[ ! -e "/sys/class/net/$BRIDGE" ]] || die "$BRIDGE already exists; refusing an unreviewed repeat migration."
nmcli -t -f NAME connection show | grep -Fxq "$BRIDGE" && die "Connection '$BRIDGE' already exists."
nmcli -t -f NAME connection show | grep -Fxq "$PORT_CONN" && die "Connection '$PORT_CONN' already exists."
[[ "$(nmcli -g ipv4.method connection show "$OLD_CONN")" == 'manual' ]] || die "$OLD_CONN is not static/manual."
nmcli -g ipv4.addresses connection show "$OLD_CONN" | tr ',' '\n' | grep -Fxq "${EXPECTED_IP}/${PREFIX}" || die "Expected ${EXPECTED_IP}/${PREFIX} is not configured on $OLD_CONN."
[[ "$(nmcli -g ipv4.gateway connection show "$OLD_CONN")" == "$GATEWAY" ]] || die "Unexpected gateway on $OLD_CONN."
[[ -c /dev/kvm ]] || die '/dev/kvm is missing.'
[[ "$(systemctl is-active cloudstack-management 2>/dev/null || true)" == 'active' ]] || die 'cloudstack-management must be active before bridge migration.'
curl -fsS --max-time 10 http://127.0.0.1:8080/client/config.json | grep -q 'Layersentry' || die 'Layersentry runtime config is not being served.'

install -d -m 0700 "$BACKUP"
cp -a /etc/NetworkManager/system-connections "$BACKUP/system-connections"
nmcli -f all connection show "$OLD_CONN" >"$BACKUP/eth0-before.txt"
ip -4 -br addr >"$BACKUP/ip-before.txt"
ip route >"$BACKUP/routes-before.txt"

cat >"$ROLLBACK" <<EOF
#!/usr/bin/env bash
set -u
exec >>/var/log/layersentry-cloudbr0-rollback.log 2>&1
echo "ROLLBACK_START \$(date -Is) backup=$BACKUP"
nmcli connection down '$BRIDGE' 2>/dev/null || true
nmcli connection down '$PORT_CONN' 2>/dev/null || true
ip link set '$PHYS_IF' nomaster 2>/dev/null || true
rsync -a --delete '$BACKUP/system-connections/' /etc/NetworkManager/system-connections/
chmod 0700 /etc/NetworkManager/system-connections 2>/dev/null || true
chmod 0600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
nmcli connection reload
nmcli connection up '$OLD_CONN' || true
sleep 4
ip -4 -br addr
ip route
ping -c 2 -W 2 '$GATEWAY' || true
echo "ROLLBACK_END \$(date -Is)"
EOF
chmod 0700 "$ROLLBACK"

# A transient timer reverts the complete NetworkManager profile directory if the
# Windows runner cannot get back in and explicitly cancel it within 180 seconds.
systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" 2>/dev/null || true
systemd-run --unit="$ROLLBACK_UNIT" --on-active=180s "$ROLLBACK" >>"$LOG" 2>&1

log "BACKUP=$BACKUP"
log 'ROLLBACK_ARMED=180s'

# Create the bridge before touching the active Ethernet profile.
nmcli connection add type bridge ifname "$BRIDGE" con-name "$BRIDGE" \
  ipv4.method manual \
  ipv4.addresses "${EXPECTED_IP}/${PREFIX}" \
  ipv4.gateway "$GATEWAY" \
  ipv4.dns "$DNS" \
  ipv4.dns-search "$DNS_SEARCH" \
  ipv4.ignore-auto-dns yes \
  ipv6.method disabled \
  bridge.stp no >/dev/null
nmcli connection modify "$BRIDGE" \
  connection.autoconnect yes \
  connection.autoconnect-priority 100 \
  connection.zone public

nmcli connection add type ethernet ifname "$PHYS_IF" con-name "$PORT_CONN" \
  master "$BRIDGE" slave-type bridge >/dev/null
nmcli connection modify "$PORT_CONN" connection.autoconnect yes
nmcli connection modify "$OLD_CONN" connection.autoconnect no connection.autoconnect-priority -999

# Bring the L3 bridge up first, then move the physical NIC from its old profile
# to the bridge port. A short loss of the SSH transport is expected here.
nmcli connection up "$BRIDGE" >/dev/null
nmcli connection down "$OLD_CONN" >/dev/null || true
nmcli connection up "$PORT_CONN" >/dev/null
sleep 8

ip -4 address show dev "$BRIDGE" | grep -Fq "inet ${EXPECTED_IP}/${PREFIX}" || die "${EXPECTED_IP}/${PREFIX} is not on $BRIDGE."
! ip -4 address show dev "$PHYS_IF" | grep -q 'inet ' || die "$PHYS_IF still owns an IPv4 address."
ip route show default | grep -Eq "default via ${GATEWAY} dev ${BRIDGE}( |$)" || die "Default route is not via $BRIDGE."
bridge link show | grep -Eq "${PHYS_IF}.*master ${BRIDGE}" || die "$PHYS_IF is not enslaved to $BRIDGE."
ping -c 3 -W 2 "$GATEWAY" >/dev/null || die 'Gateway connectivity failed after bridge migration.'
curl -fsS --max-time 10 http://127.0.0.1:8080/client/config.json | grep -q 'Layersentry' || die 'Layersentry management UI failed locally after bridge migration.'

log 'BRIDGE_LOCAL_VALIDATION=PASS'
log '[READY_FOR_RUNNER_VALIDATION]'
