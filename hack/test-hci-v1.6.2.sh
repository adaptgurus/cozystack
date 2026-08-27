#!/usr/bin/env bash
set -euo pipefail

baseline="${HCI_BASELINE:-v1.6.2}"
if ! git rev-parse -q --verify "refs/tags/${baseline}" >/dev/null; then
  echo "ERROR: required baseline tag ${baseline} is missing." >&2
  exit 1
fi

command -v go >/dev/null || { echo 'ERROR: go is required' >&2; exit 1; }
command -v helm >/dev/null || { echo 'ERROR: helm is required' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'ERROR: python3 is required' >&2; exit 1; }
if ! helm plugin list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx unittest; then
  echo 'ERROR: helm-unittest plugin is required; install it before running the HCI gate.' >&2
  exit 1
fi

rendered="$(mktemp)"
crd_rendered="$(mktemp)"
controller_rendered="$(mktemp)"
admission_rendered="$(mktemp)"
kubevirt_rendered="$(mktemp)"
schema_error="$(mktemp)"
trap 'rm -f "$rendered" "$crd_rendered" "$controller_rendered" "$admission_rendered" "$kubevirt_rendered" "$schema_error"' EXIT

expect_vmnetwork_schema_failure() {
  local expected="$1"
  shift
  : > "$schema_error"
  if helm template invalid-network packages/apps/vm-network --namespace tenant-test "$@" > /dev/null 2> "$schema_error"; then
    echo "FAIL: VMNetwork schema unexpectedly accepted invalid values: $*" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$schema_error"; then
    echo "FAIL: VMNetwork schema rejected values for an unexpected reason: $*" >&2
    cat "$schema_error" >&2
    exit 1
  fi
}

printf '\n[1/12] Checking patch whitespace against %s...\n' "$baseline"
git diff --check "${baseline}...HEAD"

printf '\n[2/12] Running tenant resolver unit tests...\n'
go test ./pkg/tenantresolver

printf '\n[3/12] Running tenant-scoped API option-provider tests...\n'
go test ./pkg/registry/core/option

printf '\n[4/12] Running HCI controller/admission/transaction Go tests...\n'
go test ./pkg/vmnetworkadmission ./pkg/networkfabric ./pkg/networkfabriccontroller ./cmd/vm-network-admission ./cmd/network-fabric-controller

printf '\n[5/12] Linting changed HCI application/media charts...\n'
helm lint packages/apps/vm-instance
helm lint packages/apps/vm-disk
helm lint packages/apps/vm-network \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500
helm lint packages/system/vm-default-images

printf '\n[6/12] Rendering and validating external VM network NAD...\n'
helm template prod-vlan120 packages/apps/vm-network \
  --namespace tenant-test \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500 > "$rendered"

grep -q 'kind: NetworkAttachmentDefinition' "$rendered"
grep -q 'name: prod-vlan120' "$rendered"
grep -q 'namespace: tenant-test' "$rendered"
grep -Fq '\"type\":\"bridge\"' "$rendered"
grep -Fq '\"bridge\":\"br-vlan120\"' "$rendered"
grep -Fq '\"mtu\":1500' "$rendered"
grep -Fq '\"ipam\":{}' "$rendered"
if grep -Fq '\"vlan\":120' "$rendered"; then
  echo 'FAIL: bridge CNI is applying VLAN 120; VLAN tagging must remain at the Talos node-network layer.' >&2
  exit 1
fi
grep -q 'vm-network.cozystack.io/vlan: "120"' "$rendered"
grep -q 'vm-network.cozystack.io/vlan-owner: "talos-node-network"' "$rendered"

# JSON-schema validation runs before templates in Helm. Exercise those invalid
# values here instead of pretending failedTemplate assertions can observe them.
expect_vmnetwork_schema_failure 'minLength: got 0, want 1' --set-string bridge='' --set vlan=120 --set mtu=1500
expect_vmnetwork_schema_failure 'maximum: got 4,095, want 4,094' --set bridge=br-test --set vlan=4095 --set mtu=1500
expect_vmnetwork_schema_failure 'maximum: got 10,000, want 9,216' --set bridge=br-test --set vlan=120 --set mtu=10000

printf '\n[7/12] Validating generated API schema parity and application wiring...\n'
source_file='packages/core/platform/sources/vm-network-application.yaml'
iaas_file='packages/core/platform/templates/bundles/iaas-vm-network.yaml'
rd_file='packages/system/vm-network-rd/cozyrds/vm-network.yaml'
vm_rd_file='packages/system/vm-instance-rd/cozyrds/vm-instance.yaml'

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
grep -q '"cdroms"' packages/apps/vm-instance/values.schema.json
grep -q '"cdroms"' "$vm_rd_file"
grep -Fq '["spec", "cdroms"]' "$vm_rd_file"

python3 - <<'PY'
import json
from pathlib import Path


def generated_schema(path: str):
    lines = Path(path).read_text().splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "openAPISchema: |-":
            if i + 1 >= len(lines):
                raise SystemExit(f"FAIL: {path} has empty openAPISchema")
            return json.loads(lines[i + 1].strip())
    raise SystemExit(f"FAIL: {path} has no openAPISchema block")

pairs = [
    ("packages/apps/vm-instance/values.schema.json", "packages/system/vm-instance-rd/cozyrds/vm-instance.yaml"),
    ("packages/apps/vm-disk/values.schema.json", "packages/system/vm-disk-rd/cozyrds/vm-disk.yaml"),
    ("packages/apps/vm-network/values.schema.json", "packages/system/vm-network-rd/cozyrds/vm-network.yaml"),
]

schemas = {}
for source, generated in pairs:
    src = json.loads(Path(source).read_text())
    dst = generated_schema(generated)
    if src != dst:
        raise SystemExit(f"FAIL: generated ApplicationDefinition schema drift: {source} != {generated}")
    schemas[source] = src

vm = schemas["packages/apps/vm-instance/values.schema.json"]
media_source = vm["properties"]["cdroms"]["items"]["properties"]["media"]["x-cozystack-options"]["source"]
if media_source != "opticaldisk":
    raise SystemExit(f"FAIL: VMInstance cdroms[].media provider is {media_source!r}, expected 'opticaldisk'")

disk = schemas["packages/apps/vm-disk/values.schema.json"]
source_rules = disk["properties"]["source"].get("x-kubernetes-validations", [])
if not any(rule.get("rule") == "self == oldSelf" for rule in source_rules):
    raise SystemExit("FAIL: VMDisk source is not immutable")
storage_rules = disk["properties"]["storageClass"].get("x-kubernetes-validations", [])
if not any(rule.get("rule") == "self == oldSelf" for rule in storage_rules):
    raise SystemExit("FAIL: VMDisk storageClass is not immutable")
PY

printf '\n[8/12] Linting HCI system charts...\n'
helm lint packages/system/vm-network-admission --set image=example.invalid/vm-network-admission:test
helm lint packages/system/network-fabric-crd
helm lint packages/system/network-fabric-controller \
  --set networkFabricController.image=example.invalid/network-fabric-controller:test
helm lint packages/system/kubevirt \
  --set-string _cluster.root-host=example.test

printf '\n[9/12] Rendering NetworkFabric CRD/controller and KubeVirt migration packages...\n'
helm template network-fabric-crd packages/system/network-fabric-crd > "$crd_rendered"
helm template network-fabric-controller packages/system/network-fabric-controller \
  --namespace cozy-network-fabric-controller \
  --set networkFabricController.image=example.invalid/network-fabric-controller:test > "$controller_rendered"
helm template kubevirt packages/system/kubevirt \
  --namespace cozy-kubevirt \
  --set-string _cluster.root-host=example.test \
  --set migrationNetwork=networkfabric-fabric-prod-migration > "$kubevirt_rendered"

grep -q 'name: networkfabrics.infrastructure.cozystack.io' "$crd_rendered"
grep -q 'activeNode:' "$crd_rendered"
grep -q 'observedGeneration:' "$crd_rendered"
grep -q 'migration:' "$crd_rendered"
grep -q 'unavailableNodes:' "$crd_rendered"
grep -q 'appliedNetworks:' "$crd_rendered"
grep -q 'lastVerifiedAt:' "$crd_rendered"
grep -q 'rollbackState:' "$crd_rendered"
grep -q 'kind: Deployment' "$controller_rendered"
grep -q 'name: network-fabric-controller' "$controller_rendered"
grep -q 'example.invalid/network-fabric-controller:test' "$controller_rendered"
grep -q 'kind: PodDisruptionBudget' "$controller_rendered"
grep -q 'minAvailable: 1' "$controller_rendered"
grep -q 'kind: Service' "$controller_rendered"
grep -q 'name: network-fabric-controller-metrics' "$controller_rendered"
grep -q 'topologySpreadConstraints:' "$controller_rendered"
grep -q 'migrations:' "$kubevirt_rendered"
grep -q 'network: "networkfabric-fabric-prod-migration"' "$kubevirt_rendered"
grep -q 'DeclarativeHotplugVolumes' "$kubevirt_rendered"
if grep -Eq '^[[:space:]]*- HotplugVolumes[[:space:]]*$' "$kubevirt_rendered"; then
  echo 'FAIL: deprecated KubeVirt HotplugVolumes feature gate is still enabled.' >&2
  exit 1
fi

printf '\n[10/12] Validating fail-closed VMNetwork admission and NetworkFabric platform wiring...\n'
helm template vm-network-admission packages/system/vm-network-admission \
  --namespace cozy-vm-network-admission \
  --set image=example.invalid/vm-network-admission:test > "$admission_rendered"

grep -q 'operations: \["CREATE", "UPDATE", "DELETE"\]' "$admission_rendered"
grep -q 'failurePolicy: Fail' "$admission_rendered"
grep -q 'resources: \["vmnetworks"\]' "$admission_rendered"
grep -q 'resources: \["networkfabrics"\]' packages/system/vm-network-admission/templates/rbac.yaml
grep -q 'resources: \["networkfabrics"\]' packages/system/network-fabric-controller/templates/rbac.yaml
grep -q 'resources: \["helmreleases"\]' packages/system/network-fabric-controller/templates/rbac.yaml

printf '\n[11/12] Running Helm unit tests for all changed HCI VM/media/network/KubeVirt charts...\n'
helm unittest packages/apps/vm-instance
helm unittest packages/apps/vm-disk
helm unittest packages/apps/vm-network
helm unittest packages/system/vm-default-images
helm unittest packages/system/kubevirt

printf '\n[12/12] Rechecking whitespace after all generators/tests...\n'
git diff --check "${baseline}...HEAD"

printf '\nHCI v1.6.2 repository gate PASSED.\n'
