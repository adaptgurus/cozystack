#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

printf '\n[1/6] Checking patch whitespace against v1.6.2...\n'
git diff --check v1.6.2...HEAD

printf '\n[2/6] Running tenant resolver unit tests...\n'
go test ./pkg/tenantresolver

printf '\n[3/6] Linting external VM network chart...\n'
helm lint packages/apps/vm-network \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500

printf '\n[4/6] Rendering and validating external VM network NAD...\n'
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
grep -q '\\"mtu\\":1500' "$rendered"
grep -q '\\"ipam\\":{}' "$rendered"
if grep -q '\\"vlan\\":120' "$rendered"; then
  echo 'FAIL: bridge CNI is applying VLAN 120; VLAN tagging must remain at the Talos node-network layer.' >&2
  exit 1
fi
grep -q 'vm-network.cozystack.io/vlan: "120"' "$rendered"
grep -q 'vm-network.cozystack.io/vlan-owner: "talos-node-network"' "$rendered"

printf '\n[5/6] Validating native VMNetwork package/application wiring...\n'
source_file='packages/core/platform/sources/vm-network-application.yaml'
iaas_file='packages/core/platform/templates/bundles/iaas-vm-network.yaml'
rd_file='packages/system/vm-network-rd/cozyrds/vm-network.yaml'

grep -q '^apiVersion: cozystack.io/v1alpha1$' "$source_file"
grep -q '^  name: cozystack.vm-network-application$' "$source_file"
grep -q '^    - name: kubevirt$' "$source_file"
grep -q '^          path: apps/vm-network$' "$source_file"
grep -q '^          path: system/vm-network-rd$' "$source_file"
grep -q 'cozystack.vm-network-application" "kubevirt"' "$iaas_file"
grep -q 'name: cozystack-vm-network-application-kubevirt-vm-network' "$rd_file"
if grep -q '\["spec","ipam"\]' "$rd_file"; then
  echo 'FAIL: VMNetwork dashboard exposes ipam although external VLAN IPAM is intentionally guest/external-DHCP managed.' >&2
  exit 1
fi

printf '\n[6/6] Running Helm regression tests when helm-unittest is installed...\n'
if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx unittest; then
  helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
  helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
else
  echo 'SKIP: helm-unittest plugin is not installed.'
  echo 'Install helm-unittest to run the chart-level regression suites.'
fi

printf '\nPASS: HCI virtualization v1.6.2 repository checks completed.\n'
