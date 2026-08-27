# HCI / Virtualization Next-Session Super Context

> READ THIS FILE FIRST IN THE NEXT CHATGPT/CODEX SESSION.
>
> This is the latest continuation note for the Cozystack HCI/virtualization work. It supplements the older `HCI_VIRTUALIZATION_SUPER_MASTER_CONTEXT.md`. When there is any conflict about current implementation state, trust the repository branch and this file, then inspect the latest commits.

## 1. Repository and branch source of truth

- Repository: `adaptgurus/cozystack`
- Exact upstream baseline for this work: `v1.6.2`
- Working branch: `feat/hci-virtualization-v1.6.2-test`
- Implementation HEAD immediately before this handoff note was created: `167f6f373c5c4d5a7a89f7b3429547cb60f239ca`
- Latest implementation commit at that point: `fix(hci): clear stale fabric capability labels`
- This documentation commit will advance branch HEAD again. Therefore ALWAYS re-fetch the branch before editing; do not hard-code the handoff SHA as the latest branch SHA.

### Mandatory next-session opening instruction

Use this exact instruction in the next session:

```text
Open adaptgurus/cozystack and use branch feat/hci-virtualization-v1.6.2-test.
Read HCI_VIRTUALIZATION_NEXT_SESSION_SUPER_CONTEXT.md first, then HCI_VIRTUALIZATION_SUPER_MASTER_CONTEXT.md, then fetch the actual current branch HEAD and latest commits. Continue coding directly in the same branch. Do not restart from conceptual discussion and do not create a new branch unless absolutely necessary.
```

## 2. Project objective

Build a production-grade, rebrandable on-prem virtualization/HCI experience on Cozystack 1.6.2 with traditional-hypervisor simplicity while preserving native Cozystack/Kubernetes architecture and upgradeability.

Core product model:

```text
Cozystack Tenant
    -> VMInstance / VMDisk / VMNetwork
    -> Cozystack Application API / HelmRelease reconciliation
    -> KubeVirt / CDI / Multus
    -> Kubernetes
    -> Talos Linux

Platform Infrastructure
    -> NetworkFabric
    -> NetworkFabric controller
    -> Talos adapter
    -> Talos VLANConfig / BridgeConfig
    -> verified Kubernetes node capability labels
    -> VM required node affinity
```

Architecture ownership must remain:

- Cozystack: cloud/application/tenant control plane.
- KubeVirt: VM/hypervisor API.
- CDI/VMDisk: disk/image/media transport.
- Multus/NAD: VM secondary network attachment.
- Talos: immutable node OS and physical VLAN/bridge authority.
- Tenant API/RBAC: security boundary.

Never put Talos host-network mutations inside tenant Helm charts.
Never derive tenant namespaces from names. `Tenant.status.namespace` remains authoritative.
Never break existing Cozystack VPC/default pod networking.

## 3. Functionality already implemented before the latest networking work

The existing master context contains the full history. Important implemented items include:

### VM optical/media foundation

- Multiple VMDisk attachments can be detected as optical via annotation:
  `vm-disk.cozystack.io/optical: "true"`.
- Optical VMDisk is rendered as KubeVirt CD-ROM:

```yaml
cdrom:
  bus: sata
  readonly: true
```

- Multiple CD/DVD devices are supported.
- Normal disks remain normal block disks.
- Attachment ordering is used for boot order.
- Incompatible optical bus selection is rejected.
- Duplicate disk/media attachment is rejected.
- Helm tests exist in `packages/apps/vm-instance/tests/optical_media_test.yaml`.

### TenantResolver

- `pkg/tenantresolver/resolver.go`
- `pkg/tenantresolver/resolver_test.go`
- Tenant hierarchy is resolved from real Tenant resources.
- Workload namespace comes from `Tenant.status.namespace`.
- No string parsing of tenant names is allowed.
- Parent/children/access checks and cycle/ambiguity handling were implemented.

### First-class VMNetwork

- `packages/apps/vm-network`
- `api/apps/v1alpha1/vmnetwork/types.go`
- `packages/system/vm-network-rd`
- native Cozystack `ApplicationDefinition`
- native OCI/component `PackageSource`
- IaaS bundle integration
- tenant-local bridge-CNI `NetworkAttachmentDefinition`
- VLAN kept as physical-fabric metadata; bridge CNI does NOT re-apply VLAN tagging.
- tenant-local NAD option provider remains the VM selector backend.
- VM default/pod networking is preserved while one or more external networks are added.
- duplicate/empty/missing tenant network references are rejected.

### VMNetwork deletion/use protection

Admission webhook blocks deletion or disruptive changes while any same-tenant VMInstance references the VMNetwork.

It checks both:

- `spec.values.networks`
- legacy `spec.values.subnets`

It is tenant scoped and fail closed when dependency lookup fails.

Disruptive fields include:

```text
bridge
vlan
mtu
promiscMode
macspoofchk
hairpinMode
fabricRef
fabricNetwork
```

Description-only updates remain allowed while attached.

## 4. Latest NetworkFabric implementation now in the branch

### NetworkFabric API

Cluster-scoped CRD:

```text
apiVersion: infrastructure.cozystack.io/v1alpha1
kind: NetworkFabric
```

Primary spec fields:

```yaml
spec:
  provider: talos
  nodeSelector: {}
  protectedManagementInterfaces:
    - eth0
  rollout:
    maxUnavailable: 1
  networks:
    - name: prod
      uplink: eth1
      vlan: 120
      vlanInterface: eth1.120
      bridge: br-vlan120
      mtu: 1500
      migration: false
```

Validation intentionally allows only one unavailable node for the first production-safe rollout implementation.

### Real NetworkFabric controller

Implemented in:

- `cmd/network-fabric-controller/main.go`
- `pkg/networkfabriccontroller/reconciler.go`
- `pkg/networkfabriccontroller/capabilities.go`
- `pkg/networkfabric/*`

The controller performs rolling one-node-at-a-time reconciliation.

Current Talos transaction model:

```text
Inspect live Talos node
    -> preflight protected management interfaces/uplinks
    -> build VLAN/bridge operations
    -> snapshot current machine config
    -> apply patch using Talos try mode
    -> verify Talos management connectivity and protected interfaces
    -> confirm the patch
    -> inspect resulting node links
    -> validate bridge/MTU capability
    -> update NetworkFabric status
```

On management verification or confirmation failure, rollback is attempted. Talos try-mode timeout is also intended as a second safety mechanism.

### Talos version target

This Cozystack branch contains Talos profile version `v1.13.6`.
The controller image packaging also uses Talosctl v1.13.6.

### Talos adapter

`pkg/networkfabric/talosctl_adapter.go`

Current adapter uses:

```text
talosctl get links -o json
talosctl get machineconfig v1alpha1 -o json
talosctl patch machineconfig --mode=try
talosctl patch machineconfig --mode=no-reboot
talosctl apply-config --mode=no-reboot   # rollback path
```

Talos patch renderer emits multi-document resources:

```yaml
apiVersion: v1alpha1
kind: VLANConfig
...
---
apiVersion: v1alpha1
kind: BridgeConfig
...
```

Tagged path:

```text
physical uplink -> VLANConfig -> BridgeConfig -> bridge CNI NAD -> VM
```

Native/untagged path:

```text
physical uplink -> BridgeConfig -> bridge CNI NAD -> VM
```

### Deployable controller package

Implemented package:

`packages/system/network-fabric-controller`

It now includes:

- Helm chart
- Makefile/image build
- controller Dockerfile
- Talosctl v1.13.6 in image
- Deployment
- ServiceAccount
- RBAC
- two replicas
- leader election
- anti-affinity
- non-root security context
- RuntimeDefault seccomp
- dropped Linux capabilities
- read-only root filesystem
- `/tmp` emptyDir for temporary transactional files
- Talos client config mounted from Secret
- readiness/liveness probes
- resource requests/limits

Default Talos Secret contract:

```text
Secret: network-fabric-talosconfig
key: talosconfig
namespace: cozy-network-fabric-controller
```

The chart DOES NOT generate this credential Secret.

Native package wiring now installs both:

```text
system/network-fabric-crd
system/network-fabric-controller
```

under `cozystack.network-fabric` variant `talos`.

## 5. Verified fabric capability -> VM placement chain

This is a major completed integration.

### Node capability publication

`pkg/networkfabriccontroller/capabilities.go`

A deterministic capability label fingerprints:

```text
NetworkFabric name
fabric network name
bridge
VLAN
MTU
```

Conceptual label:

```text
networkfabric.cozystack.io/cap-<16-hex>
```

The capability controller publishes that label only when the node is reported Ready for the current NetworkFabric generation.

Latest stale-label hardening at implementation HEAD `167f6f...`:

- labels are removed when a node no longer matches the NetworkFabric nodeSelector;
- labels are removed when the NetworkFabric is being deleted;
- labels are not retained from old verified topology.

### VMNetwork fabric binding

VMNetwork now has optional:

```yaml
spec:
  fabricRef: fabric-prod
  fabricNetwork: prod
```

Both fields must be set together.

Managed VMNetwork NAD receives annotations including:

```text
vm-network.cozystack.io/fabric-ref
vm-network.cozystack.io/fabric-network
vm-network.cozystack.io/capability-label
```

The capability fingerprint used by the VMNetwork chart matches the controller fingerprint inputs:

```text
fabricRef | fabricNetwork | bridge | vlan | mtu
```

### VM required node affinity

`packages/apps/vm-instance/templates/_hci_network_affinity.tpl`

When an attached NAD contains a fabric capability annotation, VM KubeVirt pod node affinity requires that capability label to exist on the destination node.

Therefore a VM using a production-managed VMNetwork cannot normally schedule or migrate onto a node where NetworkFabric has not published the verified capability.

Existing Windows node-placement policy is merged with the HCI network required affinity instead of being replaced.

## 6. Fabric-authoritative VMNetwork admission

Latest admission path now handles CREATE, UPDATE, DELETE.

Main implementation:

- `pkg/vmnetworkadmission/handler.go`
- `cmd/vm-network-admission/main.go`
- `packages/system/vm-network-admission`

For a VMNetwork with `fabricRef` + `fabricNetwork`, admission verifies:

1. NetworkFabric exists.
2. NetworkFabric status phase is `Ready`.
3. `status.observedGeneration == metadata.generation`.
4. referenced fabric network exists.
5. VMNetwork bridge exactly matches fabric network bridge.
6. VMNetwork VLAN exactly matches fabric VLAN.
7. VMNetwork MTU exactly matches fabric MTU.

Admission fails closed on API lookup errors.

Webhook operations now include:

```yaml
operations: ["CREATE", "UPDATE", "DELETE"]
```

RBAC grants read access to `networkfabrics` in addition to tenant HelmRelease dependency lookup.

Tests cover:

- incomplete fabric binding rejection;
- exact Ready fabric binding accepted;
- bridge/VLAN/MTU mismatch rejected;
- lookup failure fails closed;
- same-tenant VM usage blocks deletion/change;
- cross-tenant VM references are not surfaced through dependency lookup.

## 7. Important recent implementation commits

Recent commits that a new session should inspect first:

```text
57ae083a2761f0075e17a0e32623356713cdced7
feat(hci): deploy NetworkFabric controller

5eab885ef249825dcc65c1fb38ba43f30f75874f
feat(hci): publish verified fabric capabilities

fbc86b1949d1d39c13d3ee3e5c62b04d7cb0c2a4
feat(hci): enforce verified VM network placement

7eeafd0360db2f2a75361e98d9e5861d91a8248b
feat(hci): validate VMNetwork fabric bindings

42a680a81ea896ad1550a2ea50b1972ff1828929
feat(hci): wire NetworkFabric admission authority

a78a9a97f298b21a5ca97102804a7269ac1d9b22
feat(hci): authorize fabric-aware VMNetwork admission

73bfe29f764ae870dd81f1616c34191da0e50dd0
feat(hci): fail closed on VMNetwork creation

ed44b0db6856c01898c278ce1891c3a00df8ef72
test(hci): cover NetworkFabric-backed VMNetwork admission

167f6f373c5c4d5a7a89f7b3429547cb60f239ca
fix(hci): clear stale fabric capability labels
```

Earlier key commits remain documented in `HCI_VIRTUALIZATION_SUPER_MASTER_CONTEXT.md`.

## 8. PRIORITY 0: critical issue discovered at handoff

Do NOT call the networking implementation production-ready until this is fixed and tested.

### CRD status schema does not currently declare every field written by the controller

The current controller writes status including fields such as:

```text
status.activeNode
status.nodes[].observedGeneration
status.migration
```

But the current `packages/system/network-fabric-crd/templates/crd.yaml` status schema, at this handoff, does not declare all of them. Most critically it does not declare:

```text
status.nodes[].observedGeneration
```

The capability reconciler reads `status.nodes[].observedGeneration` and requires it to equal the NetworkFabric generation before publishing node capability labels.

Kubernetes structural CRD pruning may remove unknown status fields. If `status.nodes[].observedGeneration` is pruned, the capability reconciler can fail to recognize a node as verified/current, breaking the placement authority chain.

### FIRST CODE CHANGE IN NEXT SESSION

Update the NetworkFabric CRD status schema to exactly match every field written/read by `pkg/networkfabriccontroller/reconciler.go` and `capabilities.go`, including at minimum:

```yaml
status:
  observedGeneration: int64
  phase: string
  activeNode: string
  conditions: [...]
  nodes:
    - name: string
      phase: string
      observedGeneration: int64
      lastAppliedRevision: string
      managementReachable: boolean
      message: string
  migration:
    configured: boolean
    network: string
    bridge: string
    readyNodes: [string]
    unavailableNodes:
      - name: string
        reason: string
```

Then add tests/render checks proving these fields survive API schema validation/pruning.

## 9. Other production gaps to address next

These are real remaining tasks, not optional future ideas.

### A. Run/expand repository validation immediately after Priority 0

Current `hack/test-hci-v1.6.2.sh` predates the latest controller/capability work. Extend it to run at least:

```bash
go test ./pkg/networkfabric
go test ./pkg/networkfabriccontroller
go test ./pkg/vmnetworkadmission
go test ./cmd/network-fabric-controller
go test ./cmd/vm-network-admission
helm lint packages/system/network-fabric-crd
helm lint packages/system/network-fabric-controller --set networkFabricController.image=example.invalid/network-fabric-controller:test
helm lint packages/system/vm-network-admission --set image=example.invalid/vm-network-admission:test
helm lint packages/apps/vm-network --set bridge=br-vlan120 --set vlan=120 --set mtu=1500
```

Also run Helm unit tests for VMInstance and VMNetwork.

At this handoff GitHub reports no workflow runs and no combined status checks for implementation HEAD `167f6f...`. Do not represent CI as passed.

### B. Live Talos rollback validation

The rollback path currently snapshots `machineconfig` and may call:

```text
talosctl apply-config --mode=no-reboot
```

This MUST be proven against the exact Talos v1.13.6 lab nodes before production use.

Validate:

1. try-mode patch succeeds;
2. management path survives;
3. confirmation persists desired VLAN/bridge;
4. intentional failed post-check triggers rollback;
5. previous management and workload networking is restored;
6. node does not reboot unexpectedly;
7. controller recovers after process restart during a try transaction.

If the full-machine-config snapshot/restore semantics are not exact for Talos 1.13.6, replace the rollback implementation with a safer Talos-supported owned-resource strategy.

### C. Verify actual topology, not only interface existence

Current live capability verification primarily sees Talos link names/up/MTU.
Production validation should also prove:

- VLAN interface has the intended VLAN ID;
- VLAN parent is the intended physical uplink;
- bridge contains the intended parent/VLAN link;
- bridge MTU and member MTU are compatible;
- no unexpected bridge/IP migration affects protected management;
- bond/uplink topology is handled correctly where present.

Do not mark a node capable solely because a bridge with the correct name exists.

### D. NetworkFabric reconciliation must support removal/cleanup

Current plan primarily ensures desired VLAN/bridge resources exist.
Production lifecycle still needs explicit ownership and cleanup for:

- network removed from `NetworkFabric.spec.networks`;
- bridge/VLAN renamed;
- node removed from selector;
- NetworkFabric deleted.

Stale Kubernetes capability labels are now cleaned, but stale Talos VLAN/bridge documents must also be reconciled safely.

Use finalizers/ownership metadata as needed. Never remove unmanaged Talos interfaces.

### E. NetworkFabric deletion/reference safety

VMNetwork deletion/use protection exists, but platform NetworkFabric lifecycle also needs protection.

Before deleting a NetworkFabric or removing one of its networks, verify no VMNetwork still references:

```text
fabricRef
fabricNetwork
```

Fail closed and provide actionable errors.

### F. Controller status accuracy

Persist useful per-node details such as:

```text
observedGeneration
last successful verification time
last applied/previous revision identifier where safe
managementReachable
bridge/VLAN capability summary
failure reason
rollback state
```

Do not persist Talos secrets or full machine config in Kubernetes status/logs.

### G. Controller HA hardening

The chart has two replicas plus leader election. Add/validate as appropriate:

- PodDisruptionBudget;
- topology spread/anti-affinity behavior;
- priority class availability in target Cozystack profiles;
- Secret-not-found readiness behavior;
- metrics/alerts for failed rollouts, rollback failure, unreachable Talos nodes, stale generation, migration incompatibility.

### H. NetworkFabric GUI/API productization

The backend CRD/controller exists, but the user requirement is one GUI for routine physical VM networking.

Required end-state concept:

```text
Infrastructure -> Networking -> VM Networks / Physical Networks
```

Routine administrators should not manually write Talos YAML, VLANConfig, BridgeConfig, NAD, or Multus configuration.

Still pending:

- first-class admin GUI/resource workflow for NetworkFabric;
- discovery/selection of nodes/uplinks/bonds;
- safe bridge/VLAN form;
- health/rollout/rollback status in UI;
- selectable migration network;
- validation messages surfaced in GUI.

### I. VMNetwork GUI should not require duplicated free-text dataplane fields

Current VMNetwork can bind to `fabricRef`/`fabricNetwork`, and admission verifies bridge/VLAN/MTU exactly.
For VMware/Proxmox-style UX, improve the UI so platform-managed networks are selected from real NetworkFabric/network options and bridge/VLAN/MTU are derived or clearly read-only rather than requiring operators to copy matching values manually.

Preserve an explicitly supported legacy/direct-bridge path only if required for backward compatibility.

### J. Dedicated live-migration network integration

NetworkFabric supports one network with `migration: true` and reports migration compatibility, but verify whether Cozystack/KubeVirt is actually configured to use that bridge/network as the KubeVirt live-migration transport.

Do not confuse:

- attached VM external NIC placement safety; with
- KubeVirt's dedicated migration traffic network.

Inspect exact Cozystack v1.6.2 KubeVirt configuration and wire this only through the supported KubeVirt mechanism.

## 10. Required network E2E test matrix

Before calling physical VM networking production-ready, run real-cluster tests for:

```text
VM default network only
VM + one external VLAN
VM + multiple external VLANs
VM with VLAN + ISO
Windows VM + Windows ISO + VirtIO ISO + data disk + external VLAN
Linux VM + external VLAN
VM stop/start
VM restart
live migration between capable nodes
migration blocked/unschedulable when destination capability is absent
node capability label removal
NetworkFabric generation change
node removed from selector
NetworkFabric controller restart
Talos management connectivity failure during try mode
rollback success
rollback failure reporting
invalid VLAN
missing uplink
missing bridge
missing NAD
MTU mismatch
fabric bridge/VLAN/MTU mismatch
incomplete fabricRef/fabricNetwork
NetworkFabric not Ready
NetworkFabric stale observedGeneration
duplicate VM network attachment
tenant isolation
cross-tenant reference attempt
delete VMNetwork while attached
change VMNetwork dataplane while attached
remove fabric network while tenant VMNetwork references it
NetworkFabric deletion while referenced
```

## 11. Mandatory VM/media/Windows work still not complete

Do NOT declare the overall HCI project complete after networking.

Mandatory remaining product requirements from the original extension include:

### ISO/media library

- first-class ISO Library;
- global/platform ISO scope;
- tenant-private ISO scope;
- upload/import/catalog workflow;
- Linux installer ISO;
- Windows installer ISO;
- VirtIO driver ISO;
- rescue/appliance/custom ISO;
- generic mount/eject;
- distinguish eject media vs remove CD/DVD hardware vs delete ISO object;
- persistence across VM restart/reconcile/migration/upgrade;
- only enable live CD-ROM hotplug/eject if exact KubeVirt behavior supports it.

### Windows fresh install workflow

Required normal model:

```text
Hard Disk 0    empty system disk
CD/DVD 0       Windows installation ISO
CD/DVD 1       VirtIO drivers ISO
```

Definition of done remains:

```text
[ ] Windows profiles discovered dynamically
[ ] Windows ISO selectable
[ ] VirtIO ISO selectable
[ ] two optical drives validated E2E
[ ] empty system disk creation workflow
[ ] installer boots
[ ] VirtIO storage driver loads
[ ] target disk visible
[ ] installation completes
[ ] boot from installed disk
[ ] installer/driver media eject
[ ] optimized VirtIO disk path after driver readiness
[ ] VirtIO NIC
[ ] guest agent status
[ ] reboot persistence
[ ] live migration
[ ] tests
```

The low-level multiple optical attachment foundation exists, but the full user workflow above is not yet complete.

## 12. Existing behavior that must never regress

Next session must preserve:

- Cozystack Tenant isolation.
- Existing default/VPC networking.
- Tenant-local NAD selection.
- Windows scheduling preference/requirement semantics.
- VM optical media behavior already added.
- native Cozystack ApplicationDefinition/PackageSource model.
- Flux/Helm reconciliation.
- Talos as node network authority.
- VLAN tagging at the Talos physical-fabric layer, not duplicate bridge-CNI VLAN tagging.

## 13. Testing honesty rules

Use these labels consistently in discussion and documentation:

### Static validated

Only when source/render/schema inspection was actually performed.

### Unit tested

Only after the relevant `go test` / Helm unit suite actually ran successfully.

### Package/render tested

Only after Helm lint/template/package checks actually ran.

### Lab E2E validated

Only after deployment to real/nested Talos+Cozystack+KubeVirt nodes and executing the real test matrix.

### Production-ready

Only after all safety-critical tests, rollback, failure injection, upgrade/reconcile tests, monitoring, and documented operational procedures are complete.

At this handoff, do NOT claim the latest NetworkFabric changes have GitHub CI approval or live-cluster E2E validation. GitHub returned no workflow runs/status contexts for implementation HEAD `167f6f...`.

## 14. Immediate next-session execution order

Do these in order without reopening architectural debate:

1. Fetch actual branch HEAD and inspect commits after this handoff note.
2. Fix NetworkFabric CRD status schema pruning mismatch (Priority 0).
3. Add CRD/status tests proving `status.nodes[].observedGeneration`, `activeNode`, and migration status are schema-valid.
4. Extend `hack/test-hci-v1.6.2.sh` for `pkg/networkfabriccontroller`, controller command, controller Helm chart, new admission CREATE tests, and capability/affinity rendering.
5. Run full Go/Helm/static tests; fix every failure.
6. Audit Talos v1.13.6 patch/confirm/rollback commands against actual behavior.
7. Add safe stale Talos VLAN/bridge cleanup and NetworkFabric finalizer lifecycle.
8. Add NetworkFabric reference/deletion protection against VMNetwork usage.
9. Strengthen node topology verification beyond link-name existence.
10. Add PDB/metrics/failure observability and credential readiness checks.
11. Productize NetworkFabric and VMNetwork GUI option flows.
12. Wire/validate dedicated KubeVirt migration-network behavior.
13. Deploy branch to the lab and execute the full network E2E matrix.
14. Continue ISO Library + Windows two-ISO + mount/eject workflow.
15. Only after all mandatory sections pass, prepare merge/rebase strategy against Cozystack 1.6.2/release branch and upstream review.

## 15. Useful test/lab commands

```bash
git clone https://github.com/adaptgurus/cozystack.git
cd cozystack
git fetch origin
git checkout feat/hci-virtualization-v1.6.2-test
git pull --ff-only

git describe --tags --always
git log --oneline --decorate -30
git diff --check v1.6.2...HEAD
git diff --stat v1.6.2...HEAD

chmod +x hack/test-hci-v1.6.2.sh
./hack/test-hci-v1.6.2.sh
```

Direct packages to run even if the script has not yet been updated:

```bash
go test ./pkg/tenantresolver
go test ./pkg/registry/core/option
go test ./pkg/vmnetworkadmission
go test ./pkg/networkfabric
go test ./pkg/networkfabriccontroller
go test ./cmd/vm-network-admission
go test ./cmd/network-fabric-controller

helm lint packages/apps/vm-network \
  --set bridge=br-vlan120 \
  --set vlan=120 \
  --set mtu=1500

helm lint packages/system/vm-network-admission \
  --set image=example.invalid/vm-network-admission:test

helm lint packages/system/network-fabric-crd

helm lint packages/system/network-fabric-controller \
  --set networkFabricController.image=example.invalid/network-fabric-controller:test
```

When helm-unittest is installed:

```bash
helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
```

## 16. Emergency short continuation context

If the next session has very little context window, use this:

```text
Repo: adaptgurus/cozystack
Base: v1.6.2
Branch: feat/hci-virtualization-v1.6.2-test
Read HCI_VIRTUALIZATION_NEXT_SESSION_SUPER_CONTEXT.md first.

Latest implementation HEAD before handoff note: 167f6f373c5c4d5a7a89f7b3429547cb60f239ca.
Always fetch current branch HEAD because the handoff doc commit advances it.

Implemented:
- multiple optical VMDisk/CDROM support
- authoritative TenantResolver
- first-class tenant VMNetwork and tenant-local NAD selector
- delete/disruptive-update protection while VMNetwork is attached
- cluster NetworkFabric CRD
- real rolling Talos NetworkFabric controller
- Talos v1.13.6 VLANConfig/BridgeConfig renderer and try/confirm/rollback transaction
- deployable HA controller Helm package
- verified NetworkFabric node capability labels
- VMNetwork fabricRef/fabricNetwork binding
- VM required node affinity for verified network capabilities
- fabric-authoritative CREATE/UPDATE admission checking Ready generation + exact bridge/VLAN/MTU
- stale capability label cleanup

PRIORITY 0 BUG:
NetworkFabric controller writes status.nodes[].observedGeneration, status.activeNode and status.migration, but current CRD schema does not declare all of them. Kubernetes pruning can break capability publication. Fix CRD status schema first and test it.

Then:
- expand/run tests
- validate real Talos rollback
- verify VLAN parent/ID + bridge members, not only interface name/up/MTU
- implement stale Talos resource cleanup/finalizers
- protect NetworkFabric deletion while VMNetworks reference it
- add PDB/observability
- build GUI NetworkFabric workflow
- validate dedicated KubeVirt migration network
- run real cluster E2E
- continue ISO Library, generic mount/eject and Windows two-ISO workflow

Never parse tenant namespaces from names.
Never break default/VPC networking.
Never duplicate VLAN tagging in bridge CNI.
Never call production-ready without live failure/rollback/E2E validation.
```
