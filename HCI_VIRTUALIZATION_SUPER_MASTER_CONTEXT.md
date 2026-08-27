# Cozystack v1.6.2 HCI / Virtualization Super Master Context

> **Persistent repository handoff for ChatGPT/Codex and human contributors.**
>
> **Do not restart the design from scratch. Read this file first, inspect the actual branch code, and continue implementation directly in this repository.**

Last updated: 2026-08-27

---

## 1. Repository, branch, and baseline — immutable working rule

Repository:

```text
adaptgurus/cozystack
```

Target upstream/base release:

```text
v1.6.2
```

Development/testing branch:

```text
feat/hci-virtualization-v1.6.2-test
```

Important historical decision:

- `release-1.6` was already **11 commits ahead of `v1.6.2`** when this work was started.
- Therefore this project intentionally uses a clean branch created directly from **`v1.6.2`**.
- Do not rebase the project onto `release-1.6` merely for convenience.
- Do not create additional experimental branches unless absolutely necessary.
- Continue making implementation and test changes directly on `feat/hci-virtualization-v1.6.2-test`.

Primary delivery goal:

> Build, test, and harden enterprise virtualization/HCI enhancements in the user's Cozystack fork, validate them in a real Cozystack lab, and only after successful validation prepare them for possible upstream merge against the `v1.6.2` baseline.

This is **not a demo project**. Treat it as production-oriented virtualization engineering.

---

## 2. Architectural intent

The target is a unified on-prem virtualization platform with the operational simplicity expected from VMware, Proxmox, or Harvester while remaining correctly implemented on native Cozystack/Kubernetes ownership boundaries.

Use this ownership model:

```text
Cozystack Dashboard/API
        ↓
apps.cozystack.io
        ↓
VMInstance / VMDisk / Tenant / other native application resources
        ↓
Cozystack operator / charts / ApplicationDefinition / PackageSource
        ↓
KubeVirt / CDI / Multus / storage integrations
        ↓
Kubernetes
        ↓
Talos Linux
```

Do **not** treat Cozystack as generic Kubernetes and add random CRDs without first checking whether the required concept is already modeled by Cozystack.

Before creating a new API/resource, inspect whether the function can be provided through existing:

```text
VMInstance
VMDisk
Tenant
Platform configuration
ApplicationDefinition
PackageSource
Multus package
KubeVirt package
LINSTOR / CSI
Cozystack API
```

Custom APIs should orchestrate genuinely missing concepts rather than duplicate existing ownership.

Fundamental platform boundaries:

```text
Cozystack       = cloud management plane
KubeVirt        = VM / hypervisor API
CDI             = VM image and media transport
LINSTOR / CSI   = storage data plane
Multus          = VM secondary network attachment
Talos           = immutable node OS and node-network configuration authority
Tenant          = authoritative security / workload namespace boundary
```

Our extension layer should provide:

```text
orchestration
safe workflows
validation
capability discovery
policy
observability
GUI integration
```

It must not unnecessarily replace those underlying systems.

---

## 3. Enterprise virtualization requirements

The final platform must support or correctly integrate the following areas:

- Linux VMs.
- Windows VMs.
- Multiple VM disks.
- Multiple ISO/CD-ROM attachments.
- Windows installation media plus VirtIO driver ISO simultaneously.
- Physical/external VLAN-backed VM networks.
- Existing Cozystack VPC/default networking without regression.
- Multus secondary networking.
- KubeVirt VM lifecycle.
- Tenant isolation.
- VM HA.
- Live migration.
- Migration-network compatibility validation.
- VM restart and stop/start persistence.
- Production-grade validation/error reporting.
- Air-gap usability.
- Future SAN/enterprise storage integration.
- HCI storage integration.
- Backup/restore integration.
- Upgrade-safe architecture.

The GUI should eventually make operations such as these feel like traditional hypervisor administration:

```text
Create Windows VM
Attach two or more ISOs
Mount/eject media
Create and attach data disks
Resize disks
Change CPU/RAM
Attach VLAN-backed VM NICs
Create new physical VM networks
Map host NIC/bond/bridge/VLAN fabric
Connect NFS/SAN
Create HCI storage
Backup
Restore
Migrate
```

But the implementation must respect native ownership boundaries.

---

## 4. Mandatory VM hardware / media direction

A VM hardware model should conceptually expose:

```text
VM: windows-prod-01

Hardware
────────────────────────────────────────
CPU                    8 vCPU
Memory                 32 GiB

Hard Disk 0            100 GiB
Hard Disk 1            500 GiB

CD/DVD Drive 0         Windows Server 2025.iso
CD/DVD Drive 1         virtio-win.iso

Network Device 0       Production VLAN 120
Network Device 1       Backup VLAN 300

GPU                     None

[Add Hardware]
```

`Add Hardware` should eventually support capability-gated operations such as:

```text
Hard Disk
Existing Disk
CD/DVD Drive
Network Interface
GPU
Other supported host devices
```

Multiple optical drives are mandatory for Windows installation workflows.

### ISO model

Prefer Cozystack/CDI-backed storage. Tenant-consumable ISO media should use the native VMDisk/CDI path where possible, including optical semantics rather than creating a parallel storage system.

The long-term GUI should provide a first-class:

```text
Virtualization → ISO Library
```

with global approved media and private tenant media scopes.

Important semantics:

- Ejecting ISO media is not the same as deleting the ISO.
- Removing CD/DVD hardware is not the same as ejecting media.
- Persistent optical configuration must survive VM restart, controller restart, node migration, reconciliation, and extension upgrades unless explicitly configured as temporary media.
- Windows workflows should support Windows ISO + VirtIO ISO + empty system disk.

---

## 5. Mandatory tenant / namespace model

Never derive tenant namespaces from tenant names or naming conventions.

Authoritative tenant placement must use Cozystack Tenant objects, especially:

```text
Tenant.status.namespace
```

The central tenant resolver must be used for resource placement and authorization.

Never expose an unrestricted raw `metadata.namespace` text box to normal tenant users.

Tenant-scoped resources such as:

```text
VMInstance
VMDisk
private ISO
tenant backup Plan
tenant VMNetwork attachment
```

must be created in the workload namespace resolved from the authenticated/authorized Tenant context.

Cross-namespace security rule:

> A tenant user must not be able to escape the tenant boundary by directly supplying another namespace.

Global resources should remain platform-owned. Avoid invalid cross-namespace owner references; prefer explicit references, labels, annotations, and status references where needed.

---

## 6. Mandatory physical VM networking direction

The long-term user workflow is:

```text
Infrastructure
→ Networking
→ VM Networks
→ Create VM Network
```

Routine users should not need to manually understand or create:

```text
Talos VLANConfig
Talos BridgeConfig
NetworkAttachmentDefinition
Multus
KubeVirt secondary network objects
```

External VLAN-backed VM networking should conceptually follow:

```text
Physical NIC(s)
      |
Linux Bond / LACP
      |
Linux Bridge
      |
optional VLAN tag
      |
Multus NetworkAttachmentDefinition
      |
KubeVirt interface
      |
VM NIC
```

Do not assume bridge names are globally identical across virtualization nodes without validating the node-network architecture.

The selected bridge must be compatible with every KubeVirt-capable node on which a VM may run or migrate, or scheduling/migration must be constrained safely.

Preserve Cozystack's existing VPC/default networking. External VM networks are additive; they must not replace or break the current default/VPC path.

### Upgrade-safety rule for Talos networking

Do not spread Talos-specific orchestration throughout unrelated Cozystack UI/application code.

Prefer a narrow compatibility architecture for future physical-network automation, conceptually:

```text
network-fabric-controller
Talos adapter
Cozystack adapter
Tenant resolver
KubeVirt adapter
```

This allows future Cozystack/Talos versions to be supported by changing narrow compatibility layers rather than maintaining an invasive fork.

---

## 7. Code that was already implemented before the current session

### 7.1 VM optical media / ISO attachment support

Modified:

```text
packages/apps/vm-instance/templates/vm.yaml
```

Implemented behavior:

- Reads attached `DataVolume` objects.
- Detects optical media using:

```yaml
metadata:
  annotations:
    vm-disk.cozystack.io/optical: "true"
```

- Optical media renders as KubeVirt CD-ROM hardware:

```yaml
cdrom:
  bus: sata
  readonly: true
```

- Multiple ISO/CD-ROM devices are supported.
- Normal disks continue using standard KubeVirt disk rendering.
- Boot order follows attachment order.
- Optical media rejects an incompatible bus such as `virtio`.
- Duplicate disk/media attachments are rejected.

Tests:

```text
packages/apps/vm-instance/tests/optical_media_test.yaml
```

Coverage includes:

- two optical disks simultaneously;
- normal virtio disk mixed with optical media;
- SATA/read-only rendering;
- boot ordering;
- invalid optical-media bus rejection;
- duplicate disk attachment rejection.

### 7.2 Authoritative TenantResolver

Added:

```text
pkg/tenantresolver/resolver.go
pkg/tenantresolver/resolver_test.go
```

Implemented:

- Resolve Tenant object.
- Resolve workload namespace from `Tenant.status.namespace`.
- Resolve parent tenant.
- List direct child tenants.
- Detect ambiguous hierarchy.
- Detect hierarchy cycles.
- SubjectAccessReview support.
- Tenant-object access checks.
- Resource access through tenant hierarchy.
- Parent/inherited access checks.

Primary GVR:

```text
apps.cozystack.io/v1alpha1
resource: tenants
```

Unit tests cover namespace resolution, missing status namespace, hierarchy traversal, ambiguous parent hierarchy, cycles, and inherited authorization.

### 7.3 Initial external VM network Helm application

Added:

```text
packages/apps/vm-network/
```

Initial files included:

```text
packages/apps/vm-network/Chart.yaml
packages/apps/vm-network/values.yaml
packages/apps/vm-network/templates/network-attachment-definition.yaml
packages/apps/vm-network/tests/vm_network_test.yaml
```

It creates a tenant-scoped Multus:

```text
NetworkAttachmentDefinition
```

using bridge CNI.

Main configuration:

```yaml
bridge: ""
vlan: 0
mtu: 0
description: ""
promiscMode: false
macspoofchk: false
hairpinMode: false
ipam: {}
```

Validation expectations:

- `bridge` mandatory.
- VLAN `0-4094`.
- MTU `0` or `576-9216`.
- No guest IP assignment by default.
- Guest addressing may come from external DHCP or guest configuration.

Example:

```yaml
bridge: br-vlan120
vlan: 120
mtu: 1500
```

Tenant NAD example:

```text
tenant-test/prod-vlan120
```

Existing `vm-instance` networking already maps tenant network names to Multus network references in the VM tenant namespace. The new VMNetwork application is intended to provide those NADs.

### 7.4 One-command repository validation script

Added:

```text
hack/test-hci-v1.6.2.sh
```

It was designed to run checks such as:

```bash
git diff --check v1.6.2...HEAD
go test ./pkg/tenantresolver
helm lint packages/apps/vm-network --set bridge=br-vlan120 --set vlan=120 --set mtu=1500
helm template prod-vlan120 packages/apps/vm-network --namespace tenant-test --set bridge=br-vlan120 --set vlan=120 --set mtu=1500
```

and, when Helm unittest is available:

```bash
helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
```

---

## 8. Discoveries and implementation completed in the 2026-08-27 continuation session

The repository was inspected directly on `feat/hci-virtualization-v1.6.2-test` rather than relying on assumptions.

### 8.1 First-class application registration mechanism confirmed

For Cozystack `v1.6.2`, first-class application resources use a combination of:

```text
packages/apps/<app>/
api/apps/v1alpha1/<app>/types.go
packages/system/<app>-rd/
packages/core/platform/sources/<app>-application.yaml
```

Application schemas are generated through the app `Makefile` / `cozyvalues-gen`, and resource definitions use `ApplicationDefinition` plus package-source wiring.

This means merely adding `packages/apps/vm-network/Chart.yaml` is insufficient for a native dashboard/API resource.

### 8.2 First-class VMNetwork registration committed

Commit:

```text
69e865715caead6f7024d80d60bade80371e544a
feat(hci): register VM networks as first-class applications
```

Added/updated:

```text
packages/apps/vm-network/values.schema.json
packages/apps/vm-network/Makefile
packages/apps/vm-network/README.md
packages/apps/vm-network/logos/network.svg
api/apps/v1alpha1/vmnetwork/types.go
packages/core/platform/sources/vm-network-application.yaml
packages/system/vm-network-rd/Chart.yaml
packages/system/vm-network-rd/Makefile
packages/system/vm-network-rd/cozyrds/vm-network.yaml
packages/system/vm-network-rd/templates/cozyrd.yaml
```

VMNetwork is modeled as a first-class Cozystack application resource with:

```text
kind: VMNetwork
singular: vmnetwork
plural: vmnetworks
```

Dashboard metadata places it in IaaS and provides bridge/VLAN/MTU/description and bridge-CNI related fields.

Existing VPC/default VM networking was intentionally not replaced.

### 8.3 VM-side tenant network validation committed

Commit:

```text
a09ff0ed75a11aff73bd5c013cd93ba350ba5377
test(hci): validate tenant VM network attachments
```

Added:

```text
packages/apps/vm-instance/templates/validate-networks.yaml
packages/apps/vm-instance/tests/network_attachment_test.yaml
packages/apps/vm-instance/tests/network_validation_test.yaml
```

Behavior added:

- Reject empty network attachment names.
- Reject duplicate VM network attachments.
- Validate that a referenced `NetworkAttachmentDefinition` exists in the VM's own tenant namespace.
- Preserve default pod/VPC network while attaching one or multiple external Multus networks.

This is an important tenant-isolation guard: the VM cannot simply reference a network in an arbitrary external namespace through the normal tenant network field.

### 8.4 Current branch head at this handoff

At the time this context file was created, the branch head was:

```text
a09ff0ed75a11aff73bd5c013cd93ba350ba5377
```

Before making new changes, always re-read the actual branch head because a later session may have advanced it.

---

## 9. Current continuation point — resume here

Do not restart architecture discussion.

The immediate implementation investigation was checking the **final system-install/platform wiring** for the new first-class VMNetwork resource.

Already established:

- VMNetwork application chart exists.
- VMNetwork schema/API type exists.
- VMNetwork `ApplicationDefinition` / `*-rd` chart exists.
- VMNetwork `PackageSource` exists.
- VM form already uses the native schema option source:

```text
x-cozystack-options.source: "network"
```

- VM template already understands multiple tenant Multus networks.
- VM-side duplicate, empty-name, and tenant-local NAD validation has been added.

### Next engineering tasks

1. Inspect `packages/core/platform/templates/apps.yaml`, `sources.yaml`, bundle templates, and related platform install logic to verify that the new `vm-network-application` source and `vm-network-rd` chart are actually installed/discovered in the same way as established resources such as `vm-instance`, `vm-disk`, and `virtualprivatecloud`.
2. Confirm whether any hard-coded application/resource-definition lists still require explicit VMNetwork registration.
3. Verify what backend/dashboard logic populates `x-cozystack-options.source: "network"` and ensure first-class `VMNetwork` resources are exposed through that existing selector without breaking VPC/default networking.
4. Validate generated schema/types against the exact generator output conventions used by `v1.6.2` and correct any hand-generated differences if necessary.
5. Run branch-level validation and fix every failure rather than assuming generated artifacts are valid.
6. Add deletion-safety behavior for VMNetwork objects that are still attached to VMs, using native ownership/reference patterns where possible.
7. Design/implement node bridge and migration compatibility validation. Helm templates alone cannot prove a Linux bridge exists on every eligible KubeVirt node; this requires live/admission/controller-level capability validation.
8. Add network health/status and migration preflight checks.
9. Continue toward GUI-driven NetworkFabric/Talos bridge/VLAN orchestration through an upgrade-safe compatibility/controller layer rather than invasive Talos logic spread across Cozystack.
10. Continue the mandatory ISO Library / Windows two-ISO / mount-eject workflow until the full definition of done is satisfied.

---

## 10. Required VM/network regression matrix

Do not declare networking complete until the following are tested where applicable:

```text
VM default network only
VM + one external VLAN
VM + multiple external VLANs
VM with VLAN + ISO
VM with Windows ISO + VirtIO ISO + data disk + external VLAN
Linux VM + external VLAN
live migration behavior
VM restart
VM stop/start
deleting network while attached
duplicate network attachment
invalid VLAN
missing host bridge
missing NAD
MTU mismatch
tenant isolation
cross-tenant reference attempt
bridge absent on migration destination node
```

Graceful validation/error coverage is required for at least:

```text
bridge not present on VM node
invalid VLAN
NAD missing
duplicate interface/network
incompatible configuration
MTU mismatch
migration target lacks network capability
```

Do not claim a static Helm chart verifies host bridge existence. That must be validated using cluster/node state through an appropriate controller/admission/preflight mechanism.

---

## 11. Windows definition of done

Windows support is not complete until all applicable items are validated:

```text
[ ] Windows profiles discovered dynamically
[ ] Windows ISO can be selected
[ ] VirtIO ISO can be selected
[ ] two optical drives supported
[ ] empty system disk created
[ ] Windows installer boots
[ ] VirtIO storage driver can be loaded
[ ] target system disk becomes visible
[ ] installation completes
[ ] VM boots from installed system disk
[ ] media can be ejected without deleting ISO
[ ] optimized disk path can be used after driver readiness
[ ] VirtIO NIC works
[ ] guest agent status works where installed
[ ] reboot persistence works
[ ] live migration behavior validated
[ ] tests pass
```

The normal fresh Windows workflow should conceptually be:

```text
Hard Disk 0        empty system disk
CD/DVD Drive 0     Windows installation ISO
CD/DVD Drive 1     VirtIO driver ISO
```

Do not simplify the product back to a single `iso` field.

---

## 12. Physical-network definition of done

The network subsystem is not complete until applicable items are validated:

```text
[ ] physical NIC/bond model discovered or configured safely
[ ] Talos bridge configuration can be created declaratively
[ ] Talos VLAN configuration can be created declaratively
[ ] rolling application works
[ ] rollback works
[ ] node management connectivity remains safe
[ ] Multus validated
[ ] bridge CNI validated
[ ] NetworkFabric exists or equivalent orchestration is implemented
[ ] VMNetwork exists as a first-class Cozystack resource
[ ] tenant assignment works
[ ] tenant NADs reconcile automatically
[ ] tenant users can attach permitted networks
[ ] unauthorized tenants cannot attach other tenant networks
[ ] migration preflight checks network compatibility
[ ] network health monitoring works
[ ] network deletion protection works
[ ] tests pass
```

Mandatory functionality must not be moved indefinitely into vague "future work":

```text
Windows two-ISO installation
generic ISO mount/eject
tenant-safe namespace resolution
GUI VLAN creation
Talos bridge creation
Talos VLAN creation
automatic tenant NAD creation
VM VLAN attachment
network health
network rollback
migration-network validation
```

---

## 13. Testing and validation rules

For every integration decision:

1. Inspect the actual Cozystack `v1.6.2` code and the current branch implementation.
2. Do not rely only on memory or generic Kubernetes patterns.
3. Make direct repository changes.
4. Add tests next to the implementation.
5. Keep the branch testable at every meaningful checkpoint.
6. Preserve existing Cozystack behavior unless the feature explicitly requires change.
7. Do not mark unexecuted live-cluster checks as passed.
8. Distinguish static validation, unit tests, Helm rendering tests, and real cluster E2E tests.

Baseline repository checks include:

```bash
git diff --check v1.6.2...HEAD
go test ./pkg/tenantresolver
helm lint packages/apps/vm-network --set bridge=br-vlan120 --set vlan=120 --set mtu=1500
helm template prod-vlan120 packages/apps/vm-network --namespace tenant-test --set bridge=br-vlan120 --set vlan=120 --set mtu=1500
```

When available:

```bash
helm unittest packages/apps/vm-instance -f 'tests/*_test.yaml'
helm unittest packages/apps/vm-network -f 'tests/*_test.yaml'
```

Also run:

```bash
chmod +x hack/test-hci-v1.6.2.sh
./hack/test-hci-v1.6.2.sh
```

Expand this script as new production checks are implemented.

---

## 14. Test-machine continuation commands

When the branch is ready for lab testing:

```bash
git clone https://github.com/adaptgurus/cozystack.git
cd cozystack
git fetch origin
git checkout feat/hci-virtualization-v1.6.2-test
git pull
```

Verify branch/baseline:

```bash
git describe --tags --always
git log --oneline --decorate -20
git diff --stat v1.6.2...HEAD
```

Run repository validation:

```bash
chmod +x hack/test-hci-v1.6.2.sh
./hack/test-hci-v1.6.2.sh
```

If Helm unittest is missing:

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest.git
./hack/test-hci-v1.6.2.sh
```

Once implementation is sufficiently complete, provide exact commands for deploying this branch into the Cozystack test cluster and perform an end-to-end VM validation rather than stopping at local render tests.

---

## 15. Rules for the next ChatGPT/Codex session

**Do not restart from conceptual discussion.**

The next session must:

1. Open `adaptgurus/cozystack`.
2. Checkout/read `feat/hci-virtualization-v1.6.2-test`.
3. Read this file first.
4. Read the latest branch commits because this document may lag later commits.
5. Compare against `v1.6.2` when evaluating regressions.
6. Inspect the actual implementation before each integration decision.
7. Continue coding directly in the repository.
8. Add tests and validation with each feature.
9. Do not provide only code snippets in chat when repository writes are possible.
10. Preserve tenant isolation and existing VPC/default networking.
11. Preserve future Cozystack/Talos upgradeability; avoid unnecessary invasive forks.
12. Do not declare the project complete while mandatory media, Windows, VLAN/bridge, health, rollback, migration-validation, storage, or live-cluster verification requirements remain unfinished.

The highest-priority continuation point at the time of this handoff is:

> **Finish verifying the native Cozystack platform installation/discovery path for first-class `VMNetwork`, then validate the existing `network` option source/UI integration and continue production-grade VM physical-network lifecycle implementation.**

---

## 16. Short context for emergency continuation

If a future chat has very little context window, use this minimum summary:

```text
Repo: adaptgurus/cozystack
Base: v1.6.2
Branch: feat/hci-virtualization-v1.6.2-test

Goal: production-grade Cozystack HCI/virtualization improvements, not demo code.

Already implemented:
- multiple optical/ISO VM attachments with tests
- authoritative TenantResolver using Tenant.status.namespace
- tenant-scoped bridge-CNI VMNetwork chart
- VMNetwork first-class API/ApplicationDefinition/PackageSource/RD registration
- tenant-local NAD existence validation
- duplicate/empty VM network attachment validation
- VM default/VPC network preserved with one or multiple external Multus networks

Important commits:
- 69e865715caead6f7024d80d60bade80371e544a first-class VMNetwork registration
- a09ff0ed75a11aff73bd5c013cd93ba350ba5377 tenant VM network validation/tests

Continue by checking platform apps/sources/bundle install wiring, UI `network` option-source behavior, generated-schema correctness, deletion safety, node bridge/migration compatibility, network health, Talos NetworkFabric orchestration, ISO Library, Windows two-ISO workflow, and full E2E tests.

Never derive tenant namespaces from names.
Never break existing VPC/default networking.
Never claim host bridge/migration compatibility without live node/controller validation.
Make changes directly in this branch and test them.
```
