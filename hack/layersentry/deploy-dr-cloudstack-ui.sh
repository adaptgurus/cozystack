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

# BEGIN BACKEND FINGERPRINT
# Hash regular file bytes, directory membership, and symlink targets without
# following links outside the packaged backend. Missing optional META-INF is
# part of the fingerprint; staging must not create it or remove an existing one.
backend_fingerprint() {
  python3 - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
entries = []
def fail_walk(error):
    raise error

for name in ('WEB-INF', 'META-INF'):
    base = root / name
    if not base.exists() and not base.is_symlink():
        entries.append([name, 'absent'])
        continue
    if base.is_symlink() or not base.is_dir():
        raise SystemExit('Backend root must be a real directory')
    paths = [base]
    for directory, directories, files in os.walk(base, followlinks=False, onerror=fail_walk):
        paths.extend(Path(directory) / child for child in directories + files)
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            entries.append([relative, 'link', os.readlink(path)])
        elif stat.S_ISDIR(mode):
            entries.append([relative, 'directory'])
        elif stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            entries.append([relative, 'file', digest.hexdigest()])
        else:
            raise SystemExit('Unexpected special file in backend')
print(hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest())
PY
}
# END BACKEND FINGERPRINT

# BEGIN RUNTIME CONFIG TOOL
runtime_config_tool() {
  python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import sys

BRANDING_KEYS = (
    'appTitle', 'productProfile', 'brandLocked', 'footer', 'loginTitle',
    'loginFavicon', 'loginFooter', 'resetPasswordFooter', 'logo', 'minilogo',
    'banner', 'favicon', 'theme', 'allowSettingTheme',
)

def read_object(path):
    try:
        def reject_constant(_value):
            raise ValueError('non-JSON constant')
        value = json.loads(Path(path).read_text(encoding='utf-8'), parse_constant=reject_constant)
        if not isinstance(value, dict):
            raise ValueError('not an object')
        return value
    except (OSError, ValueError):
        raise SystemExit('Runtime configuration must be a readable JSON object') from None

if sys.argv[1] == 'merge':
    defaults_path, existing_path, candidate_path = map(Path, sys.argv[2:])
    defaults = read_object(defaults_path)
    existing = read_object(existing_path) if existing_path.exists() or existing_path.is_symlink() else {}
    if not all(key in defaults for key in BRANDING_KEYS):
        raise SystemExit('Artifact configuration is missing required branding keys')
    merged = dict(defaults)
    merged.update(existing)
    merged.update({key: defaults[key] for key in BRANDING_KEYS})
    # Exclusive creation in the private deployment stage; never modify the
    # immutable artifact or print existing configuration values.
    try:
        descriptor = os.open(candidate_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(merged, stream, indent=2)
            stream.write('\n')
    except OSError:
        raise SystemExit('Cannot create private runtime configuration candidate') from None
elif sys.argv[1] == 'verify':
    if read_object(sys.argv[2]) != read_object(sys.argv[3]):
        raise SystemExit('Deployed runtime configuration differs from the preserved candidate')
else:
    raise SystemExit('Unsupported runtime configuration operation')
PY
}
# END RUNTIME CONFIG TOOL

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Deployment must run as root.'
[[ $# -eq 3 ]] || die 'Expected bundle directory, UI commit, and run identity.'

BUNDLE=$1
UI_COMMIT=$2
RUN_ID=$3
[[ "$BUNDLE" == "/run/layersentry-dr-ui-${RUN_ID}" ]] || die 'Unexpected deployment bundle path.'
# BEGIN REVIEWED UI SOURCE
case "$UI_COMMIT" in
  "$EXPECTED_UI_COMMIT"|dc58f76f67dac13aa886c8d45475944f31b0c039) EXPECTED_UI_COMMIT=$UI_COMMIT ;;
  *) die 'CloudStack UI commit is not the authorized commit.' ;;
esac
# END REVIEWED UI SOURCE
[[ "$RUN_ID" =~ ^[0-9]+-[0-9]+$ ]] || die 'Invalid workflow run identity.'

ARCHIVE="$BUNDLE/ui-dist.tar.gz"
CHECKSUM="$BUNDLE/ui-dist.tar.gz.sha256"
MANIFEST="$BUNDLE/build-manifest.json"
STAGE_ROOT="/usr/share/cloudstack-management/.layersentry-ui-${RUN_ID}"
EXTRACTED="$STAGE_ROOT/extracted/ui-dist"
CANDIDATE="$STAGE_ROOT/candidate"
CONFIG_CANDIDATE="$STAGE_ROOT/runtime-config-candidate.json"
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

for command in curl python3 restorecon rpm sha256sum systemctl tar timeout; do
  command -v "$command" >/dev/null 2>&1 || die "Required command is missing: $command"
done
[[ -f /etc/os-release ]] || die 'Rocky Linux release metadata is missing.'
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == rocky && "${VERSION_ID:-}" == 9.* ]] || die 'Target is not Rocky Linux 9.'
observed_version=$(rpm -q --qf '%{VERSION}' cloudstack-management 2>/dev/null) || die 'Cannot query cloudstack-management version.'
[[ "$observed_version" == "$EXPECTED_CLOUDSTACK_VERSION" ]] || die "cloudstack-management is not exact version $EXPECTED_CLOUDSTACK_VERSION."
[[ -d "$SERVED_UI" && -f "$SERVED_UI/index.html" ]] || die 'CloudStack served webapp is missing.'
# CloudStack 4.22.1.1 packaging/el8/cloud.spec includes this webapp in the
# management RPM; the optional cloudstack-ui RPM serves a separate directory.
observed_owner=$(rpm -qf --qf '%{NAME} %{VERSION}\n' "$SERVED_UI/index.html" 2>/dev/null) || die 'Cannot query CloudStack served webapp package ownership.'
[[ "$observed_owner" == "cloudstack-management $EXPECTED_CLOUDSTACK_VERSION" ]] || die "CloudStack served webapp is not owned by cloudstack-management $EXPECTED_CLOUDSTACK_VERSION."
# The META-INF in client/target/classes/META-INF/webapp is an outer build
# directory, not a required directory inside the installed webapp.
[[ -d "$SERVED_UI/WEB-INF" && ! -L "$SERVED_UI/WEB-INF" && -f "$SERVED_UI/WEB-INF/web.xml" && ! -L "$SERVED_UI/WEB-INF/web.xml" ]] || die 'Required CloudStack backend WEB-INF/web.xml is missing or unsafe.'
backend_owner=$(rpm -qf --qf '%{NAME} %{VERSION}\n' "$SERVED_UI/WEB-INF/web.xml" 2>/dev/null) || die 'Cannot query CloudStack backend package ownership.'
[[ "$backend_owner" == "cloudstack-management $EXPECTED_CLOUDSTACK_VERSION" ]] || die "CloudStack backend is not owned by cloudstack-management $EXPECTED_CLOUDSTACK_VERSION."
BACKEND_BEFORE=$(backend_fingerprint "$SERVED_UI") || die 'Cannot fingerprint CloudStack backend content.'
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

# Minimal Rocky installations may omit rsync. Keep the existing metadata-aware
# deploy/rollback algorithm and provision its prerequisite before any UI change.
if ! command -v rsync >/dev/null 2>&1; then
  command -v dnf >/dev/null 2>&1 || die 'rsync is missing and dnf is unavailable.'
  printf 'RSYNC_PREREQUISITE=INSTALLING\n'
  if ! timeout 180 dnf -y --setopt=timeout=30 --setopt=retries=2 install rsync >"$BUNDLE/rsync-install.log" 2>&1; then
    die 'rsync installation failed before UI mutation; inspect host package-manager logs.'
  fi
fi
command -v rsync >/dev/null 2>&1 || die 'rsync is unavailable after prerequisite provisioning.'
printf 'RSYNC_PREREQUISITE=READY\n'
rpm -q rsync

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
runtime_config_tool merge "$EXTRACTED/config.json" "$SERVED_CONFIG" "$CONFIG_CANDIDATE"

rsync -aHAX --numeric-ids "$SERVED_UI/" "$CANDIDATE/"
rsync -a --delete --exclude='/WEB-INF/' --exclude='/META-INF/' --exclude='/config.json' --chown=root:root --chmod=D755,F644 "$EXTRACTED/" "$CANDIDATE/"
[[ "$(backend_fingerprint "$CANDIDATE")" == "$BACKEND_BEFORE" ]] || die 'Staging did not preserve CloudStack backend content.'
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
printf '%s\n' "$BACKEND_BEFORE" >"$BACKUP_DIR/backend-before.sha256"

DEPLOYMENT_STARTED=true
systemctl stop cloudstack-management
rsync -aHAX --numeric-ids --delete --exclude='/WEB-INF/' --exclude='/META-INF/' --exclude='/config.json' "$CANDIDATE/" "$SERVED_UI/"
[[ "$(backend_fingerprint "$SERVED_UI")" == "$BACKEND_BEFORE" ]] || die 'CloudStack backend content was not preserved during deployment.'
install -m 0644 -o root -g root "$CONFIG_CANDIDATE" "${SERVED_CONFIG}.new-${RUN_ID}"
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
runtime_config_tool verify "$CONFIG_CANDIDATE" "$SERVED_CONFIG"
runtime_config_tool verify "$CONFIG_CANDIDATE" "$runtime_config"
printf 'RUNTIME_CONFIG_PRESERVATION=PASS\n'
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

python3 - "$EXTRACTED" "$SERVED_UI" <<'PY'
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import urlsplit
from urllib.request import urlopen

expected, served = map(Path, sys.argv[1:])
for path in expected.rglob('*'):
    if path.is_file() and path.relative_to(expected).as_posix() != 'config.json':
        assert path.read_bytes() == (served / path.relative_to(expected)).read_bytes(), str(path.relative_to(expected))

class Assets(HTMLParser):
    paths = {'index.html'}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        value = attrs.get('src') if tag == 'script' else attrs.get('href') if tag == 'link' else None
        if value and urlsplit(value).path.endswith(('.js', '.css')):
            assert not urlsplit(value).scheme and not urlsplit(value).netloc
            relative = urlsplit(value).path.removeprefix('/client/').removeprefix('./')
            assert not relative.startswith('/') and '..' not in Path(relative).parts
            self.paths.add(relative)

assets = Assets()
assets.feed((expected / 'index.html').read_text())
for relative in sorted(assets.paths):
    with urlopen('http://127.0.0.1:8080/client/' + relative, timeout=30) as response:
        assert response.status == 200
        assert hashlib.sha256(response.read()).digest() == hashlib.sha256((expected / relative).read_bytes()).digest(), relative
print('EXACT_UI_FILES=PASS')
print('HTTP_UI_ASSET_HASHES=PASS')
PY

[[ "$(backend_fingerprint "$SERVED_UI")" == "$BACKEND_BEFORE" ]] || die 'CloudStack backend content changed during final verification.'
printf 'BACKEND_CONTENT_HASHES=PASS\n'
DEPLOYMENT_PASSED=true
printf 'LAYERSENTRY_DR_UI_DEPLOYMENT=PASS\n'
printf 'CLOUDSTACK_UI_COMMIT=%s\n' "$UI_COMMIT"
printf 'CLOUDSTACK_VERSION=%s\n' "$EXPECTED_CLOUDSTACK_VERSION"
printf 'RUNTIME_PRODUCT=%s\n' "$EXPECTED_PRODUCT"
printf 'RUNTIME_PROFILE=%s\n' "$EXPECTED_PROFILE"
printf 'HTTP_CLIENT=%s\n' "$http_code"
printf 'BACKUP=%s\n' "$BACKUP_DIR"
