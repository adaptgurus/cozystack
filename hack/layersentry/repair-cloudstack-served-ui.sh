#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

EXPECTED_FQDN='layersentry.lab.example'
EXPECTED_IP='10.10.10.14'
EXPECTED_VERSION='4.22.1.1-1'
STAGED_UI='/usr/share/cloudstack-ui'
SERVED_UI='/usr/share/cloudstack-management/webapp'
SERVED_CONFIG='/etc/cloudstack/management/config.json'
LOG="/var/log/layersentry-served-ui-repair-$(date +%Y%m%d-%H%M%S).log"
STAGE='initialization'

log(){ printf '%s\n' "$*" | tee -a "$LOG"; }
stage(){ STAGE="$1"; log "==> $STAGE"; }
die(){ log "ERROR: $*" >&2; exit 1; }
onerr(){ rc=$?; set +e; log "ERROR: served UI repair failed during '$STAGE' at line ${BASH_LINENO[0]:-unknown} (exit $rc)."; exit "$rc"; }
trap onerr ERR

exact_pkg(){
  local pkg="$1" v
  rpm -q "$pkg" >/dev/null 2>&1 || return 1
  v="$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$pkg")"
  [[ "$v" == "$EXPECTED_VERSION" || "$v" == "$EXPECTED_VERSION."* ]]
}

stage 'validating target and package layout'
[[ $EUID -eq 0 ]] || die 'Run as root.'
[[ "$(hostname -f)" == "$EXPECTED_FQDN" ]] || die "Unexpected FQDN: $(hostname -f)"
primary_ip="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')"
[[ "$primary_ip" == "$EXPECTED_IP" ]] || die "Unexpected primary IP: $primary_ip"
exact_pkg cloudstack-management || die 'cloudstack-management exact 4.22.1.1-1 is required.'
exact_pkg cloudstack-ui || die 'cloudstack-ui exact 4.22.1.1-1 is required.'
exact_pkg cloudstack-agent || die 'cloudstack-agent exact 4.22.1.1-1 is required.'
[[ -d "$STAGED_UI" && -f "$STAGED_UI/index.html" ]] || die "Staged UI missing at $STAGED_UI"
[[ -d "$SERVED_UI" && -f "$SERVED_UI/index.html" ]] || die "Served management webapp missing at $SERVED_UI"
[[ -d "$SERVED_UI/WEB-INF" ]] || die 'Management WEB-INF is missing; refusing to modify webapp.'
[[ -f "$STAGED_UI/config.json" ]] || die 'Staged Layersentry config is missing.'
python3 - "$STAGED_UI/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
checks={
 'appTitle':c.get('appTitle')=='Layersentry',
 'loginTitle':c.get('loginTitle')=='Layersentry',
 'footer':c.get('footer')=='Layersentry V1.0',
 'logo':c.get('logo')=='assets/layersentry-logo.svg',
 'minilogo':c.get('minilogo')=='assets/layersentry-icon.svg',
 'userCard':c.get('userCard',{}).get('enabled') is False,
 'apidocs':c.get('apidocs') is False,
 'notifyLatestCSVersion':c.get('notifyLatestCSVersion') is False,
}
print('STAGED_CONFIG_CHECKS='+json.dumps(checks,sort_keys=True))
assert all(checks.values())
PY
grep -Rqs --include='*.js' 'DBaaS' "$STAGED_UI" || die 'DBaaS is not compiled in staged UI.'
grep -Rqs --include='*.js' 'APaaS' "$STAGED_UI" || die 'APaaS is not compiled in staged UI.'
grep -Rqs --include='*.js' 'Secure cloud infrastructure management' "$STAGED_UI" || die 'Layersentry onboarding is not compiled in staged UI.'

stage 'backing up served management webapp'
stamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="/var/backups/layersentry/${stamp}/served-ui-repair"
install -d -m 0700 "$backup_dir"
tar --xattrs --acls -C /usr/share/cloudstack-management -czf "$backup_dir/webapp-before.tar.gz" webapp
chmod 0600 "$backup_dir/webapp-before.tar.gz"
if [[ -e "$SERVED_CONFIG" || -L "$SERVED_CONFIG" ]]; then
  cp -aL "$SERVED_CONFIG" "$backup_dir/config.json.before"
  chmod 0600 "$backup_dir/config.json.before"
fi
log "INFO: Backup created at $backup_dir"

stage 'deploying Layersentry into the served management webapp'
systemctl stop cloudstack-management
# Overlay only static UI content. Never delete or overwrite backend WEB-INF/META-INF.
rsync -a --exclude='config.json' --exclude='WEB-INF' --exclude='META-INF' \
  --chown=root:root --chmod=D755,F644 "$STAGED_UI/" "$SERVED_UI/"
install -D -m 0644 -o root -g root "$STAGED_UI/config.json" "$SERVED_CONFIG"
# CloudStack RPM layout expects the webapp config to resolve to /etc/cloudstack/management/config.json.
if [[ -e "$SERVED_UI/config.json" || -L "$SERVED_UI/config.json" ]]; then
  rm -f "$SERVED_UI/config.json"
fi
ln -s "$SERVED_CONFIG" "$SERVED_UI/config.json"
restorecon -RF "$SERVED_UI" "$SERVED_CONFIG" >/dev/null 2>&1 || true
# Keep the agent quiet until cloudbr0 is intentionally configured.
systemctl disable --now cloudstack-agent >/dev/null 2>&1 || true
systemctl start cloudstack-management

stage 'waiting for management HTTP readiness'
code=''
for _ in $(seq 1 90); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/client/ || true)"
  [[ "$code" == '200' ]] && break
  sleep 5
done
[[ "$code" == '200' ]] || die "Management UI did not return HTTP 200; last code='$code'."

stage 'verifying served Layersentry runtime'
tmp="$(mktemp /tmp/layersentry-served-config.XXXXXX.json)"
trap 'rm -f "$tmp"' EXIT
curl -fsS --max-time 15 http://127.0.0.1:8080/client/config.json -o "$tmp"
python3 - "$tmp" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
checks={
 'appTitle':c.get('appTitle')=='Layersentry',
 'loginTitle':c.get('loginTitle')=='Layersentry',
 'footer':c.get('footer')=='Layersentry V1.0',
 'logo':c.get('logo')=='assets/layersentry-logo.svg',
 'minilogo':c.get('minilogo')=='assets/layersentry-icon.svg',
 'userCard':c.get('userCard',{}).get('enabled') is False,
 'apidocs':c.get('apidocs') is False,
 'notifyLatestCSVersion':c.get('notifyLatestCSVersion') is False,
}
print('RUNTIME_CONFIG_CHECKS='+json.dumps(checks,sort_keys=True))
assert all(checks.values())
PY
for asset in layersentry-logo.svg layersentry-icon.svg; do
  asset_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:8080/client/assets/$asset")"
  [[ "$asset_code" == '200' ]] || die "Asset $asset returned HTTP $asset_code."
done
grep -Rqs --include='*.js' 'DBaaS' "$SERVED_UI" || die 'DBaaS missing from served webapp.'
grep -Rqs --include='*.js' 'APaaS' "$SERVED_UI" || die 'APaaS missing from served webapp.'
grep -Rqs --include='*.js' 'Secure cloud infrastructure management' "$SERVED_UI" || die 'Layersentry onboarding missing from served webapp.'
[[ "$(readlink -f "$SERVED_UI/config.json")" == "$SERVED_CONFIG" ]] || die 'Served config symlink target is wrong.'
systemctl is-active --quiet cloudstack-management || die 'cloudstack-management is not active.'
agent_state="$(systemctl is-active cloudstack-agent 2>/dev/null || true)"
agent_enabled="$(systemctl is-enabled cloudstack-agent 2>/dev/null || true)"

stage 'confirming infrastructure remains untouched'
counts="$(mysql --protocol=socket -uroot -NBe "SELECT CONCAT('zones=',COUNT(*)) FROM cloud.data_center; SELECT CONCAT('pods=',COUNT(*)) FROM cloud.host_pod_ref; SELECT CONCAT('clusters=',COUNT(*)) FROM cloud.cluster; SELECT CONCAT('hosts=',COUNT(*)) FROM cloud.host; SELECT CONCAT('primary_storage=',COUNT(*)) FROM cloud.storage_pool;" 2>/dev/null || true)"
printf '%s\n' "$counts" | tee -a "$LOG"

log "HTTP=$code"
log "SERVED_CONFIG=$(readlink -f "$SERVED_UI/config.json")"
log "AGENT_STATE=$agent_state"
log "AGENT_ENABLED=$agent_enabled"
log "BACKUP=$backup_dir"
log '[100%] Layersentry served management UI repair completed'
