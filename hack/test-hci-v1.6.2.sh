#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

printf '\n[1/10] Checking patch whitespace against v1.6.2...\n'
git diff --check v1.6.2...HEAD

printf '\n[2/10] Running tenant resolver unit tests...\n'
go test ./pkg/tenantresolver

printf '\n[3/10] Running tenant-scoped API option-provider tests...\n'
go test ./pkg/registry/core/option

printf '\n[4/10] Running VMNetwork admission and NetworkFabric transaction tests...\n'
go test ./pkg/vmnetworkadmission ./pkg/networkfabric ./cmd/vm-network-admission

printf '\n[5/10] Linting external VM network chart...\n'
helm lint packages/apps/vm-network \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500

printf '\n[6/10] Rendering and validating external VM network NAD...\n'
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
grep -q '\"type\":\"bridge\"' "$rendered"
grep -q '\"bridge\":\"br-vlan120\"' "$rendered"
grep -q '\"mtu\":1500' "$rendered"
grep -q '\"ipam\":{}' "$rendered"
if grep -q '\"vlan\":120' "$rendered"; then
  echo 'FAIL: bridge CNI is applying VLAN 120; VLAN tagging must remain at the Talos node-network layer.' >&2
  exit 1
fi
grep -q 'vm-network.cozystack.io/vlan: "120"' "$rendered"
grep -q 'vm-network.cozystack.io/vlan-owner: "talos-node-network"' "$rendered"

printf '\n[7/10] Validating native VMNetwork package/application wiring...\n'
source_file='packages/core/platform/sources/vm-network-application.yaml'
iaas_file='packages/core/platform/templates/bundles/iaas-vm-network.yaml'
rd_file='packages/system/vm-network-rd/cozyrds/vm-network.yaml'

grep -q '^apiVersion: cozystack.io/v1alpha1$' "$source_file"
grep -q '^  name: cozystack.vm-network-application$' "$source_file"
grep -q '^    - name: kubevirt$' "$source_file"
grep -q 'cozystack.cert-manager' "$source_file"
grep -q '^          path: apps/vm-network$' "$source_file"
grep -q '^          path: system/vm-network-rd$' "$source_file"
grep -q '^          path: system/vm-network-admission$' "$source_file"
grep -q 'cozystack.vm-network-application" "kubevirt"' "$iaas_file"
grep -q 'name: cozystack-vm-network-application-kubevirt-vm-network' "$rd_file"
if grep -q '\["spec","ipam"\]' "$rd_file"; then
  echo 'FAIL: VMNetwork dashboard exposes ipam although external VLAN IPAM is intentionally guest/external-DHCP managed.' >&2
  exit 1
fi

printf '\n[8/10] Linting VMNetwork admission and NetworkFabric CRD charts...\n'
helm lint packages/system/vm-network-admission --set image=example.invalid/vm-network-admission:test
helm lint packages/system/network-fabric-crd

printf '\n[9/10] Validating fail-closed admission and NetworkFabric platform wiring...\n'
admission_file='packages/system/vm-network-admission/templates/webhook.yaml'
fabric_source='packages/core/platform/sources/network-fabric.yaml'
fabric_bundle='packages/core/platform/templates/bundles/iaas-network-fabric.yaml'
fabric_crd='packages/system/network-fabric-crd/templates/crd.yaml'

grep -q 'failurePolicy: Fail' "$admission_file"
grep -q 'operations: \["UPDATE", "DELETE"\]' "$admission_file"
grep -q 'resources: \["vmnetworks"\]' "$admission_file"
grep -q 'name: cozystack.network-fabric' "$fabric_source"
grep -q 'path: system/network-fabric-crd' "$fabric_source"
grep -q 'cozystack.network-fabric" "talos"' "$fabric_bundle"
grep -q 'name: networkfabrics.infrastructure.cozystack.io' "$fabric_crd"
grep -q 'scope: Cluster' "$fabric_crd"
grep -q 'maxUnavailable:' "$fabric_crd"

printf '\n[10/10] Running Helm regression tests when helm-unittest is installed...\n'
if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx unittest; then
  helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
  helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
else
  echo 'SKIP: helm-unittest plugin is not installed.'
  echo 'Install helm-unittest to run the chart-level regression suites.'
fi

printf '\nPASS: HCI virtualization v1.6.2 repository checks completed.\n'
