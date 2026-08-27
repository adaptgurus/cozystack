#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

printf '\n[1/5] Checking patch whitespace against v1.6.2...\n'
git diff --check v1.6.2...HEAD

printf '\n[2/5] Running tenant resolver unit tests...\n'
go test ./pkg/tenantresolver

printf '\n[3/5] Linting external VM network chart...\n'
helm lint packages/apps/vm-network \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500

printf '\n[4/5] Rendering and validating external VM network NAD...\n'
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
helm template prod-vlan120 packages/apps/vm-network \
  --namespace tenant-test \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500 > "$rendered"

grep -q 'kind: NetworkAttachmentDefinition' "$rendered"
grep -q 'name: prod-vlan120' "$rendered"
grep -q 'namespace: tenant-test' "$rendered"
grep -q '\\"type\\":\\"bridge\\"' "$rendered"
grep -q '\\"bridge\\":\\"br-vlan120\\"' "$rendered"
grep -q '\\"vlan\\":120' "$rendered"
grep -q '\\"mtu\\":1500' "$rendered"

printf '\n[5/5] Running Helm media regression tests when helm-unittest is installed...\n'
if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx unittest; then
  helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
  helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
else
  echo 'SKIP: helm-unittest plugin is not installed.'
  echo 'The Go tests and vm-network lint/render checks above still ran.'
fi

printf '\nPASS: HCI virtualization v1.6.2 repository checks completed.\n'
