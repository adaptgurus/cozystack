#!/usr/bin/env bash
set -u
section(){ printf '\n===== %s =====\n' "$1"; }

section RUNTIME_HEADERS
curl -sS -D - -o /tmp/runtime-config.json --max-time 15 http://127.0.0.1:8080/client/config.json | sed -n '1,30p' || true
sha256sum /tmp/runtime-config.json 2>/dev/null || true
python3 - /tmp/runtime-config.json <<'PY' 2>/dev/null || true
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
print('RUNTIME', c.get('appTitle'), c.get('footer'), c.get('logo'), c.get('userCard',{}).get('enabled'), c.get('apidocs'))
PY

section CONFIG_FILES
while IFS= read -r p; do
  echo "--- $p"
  ls -l "$p" 2>/dev/null || true
  sha256sum "$p" 2>/dev/null || true
  python3 - "$p" <<'PY' 2>/dev/null || true
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
print('JSON',c.get('appTitle'),c.get('footer'),c.get('logo'),c.get('userCard',{}).get('enabled'),c.get('apidocs'))
PY
done < <(find /etc/cloudstack /usr/share/cloudstack-management /usr/share/cloudstack-ui /var/lib/cloudstack /var/cache/cloudstack /var/log/cloudstack -xdev \( -type f -o -type l \) -name config.json -print 2>/dev/null | sort -u)

section STOCK_CONFIG_MATCHES
grep -Rsl --include='config.json' '"appTitle"[[:space:]]*:[[:space:]]*"CloudStack"' /etc/cloudstack /usr/share/cloudstack-management /usr/share/cloudstack-ui /var/lib/cloudstack 2>/dev/null | head -50 || true

section LAYERSENTRY_CONFIG_MATCHES
grep -Rsl --include='config.json' '"appTitle"[[:space:]]*:[[:space:]]*"Layersentry"' /etc/cloudstack /usr/share/cloudstack-management /usr/share/cloudstack-ui /var/lib/cloudstack 2>/dev/null | head -50 || true

section UI_INDEXES
find /etc/cloudstack /usr/share/cloudstack-management /usr/share/cloudstack-ui /var/lib/cloudstack -xdev -type f -name index.html -print 2>/dev/null | sort -u

section SERVICE
systemctl cat cloudstack-management 2>&1 || true
systemctl show cloudstack-management -p ExecStart -p Environment -p EnvironmentFiles -p WorkingDirectory 2>&1 || true
ps -ef | grep '[j]ava' || true

section PACKAGE
rpm -ql cloudstack-ui | sed -n '1,240p'
rpm -ql cloudstack-management | grep -E '(/client|webapp|config.json|index.html)' | head -300 || true

section COMPLETE
echo CONFIG_SOURCE_DIAG_COMPLETE
