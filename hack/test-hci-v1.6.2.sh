#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

printf '\n[1/12] Checking patch whitespace against v1.6.2...\n'
git diff --check v1.6.2...HEAD

printf '\n[2/12] Running tenant resolver unit tests...\n'
go test ./pkg/tenantresolver

printf '\n[3/12] Running tenant-scoped API option-provider tests...\n'
go test ./pkg/registry/core/option

printf '\n[4/12] Running HCI controller/admission/transaction Go tests...\n'
go test \
  ./pkg/vmnetworkadmission \
  ./pkg/networkfabric \
  ./pkg/networkfabriccontroller \
  ./cmd/vm-network-admission \
  ./cmd/network-fabric-controller

printf '\n[5/12] Linting external VM network chart...\n'
helm lint packages/apps/vm-network \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500

printf '\n[6/12] Rendering and validating external VM network NAD...\n'
rendered="$(mktemp)"
controller_rendered="$(mktemp)"
crd_rendered="$(mktemp)"
trap 'rm -f "$rendered" "$controller_rendered" "$crd_rendered"' EXIT
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

printf '\n[7/12] Validating native VMNetwork package/application wiring...\n'
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

printf '\n[8/12] Linting HCI system charts...\n'
helm lint packages/system/vm-network-admission --set image=example.invalid/vm-network-admission:test
helm lint packages/system/network-fabric-crd
helm lint packages/system/network-fabric-controller \
  --set networkFabricController.image=example.invalid/network-fabric-controller:test

printf '\n[9/12] Rendering NetworkFabric CRD/controller packages...\n'
helm template network-fabric-crd packages/system/network-fabric-crd > "$crd_rendered"
helm template network-fabric-controller packages/system/network-fabric-controller \
  --namespace cozy-network-fabric-controller \
  --set networkFabricController.image=example.invalid/network-fabric-controller:test > "$controller_rendered"

grep -q 'name: networkfabrics.infrastructure.cozystack.io' "$crd_rendered"
grep -q 'activeNode:' "$crd_rendered"
grep -q 'observedGeneration:' "$crd_rendered"
grep -q 'migration:' "$crd_rendered"
grep -q 'unavailableNodes:' "$crd_rendered"
grep -q 'kind: Deployment' "$controller_rendered"
grep -q 'name: network-fabric-controller' "$controller_rendered"
grep -q 'example.invalid/network-fabric-controller:test' "$controller_rendered"

printf '\n[10/12] Validating fail-closed admission and NetworkFabric platform wiring...\n'
admission_file='packages/system/vm-network-admission/templates/webhook.yaml'
fabric_source='packages/core/platform/sources/network-fabric.yaml'
fabric_bundle='packages/core/platform/templates/bundles/iaas-network-fabric.yaml'
fabric_crd='packages/system/network-fabric-crd/templates/crd.yaml'

grep -q 'failurePolicy: Fail' "$admission_file"
grep -q 'operations: \["CREATE", "UPDATE", "DELETE"\]' "$admission_file"
grep -q 'resources: \["vmnetworks"\]' "$admission_file"
grep -q 'name: cozystack.network-fabric' "$fabric_source"
grep -q 'path: system/network-fabric-crd' "$fabric_source"
grep -q 'path: system/network-fabric-controller' "$fabric_source"
grep -q 'cozystack.network-fabric" "talos"' "$fabric_bundle"
grep -q 'name: networkfabrics.infrastructure.cozystack.io' "$fabric_crd"
grep -q 'scope: Cluster' "$fabric_crd"
grep -q 'maxUnavailable:' "$fabric_crd"
grep -q 'activeNode:' "$fabric_crd"
grep -q 'lastAppliedRevision:' "$fabric_crd"
grep -q 'unavailableNodes:' "$fabric_crd"

printf '\n[11/12] Running Helm regression tests when helm-unittest is installed...\n'
if helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx unittest; then
  helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
  helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
else
  echo 'FAIL: helm-unittest plugin is required for the HCI validation gate.' >&2
  echo 'Install with: helm plugin install https://github.com/helm-unittest/helm-unittest.git' >&2
  exit 1
fi

printf '\n[12/12] Re-checking patch whitespace after generated/render validation...\n'
git diff --check v1.6.2...HEAD

printf '\nPASS: HCI virtualization v1.6.2 repository checks completed.\n'
