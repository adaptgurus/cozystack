#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

EXPECTED_UI_COMMIT='c4a2bb29457634e38a9375d5de33b04eb3a9c825'
EXPECTED_CLOUDSTACK_VERSION='4.22.1.1'
EXPECTED_PRODUCT='LayerSentry'
EXPECTED_PROFILE='layersentry-kvm'
SERVED_UI='/usr/share/cloudstack-management/webapp'
SERVED_CONFIG='/etc/cloudstack/management/config.json'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Deployment must run as root.'
[[ $# -eq 3 ]] || die 'Expected bundle directory, UI commit, and run identity.'

BUNDLE=$1
UI_COMMIT=$2
RUN_ID=$3
[[ "$BUNDLE" == "/run/layersentry-dr-ui-${RUN_ID}" ]] || die 'Unexpected deployment bundle path.'
[[ "$UI_COMMIT" == "$EXPECTED_UI_COMMIT" ]] || die 'CloudStack UI commit is not the authorized commit.'
[[ "$RUN_ID" =~ ^[0-9]+-[0-9]+$ ]] || die 'Invalid workflow run identity.'

ARCHIVE="$BUNDLE/ui-dist.tar.gz"
CHECKSUM="$BUNDLE/ui-dist.tar.gz.sha256"
MANIFEST="$BUNDLE/build-manifest.json"
STAGE_ROOT="/usr/share/cloudstack-management/.layersentry-ui-${RUN_ID}"
EXTRACTED="$STAGE_ROOT/extracted/ui-dist"
CANDIDATE="$STAGE_ROOT/candidate"
STAGE_CREATED=false
BACKUP_DIR=''
CONFIG_WAS_PRESENT=false
DEPLOYMENT_STARTED=false
DEPLOYMENT_PASSED=false

rollback() {
  local rollback_root="$STAGE_ROOT/rollback"
  local failed=0
  printf '%s\n' 'ROLLBACK=STARTED' >&2
  systemctl stop cloudstack-management || failed=1
  install -d -m 0700 "$rollback_root" || failed=1
  if tar --xattrs --acls --selinux -xzf "$BACKUP_DIR/webapp-before.tar.gz" -C "$rollback_root"; then
    rsync -aHAX --numeric-ids --delete "$rollback_root/webapp/" "$SERVED_UI/" || failed=1
    if [[ "$CONFIG_WAS_PRESENT" == true ]]; then
      install -m 0644 -o root -g root "$BACKUP_DIR/config.json.before" "${SERVED_CONFIG}.rollback-${RUN_ID}" || failed=1
      mv -fT "${SERVED_CONFIG}.rollback-${RUN_ID}" "$SERVED_CONFIG" || failed=1
    else
      rm -f -- "$SERVED_CONFIG" || failed=1
    fi
    restorecon -RF "$SERVED_UI" || failed=1
    [[ ! -e "$SERVED_CONFIG" && ! -L "$SERVED_CONFIG" ]] || restorecon -F "$SERVED_CONFIG" || failed=1
    systemctl start cloudstack-management || failed=1
  else
    failed=1
  fi
  if (( failed == 0 )); then
    printf '%s\n' 'ROLLBACK=COMPLETED' >&2
  else
    printf 'ROLLBACK=FAILED; restore manually from %s\n' "$BACKUP_DIR" >&2
    return 1
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )) && [[ "$DEPLOYMENT_STARTED" == true && "$DEPLOYMENT_PASSED" != true && -n "$BACKUP_DIR" ]]; then
    rollback || true
  fi
  if [[ "$STAGE_CREATED" == true && -d "$STAGE_ROOT" ]]; then
    rm -rf -- "$STAGE_ROOT"
  fi
  exit "$rc"
}
trap cleanup EXIT

for command in curl python3 restorecon rpm rsync sha256sum systemctl tar; do
  command -v "$command" >/dev/null 2>&1 || die "Required command is missing: $command"
done
[[ -f /etc/os-release ]] || die 'Rocky Linux release metadata is missing.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID:-}" == 9.* ]] || die 'Target is not Rocky Linux 9.'
for package in cloudstack-management cloudstack-ui; do
  observed_version=$(rpm -q --qf '%{VERSION}' "$package" 2>/dev/null || true)
  [[ "$observed_version" == "$EXPECTED_CLOUDSTACK_VERSION" ]] || die "$package is not exact version $EXPECTED_CLOUDSTACK_VERSION."
done
[[ -d "$SERVED_UI" && -f "$SERVED_UI/index.html" ]] || die 'CloudStack served webapp is missing.'
[[ -d "$SERVED_UI/WEB-INF" && -d "$SERVED_UI/META-INF" ]] || die 'CloudStack backend WEB-INF/META-INF content is missing.'
systemctl is-active --quiet cloudstack-management || die 'cloudstack-management must be healthy before deployment.'
[[ -f "$ARCHIVE" && -f "$CHECKSUM" && -f "$MANIFEST" ]] || die 'The prebuilt UI bundle is incomplete.'

(
  cd "$BUNDLE"
  sha256sum --check --strict ui-dist.tar.gz.sha256
)
python3 - "$MANIFEST" "$ARCHIVE" "$EXPECTED_UI_COMMIT" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, archive_path, expected_commit = sys.argv[1:]
manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding='utf-8'))
archive_hash = hashlib.sha256(pathlib.Path(archive_path).read_bytes()).hexdigest()
assert manifest == {
    'schemaVersion': '1.0',
    'product': 'LayerSentry',
    'component': 'cloudstack-ui',
    'cloudstackUiCommit': expected_commit,
    'artifact': 'ui-dist.tar.gz',
    'artifactSha256': archive_hash,
    'builtOnManagementNode': False,
}
PY
python3 - "$ARCHIVE" <<'PY'
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], mode='r:gz') as archive:
    members = archive.getmembers()
    assert members
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute()
        assert '..' not in path.parts
        assert path.parts[0] == 'ui-dist'
        assert member.isfile() or member.isdir()
        assert not member.issym() and not member.islnk()
        assert not (len(path.parts) > 1 and path.parts[1] in {'WEB-INF', 'META-INF'})
PY

[[ ! -e "$STAGE_ROOT" ]] || die 'A deployment stage already exists for this run identity.'
install -d -m 0700 "$STAGE_ROOT/extracted" "$CANDIDATE"
STAGE_CREATED=true
tar --no-same-owner --no-same-permissions -xzf "$ARCHIVE" -C "$STAGE_ROOT/extracted"
[[ -f "$EXTRACTED/index.html" && -f "$EXTRACTED/config.json" ]] || die 'Prebuilt UI archive does not contain the expected dist files.'
python3 - "$EXTRACTED/config.json" "$EXPECTED_PRODUCT" "$EXPECTED_PROFILE" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding='utf-8'))
product, profile = sys.argv[2:]
assert config.get('appTitle') == product
assert config.get('loginTitle') == product
assert config.get('footer') == product
assert config.get('productProfile') == profile
assert config.get('brandLocked') is True
assert config.get('logo') == 'assets/layersentry-logo.svg'
assert config.get('minilogo') == 'assets/layersentry-icon.svg'
PY
grep -Rqs --include='*.js' 'LayerSentry' "$EXTRACTED" || die 'Compiled UI does not contain LayerSentry product branding.'
grep -Rqs --include='*.js' 'layersentry-kvm' "$EXTRACTED" || die 'Compiled UI does not contain the LayerSentry KVM profile.'

rsync -aHAX --numeric-ids "$SERVED_UI/" "$CANDIDATE/"
rsync -a --delete --exclude='/WEB-INF/' --exclude='/META-INF/' --exclude='/config.json' --chown=root:root --chmod=D755,F644 "$EXTRACTED/" "$CANDIDATE/"
[[ -d "$CANDIDATE/WEB-INF" && -d "$CANDIDATE/META-INF" ]] || die 'Staging did not preserve CloudStack backend content.'
sync

stamp=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="/var/backups/layersentry/${stamp}-dr-ui-${RUN_ID}"
install -d -m 0700 "$BACKUP_DIR"
tar --xattrs --acls --selinux -C "$(dirname "$SERVED_UI")" -czf "$BACKUP_DIR/webapp-before.tar.gz" "$(basename "$SERVED_UI")"
chmod 0600 "$BACKUP_DIR/webapp-before.tar.gz"
if [[ -e "$SERVED_CONFIG" || -L "$SERVED_CONFIG" ]]; then
  cp -aL "$SERVED_CONFIG" "$BACKUP_DIR/config.json.before"
  chmod 0600 "$BACKUP_DIR/config.json.before"
  CONFIG_WAS_PRESENT=true
fi
install -m 0600 "$MANIFEST" "$BACKUP_DIR/deployed-build-manifest.json"

DEPLOYMENT_STARTED=true
systemctl stop cloudstack-management
rsync -aHAX --numeric-ids --delete --exclude='/WEB-INF/' --exclude='/META-INF/' --exclude='/config.json' "$CANDIDATE/" "$SERVED_UI/"
[[ -d "$SERVED_UI/WEB-INF" && -d "$SERVED_UI/META-INF" ]] || die 'CloudStack backend content was not preserved during deployment.'
install -m 0644 -o root -g root "$EXTRACTED/config.json" "${SERVED_CONFIG}.new-${RUN_ID}"
mv -fT "${SERVED_CONFIG}.new-${RUN_ID}" "$SERVED_CONFIG"
ln -s "$SERVED_CONFIG" "$SERVED_UI/.config.json-${RUN_ID}"
mv -fT "$SERVED_UI/.config.json-${RUN_ID}" "$SERVED_UI/config.json"
restorecon -RF "$SERVED_UI" "$SERVED_CONFIG"
systemctl start cloudstack-management

http_code=''
for _ in $(seq 1 60); do
  http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/client/ || true)
  [[ "$http_code" == 200 ]] && break
  sleep 5
done
[[ "$http_code" == 200 ]] || die "CloudStack UI readiness failed with HTTP status ${http_code:-none}."

runtime_config="$STAGE_ROOT/runtime-config.json"
runtime_logo="$STAGE_ROOT/runtime-logo.svg"
curl -fsS --max-time 15 http://127.0.0.1:8080/client/config.json -o "$runtime_config"
curl -fsS --max-time 15 http://127.0.0.1:8080/client/assets/layersentry-logo.svg -o "$runtime_logo"
python3 - "$runtime_config" "$EXPECTED_PRODUCT" "$EXPECTED_PROFILE" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding='utf-8'))
product, profile = sys.argv[2:]
assert config.get('appTitle') == product
assert config.get('loginTitle') == product
assert config.get('footer') == product
assert config.get('productProfile') == profile
assert config.get('brandLocked') is True
assert config.get('logo') == 'assets/layersentry-logo.svg'
assert config.get('minilogo') == 'assets/layersentry-icon.svg'
PY
grep -Fq '<title id="title">Layer Sentry</title>' "$runtime_logo" || die 'Served LayerSentry logo branding is invalid.'
grep -Rqs --include='*.js' 'LayerSentry' "$SERVED_UI" || die 'Served compiled UI does not contain LayerSentry branding.'
grep -Rqs --include='*.js' 'layersentry-kvm' "$SERVED_UI" || die 'Served compiled UI does not contain the LayerSentry KVM profile.'
[[ "$(readlink -f "$SERVED_UI/config.json")" == "$SERVED_CONFIG" ]] || die 'Served config does not resolve to the installed LayerSentry config.'
systemctl is-active --quiet cloudstack-management || die 'cloudstack-management is not active after deployment.'

DEPLOYMENT_PASSED=true
printf 'LAYERSENTRY_DR_UI_DEPLOYMENT=PASS\n'
printf 'CLOUDSTACK_UI_COMMIT=%s\n' "$UI_COMMIT"
printf 'CLOUDSTACK_VERSION=%s\n' "$EXPECTED_CLOUDSTACK_VERSION"
printf 'RUNTIME_PRODUCT=%s\n' "$EXPECTED_PRODUCT"
printf 'RUNTIME_PROFILE=%s\n' "$EXPECTED_PROFILE"
printf 'HTTP_CLIENT=%s\n' "$http_code"
printf 'BACKUP=%s\n' "$BACKUP_DIR"
