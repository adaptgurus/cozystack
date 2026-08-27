# COZYSTACK HCI / VIRTUALIZATION — PRODUCTION CONTINUATION SUPER MASTER CONTEXT

## 0. PURPOSE — READ THIS FIRST IN THE NEXT CHAT

This file is an EXECUTION CONTRACT for continuing production work on the existing Cozystack HCI virtualization branch.

Do not restart from conceptual discussion.
Do not create another branch.
Do not discard or rewrite completed work without evidence.
Do not declare production-ready because CI is green.
Do not inflate a percentage.

Repository:

```text
adaptgurus/cozystack
```

Base:

```text
v1.6.2
```

Branch:

```text
feat/hci-virtualization-v1.6.2-test
```

Known pre-context HEAD after the VM-template capability-gating changes:

```text
0131393d2337511a064914032a66991d636ec2dd
```

THIS HEAD IS ONLY A CHECKPOINT. THE NEXT SESSION MUST FETCH THE ACTUAL BRANCH HEAD BEFORE DOING ANYTHING.

Read in this order:

1. `HCI_VIRTUALIZATION_PRODUCTION_CONTINUATION_SUPER_MASTER_CONTEXT.md` — this file.
2. `COZYSTACK_HCI_ULTIMATE_NEXT_SESSION_SUPER_MASTER_CONTEXT(1).md` or the latest ultimate super-master context supplied by the user.
3. `PRODUCTION VM MEDIA + ISO + WINDOWS + TALOS VLAN + TENANT NETWORK MANAGEMENT EXTENSION(4).md`.
4. `HCI_VIRTUALIZATION_NEXT_SESSION_SUPER_CONTEXT.md` in the repository.
5. `HCI_VIRTUALIZATION_SUPER_MASTER_CONTEXT.md` in the repository.
6. Actual changed source, generated APIs, charts, tests, docs, and exact shipped dependency APIs.

Always establish truth with:

```bash
git fetch --all --tags --prune
git checkout feat/hci-virtualization-v1.6.2-test
git status
git rev-parse HEAD
git log --oneline --decorate -60
git describe --tags --always
git diff --stat v1.6.2...HEAD
git diff --check v1.6.2...HEAD
```

Fetch latest GitHub Actions HCI gate status before changing code.

---

# 1. PRODUCT TARGET

Build a production-grade on-prem virtualization/HCI experience on Cozystack with the usability expected from VMware, Proxmox and Harvester, while preserving native ownership boundaries:

```text
Cozystack Tenant
  -> VMInstance / VMDisk
  -> KubeVirt / CDI

Cozystack Tenant
  -> VMNetwork
  -> Multus / tenant-local NAD

Platform Infrastructure
  -> NetworkFabric
  -> Talos VLAN / Bridge

Platform image/media catalog
  -> CDI DataVolumes / PVCs in approved platform namespace

StorageProfile
  -> LINSTOR / CSI
```

The extension is an orchestration/product layer. It must not replace or bypass Cozystack, KubeVirt, CDI, Multus, Talos, Tenant or LINSTOR/CSI ownership.

---

# 2. ABSOLUTE VALIDATION LABELS

Use these labels precisely:

```text
Static validated
Unit tested
Package/render tested
CI validated
Lab E2E validated
Failure/rollback validated
Upgrade/reconcile validated
Production-ready
```

`Production-ready` is forbidden until all safety-critical exact-version real-cluster tests pass.

Green GitHub Actions is not equivalent to real Talos/KubeVirt/CDI/Multus/Windows E2E.

If lab is unavailable, the strongest allowed conclusion is:

```text
Repository validated; production certification pending lab E2E.
```

99%+ means at minimum:

```text
0 known P0 defects
0 known P1 defects
0 mandatory features intentionally deferred
all generated artifacts synchronized
all mandatory Go tests green
all mandatory Helm tests green
all changed chart lint/render checks green
all CRD/schema/pruning tests green
all security/RBAC tests green
all lifecycle/finalizer/reference tests green
all media/Windows tests green
all template/clone tests green
all migration/network tests green
clean diff/generator state
no unexplained TODO/FIXME/501 in mandatory scope
real lab failure/rollback/E2E green
```

---

# 3. CURRENT VERIFIED REPOSITORY STATE BEFORE THIS CONTINUATION FILE

The HCI gate was green at:

```text
d5aa7c71f1223dae1963b798c3d09205cfdc0e6f
GitHub Actions HCI v1.6.2 Gate run: 33099628181
Result: SUCCESS
```

After that green checkpoint, native VM-template foundation work was added. Re-fetch CI for the latest HEAD; do not assume it is green.

Recent template-foundation commits include:

```text
d6a1d90d9726d5ec70ab178b3f25fe71e35aa816  feat(hci): enable KubeVirt VM template foundation
14a5306c4b1a9e32089b98f2ec9d48b15342b050  test(hci): pin native VM template gates
1d75240eb0c152d004839ad7d7ece5c477d1c29a  feat(hci): make native VM templates capability-gated
b0374b06abbe4199ab2c36e0cb7a8e7cba20dc29  fix(hci): capability-gate alpha KubeVirt templates
0131393d2337511a064914032a66991d636ec2dd  test(hci): cover VM template capability rollback
```

The KubeVirt chart now has:

```yaml
vmTemplates:
  enabled: true
```

When enabled it configures:

```text
Snapshot
Template
virtTemplateDeployment.enabled=true
```

When disabled it removes the alpha template capability while preserving the stable base feature-gate set.

This is deliberate because Cozystack v1.6 ships KubeVirt v1.8.4 and the native KubeVirt Template API is Alpha in v1.8.x.

---

# 4. COMPLETED / SUBSTANTIALLY HARDENED WORK — DO NOT RESTART IT

Already implemented or substantially hardened on this branch:

- VMInstance optical media schema drift corrected.
- VMDisk source/storageClass immutability corrected in source/generated schema.
- Expanded HCI gate includes vm-disk, vm-default-images, vm-instance, vm-network and kubevirt coverage.
- NetworkFabric status structural-pruning tests strengthened.
- Durable Talos transaction fields added to CRD schema.
- Official Talos v1.13.6 machinery client integrated for production network operations.
- Production runtime moved away from `talosctl` shell execution.
- Talos controller image no longer needs the talosctl executable.
- Ownership-safe inverse rollback; never restore a whole MachineConfig.
- TRY -> verify -> confirm transaction semantics.
- Durable crash/restart checkpoints and recovery logic.
- Explicit node selector required for NetworkFabric.
- Kubernetes Node Ready preflight.
- Control-plane network mutation refused by default unless explicitly allowed.
- Management-interface protection.
- Uplink existence/up-state/MTU checks.
- Managed bridge/VLAN topology verification.
- Unmanaged link adoption protection.
- Cross-NetworkFabric ownership conflict protection.
- VMNetwork admission failure closes on errors.
- Admission request size/type/identity validation hardened.
- VMNetwork webhook TLS/timeouts hardened.
- NetworkFabric tenant grants introduced.
- Tenant authorization uses authoritative `Tenant.status.namespace` resolution.
- Privileged controllers run non-root with read-only root filesystems, dropped capabilities and seccomp.
- Leader-election RBAC narrowed.
- Multiple persistent CD/DVD slots exist in VMInstance.
- Optical disk provider exists.
- Platform ISO provider exists.

Re-audit all of these, but do not rewrite them from scratch unless a failing test or concrete defect requires it.

---

# 5. CURRENT GOLDEN IMAGE / ISO REALITY — IMPORTANT ANSWER TO USER REQUIREMENT

## 5.1 Golden Images already exist

The branch already has a global Golden Image collection at:

```text
packages/system/vm-default-images/values.yaml
```

It currently defines 16 default Linux cloud images, approximately 320 GiB total at their default 20 GiB allocations.

Examples include Ubuntu, Rocky Linux, AlmaLinux, Debian, CentOS Stream, openSUSE and Alpine.

Golden images are stored as CDI DataVolumes/PVCs in:

```text
cozy-public
```

with internal names:

```text
vm-default-images-<image-name>
```

Tenant VMDisk supports:

```yaml
source:
  image:
    name: <golden-image-name>
```

Do not replace this working model.

## 5.2 A global ISO Library foundation already exists

The same `vm-default-images` package now has:

```yaml
isos: []
```

and:

```text
packages/system/vm-default-images/templates/iso-dv.yaml
```

Each global ISO is stored in `cozy-public` as:

```text
vm-default-isos-<iso-name>
```

The platform ISO source supports exactly one of:

```text
HTTP(S) import
CDI upload target
```

A Windows installer ISO is not shipped by default for licensing reasons.

The library can contain:

```text
Linux installers
Windows installers supplied by the administrator
VirtIO driver ISO
rescue media
firmware/update ISO
appliance ISO
custom media
```

## 5.3 Tenant ISO upload/import foundation exists

`VMDisk` supports source types including:

```text
image
disk
iso
http
upload
```

`source.iso` clones an approved platform ISO into a tenant-local VMDisk.

`source.upload` creates a CDI upload target.

`spec.optical: true` marks tenant optical media.

## 5.4 ISO attachment exists declaratively

VMInstance supports:

```yaml
cdroms:
- name: installer
  media: windows-server-2025-iso
- name: drivers
  media: virtio-win-iso
```

The VM chart validates that media points to optical VMDisk objects and renders read-only SATA CD-ROMs.

Clearing `cdroms[].media` means ejecting media while keeping the CD/DVD drive slot.

Therefore the accurate answer is:

```text
Golden Image backend: YES, already present.
Global ISO backend: YES, present.
CDI upload target support: YES, present.
Tenant optical VMDisk: YES.
Multiple ISO/CD-ROM attachment: YES declaratively.
Fully productized browser upload wizard: NOT YET COMPLETE.
Fully productized Add Hardware / Mount / Eject UI: NOT YET COMPLETE.
Secure upload token/progress/checksum/SSRF lifecycle: NOT YET COMPLETE.
```

Do not confuse API/backend support with finished UX.

---

# 6. NEW MANDATORY FEATURE — PROXMOX-CLASS VM TEMPLATE LIFECYCLE

This is now mandatory scope.

The user wants a Proxmox-like experience:

```text
VM list
  -> right-click VM
  -> Convert to Template
```

and:

```text
Virtualization
  -> Template Library
```

with reusable templates that can create new VMs without sharing writable disks.

Also support:

```text
VM -> Clone / Copy to Template
```

so an administrator can create a template while retaining the source VM.

## 6.1 Required UI structure

Target navigation:

```text
Virtualization
  - Virtual Machines
  - Templates
  - ISO Library
  - Golden Images
  - Disks
  - Networks
```

An alternate combined library page is acceptable:

```text
Virtualization -> Image & Template Library
  Tabs:
    ISO Images
    Golden Disk Images
    VM Templates
```

but all three concepts must remain semantically distinct.

## 6.2 Right-click VM actions

Required actions:

```text
Start
Stop
Shutdown
Restart
Console
Clone
Create Template Copy
Convert to Template
Snapshot
Backup
Migrate
Delete
```

`Convert to Template` is not a label flip.

It must capture both configuration and persistent disk state safely.

## 6.3 Template source preflight

Before creating a production template:

1. Resolve user-visible VMInstance to the actual KubeVirt VM.
2. Verify the VM belongs to the authoritative Tenant workload namespace.
3. Production default: source VM must be fully stopped; fail if a VMI exists.
4. Online application-consistent template creation may be added only when guest-agent/fs-freeze capability is proven and tested.
5. Every persistent disk must be snapshot/clone capable.
6. Detect excluded/unsupported volumes.
7. Reject hostDisk/ephemeral/unsafe local storage unless an explicit supported backend exists.
8. By default eject/exclude installer/driver ISO media from reusable templates.
9. Preserve required data disks.
10. Verify Network/VMNetwork references are valid or parameterizable.
11. Strip runtime identity that must not be duplicated: MAC, SMBIOS serial/UUID where appropriate, cloud-init instance identity, transient IP state and one-time credentials.
12. Secret-bearing config must not be copied into a global template without explicit safe parameterization.
13. Windows global templates require Sysprep/generalization evidence before promotion.
14. Linux global templates should support cloud-init/generalization policy.
15. Never create a template if snapshot readiness cannot be proven.

## 6.4 Exact KubeVirt v1.8.4 capability

Cozystack v1.6 ships KubeVirt v1.8.4.

KubeVirt v1.8.4 contains native:

```text
template.kubevirt.io/v1alpha1 VirtualMachineTemplate
template.kubevirt.io/v1alpha1 VirtualMachineTemplateRequest
```

and `virtctl template create` uses:

```yaml
apiVersion: template.kubevirt.io/v1alpha1
kind: VirtualMachineTemplateRequest
spec:
  virtualMachineRef:
    namespace: <source-namespace>
    name: <kubevirt-vm-name>
  templateName: <template-name>
```

It requires KubeVirt feature gates:

```text
Snapshot
Template
```

The branch now capability-gates these through `vmTemplates.enabled`.

IMPORTANT:

The native Template API is Alpha in KubeVirt v1.8.x.

Do not expose raw KubeVirt Template processing directly as the permanent Cozystack product API if it bypasses VMInstance/VMDisk/Tenant ownership.

Create/retain a narrow adapter boundary such as:

```text
VMTemplateBackend
  DiscoverCapabilities()
  ValidateSource()
  CreateTemplate()
  VerifyTemplate()
  CloneTemplate()
  DeleteTemplate()
  PromoteTemplate()
```

Possible exact-version backend implementations:

```text
KubeVirtTemplateBackend   # native template.kubevirt.io on v1.8.4 when enabled/proven
SnapshotCloneBackend      # snapshot.kubevirt.io/v1beta1 + clone.kubevirt.io/v1beta1 fallback
ReadOnlyTemplateBackend   # when required APIs/storage snapshots are not available
```

The product-facing behavior must remain stable even if KubeVirt template API changes in v1.9+.

## 6.5 Preserve Cozystack ownership when cloning

This is critical.

A Clone-from-Template workflow MUST NOT leave the tenant with only raw KubeVirt VM/PVC resources that bypass Cozystack.

End state must remain represented through Cozystack ownership:

```text
VMInstance
VMDisk(s)
VMNetwork references
```

The backend may use KubeVirt Snapshot/Clone/Template internally, but after provisioning the resulting VM must be a normal manageable Cozystack VMInstance with independent VMDisk lifecycle.

No two normal VMs may share the same writable template disk/PVC.

## 6.6 Template immutability and versioning

Treat a ready template version as immutable.

Changing a template's captured storage/configuration creates a new version/revision.

Recommended metadata:

```text
Name
Display Name
Description
Scope: Tenant | Global
Owner Tenant
OS Family
OS Name
OS Version
Architecture
Created From VM
Created At
Template Revision
Disk Count
Total Provisioned Size
StorageClass/Profile
Guest Agent Detected
Generalized/Sysprep State
Networks
Firmware/UEFI/TPM/SecureBoot capability
Cloud-init capable
Status
Last Verified
```

## 6.7 Tenant vs global templates

Support:

```text
Tenant Template
Global / Platform Template
```

Tenant templates remain isolated to the resolved tenant namespace.

Global templates are promoted only by platform administrators through a privileged controller/workflow.

Do not grant tenants cross-namespace create/read of storage objects merely to consume global templates.

Use a safe clone/promotion controller.

## 6.8 Convert vs Copy semantics

`Create Template Copy`:

```text
source VM stays
new template is created
```

`Convert to Template`:

```text
1. stop/preflight source
2. create template
3. verify template is Ready and independently recoverable
4. only then remove/retire the source VM from the VM inventory
5. never delete source disks before template storage capture is proven
6. rollback conversion if template creation fails
```

Never make conversion destructive before the new template is verified.

## 6.9 Clone from template

Wizard:

```text
Template
  -> Clone / Create VM
```

Fields:

```text
VM name
Tenant/Project
CPU / memory / instance type override
System disk size expansion
Storage profile/class
Network(s)
Cloud-init / hostname / SSH keys
Windows customization / computer name where supported
Start after clone
```

Must generate fresh identities and independent storage.

---

# 7. GOLDEN IMAGE + ISO + TEMPLATE LIBRARY PRODUCTIZATION

The user wants the familiar Proxmox idea of a central place for reusable media and templates.

Do not collapse all resources into one Kubernetes object.

Use one GUI library with distinct backend types:

```text
ISO Library
  -> optical CDI/VMDisk media

Golden Images
  -> reusable base disk CDI DataVolumes

Templates
  -> captured VM configuration + independent template storage/snapshots
```

## 7.1 ISO Library required actions

```text
Upload ISO
Import from URL
Clone platform ISO to tenant
View checksum
View size/import status
Attach to VM
Eject from VM
Replace mounted media
Delete private ISO
Publish/promote global ISO (admin)
```

## 7.2 Browser upload workflow

Current `source.upload` only establishes a CDI upload target. Finish the real browser workflow:

1. User chooses ISO file.
2. API creates approved target VMDisk/DataVolume.
3. API obtains time-limited CDI upload token through the supported API.
4. Browser uploads to the supported CDI UploadProxy path.
5. Enforce upload size limit before and during transfer.
6. Show bytes/progress/status.
7. Compute/verify SHA-256 where supported by the product pipeline.
8. Abort/cleanup incomplete uploads safely.
9. Do not expose broad Kubernetes/CDI credentials to the browser.
10. Do not place upload tokens in logs/status.

## 7.3 URL import security

Mandatory:

```text
HTTPS by default
reject embedded URL credentials
allow-list policy for enterprise environments
DNS resolution validation
redirect revalidation
SSRF protection
reject loopback
reject link-local
reject cloud metadata addresses
private network policy configurable but deny by default for tenant imports
DNS rebinding defense where practical
TLS validation
size limit
content-type/media sanity checks
checksum verification
timeout/retry bounds
redacted logging
```

The current direct CDI `source.http.url` path is not enough for the final product security model.

## 7.4 Attach global ISO

The browser must not require a tenant to know `cozy-public` PVC names.

Expected flow:

```text
Add Hardware -> CD/DVD -> ISO Library -> select global ISO
```

Product controller/API:

```text
create/reuse tenant-local optical VMDisk from source.iso
then update VMInstance.cdroms[].media
```

This preserves tenant isolation.

## 7.5 Eject/remove/delete distinction

```text
Eject Media
  -> clear cdrom.media
  -> keep CD/DVD device

Remove CD/DVD Drive
  -> remove slot from VMInstance.cdroms[]

Delete Private ISO
  -> delete tenant VMDisk only when no VM references it

Delete Global ISO
  -> admin-only and block when tenant clones/import operations require protection
```

Never conflate these actions.

---

# 8. WINDOWS TWO-ISO WORKFLOW REMAINS MANDATORY

Wizard default for Windows Server installation:

```text
Empty system disk
Windows installer ISO
VirtIO driver ISO
UEFI firmware
Windows instance preference
VirtIO/SCSI storage recommendation
VirtIO network
```

Hardware view example:

```text
Hard Disk 0     100 GiB
CD/DVD 0        Windows Server 2025.iso
CD/DVD 1        virtio-win.iso
NIC 0           Production VLAN 120
```

After installation provide a post-install cleanup action:

```text
Eject Windows ISO
Eject VirtIO ISO
Verify system disk boot priority
Verify VirtIO storage
Verify VirtIO network
Verify guest agent
```

For Windows templates:

```text
Sysprep/generalization is mandatory before global promotion.
Do not clone machine SID/host identity/one-time secrets blindly.
```

---

# 9. NETWORKFABRIC WORK STILL REQUIRED BEFORE PRODUCTION CERTIFICATION

Continue the previous mandatory scope:

- stale owned Talos VLAN/bridge cleanup;
- finalizers and dead-node policy;
- reference protection across tenant VMNetworks;
- tenant grant revocation protection while VMNetworks are attached;
- dry-run and impact preview;
- node/uplink discovery;
- heterogeneous per-node uplink mapping;
- physical switch trunk warning;
- exact health/status/metrics;
- KubeVirt migration transport proof;
- no unmanaged Talos adoption/deletion;
- no duplicate VLAN tagging in bridge CNI;
- management/default-route/etcd/storage protection.

---

# 10. LAB THAT THE USER WILL PROVIDE

The user plans to provide one Windows machine/VM acting as the Hyper-V lab host/management point.

Inside it create three Hyper-V VMs.

Each lab node:

```text
vCPU: 10
RAM: 32 GiB fixed (no Dynamic Memory)
OS/install disk: 260 GiB
extra/data disk: 200 GiB
```

Total guest allocation:

```text
30 vCPU
96 GiB RAM
780 GiB primary disks
600 GiB secondary disks
```

Do not assume the physical/nested host has enough headroom; preflight host CPU/RAM/storage first.

## 10.1 Nested virtualization prerequisites

Because KubeVirt needs hardware virtualization inside the Talos nodes, Hyper-V guests must expose virtualization extensions.

PowerShell intent:

```powershell
Set-VMProcessor -VMName <node> -ExposeVirtualizationExtensions $true
```

Also validate:

```text
static/fixed memory
sufficient vCPU
MAC spoofing / nested networking requirements on relevant vNICs
VLAN/trunk capability of the Hyper-V vSwitch
MTU
management reachability
internet/air-gap repository policy
```

Do not proceed with KubeVirt lab certification if `/dev/kvm` / virtualization acceleration is unavailable in Talos nodes.

## 10.2 Storage capacity warning

The default Golden Image collection is approximately 320 GiB before replicas.

The planned lab has only 200 GiB secondary storage per node.

Therefore DO NOT enable all 16 default images in the small certification lab.

Use a trimmed catalog, for example:

```text
1 Linux golden image
Windows installer ISO
VirtIO ISO
1 rescue/test ISO
1 Windows template after installation
```

Preserve adequate free space for snapshots/clones/migration tests.

---

# 11. GITHUB ACTIONS LAB DEPLOYMENT

The user wants deployment and testing driven by GitHub Actions.

A GitHub-hosted runner normally cannot reach a private Hyper-V/Talos lab network.

Use a self-hosted runner on the Windows management/Hyper-V side or another explicitly routed management host.

Recommended labels:

```text
self-hosted
windows
hyperv
cozystack-hci-lab
```

Create a protected GitHub Environment such as:

```text
hci-lab
```

Use environment/repository secrets only for minimum required bootstrap credentials.

Never print:

```text
Talosconfig
Kubeconfig
client private keys
upload tokens
Windows product keys
other secrets
```

to Actions logs.

Materialize credentials into temporary files with restrictive ACLs and delete them in an `always()` cleanup step.

## 11.1 Lab workflow stages

Manual `workflow_dispatch` is preferred for destructive lab runs.

Stages:

```text
1. Host preflight
2. Hyper-V network/vSwitch preflight
3. Create/validate 3 VMs
4. Attach 260 GiB + 200 GiB disks
5. Expose nested virtualization
6. Apply required MAC spoof/VLAN settings
7. Boot/install Talos exact target version
8. Bootstrap Cozystack exact branch/baseline
9. Verify exact component versions
10. Deploy HCI branch packages
11. Run repository smoke tests
12. Run NetworkFabric E2E
13. Run rollback/failure matrix
14. Run VMNetwork/tenant isolation
15. Run ISO upload/import/mount/eject
16. Install Windows with two ISOs
17. Convert Windows VM to template
18. Clone template into new VM
19. Verify independent disks/identity/network
20. Run live migration
21. Reboot nodes/controllers
22. Run reconcile/upgrade/rollback checks
23. Collect diagnostics/artifacts
24. Cleanup only test resources explicitly marked safe to delete
```

Do not have CI automatically destroy the whole lab after a failed safety test; preserve evidence unless cleanup is explicitly safe.

---

# 12. EXACT TEMPLATE LAB TESTS

Mandatory before calling Templates production-ready:

## 12.1 Linux template

```text
Create Linux VM from Golden Image
boot
customize VM
shutdown
Create Template Copy
wait Ready
clone template to VM A
clone template to VM B
prove disks/PVCs are independent
prove MAC/SMBIOS identity is unique
boot both simultaneously
modify A
prove B/template unchanged
restart controller
clone again
```

## 12.2 Convert semantics

```text
Create VM
shutdown
right-click / API Convert to Template
inject template creation failure -> source VM remains intact
retry -> template Ready
only then source leaves VM inventory according to conversion policy
clone template -> new VM boots
```

## 12.3 Windows template

```text
Install Windows Server 2022 or 2025 using Windows + VirtIO ISOs
install guest agent
patch/update as desired
Sysprep/generalize
shutdown
convert/copy to template
clone to new VM
boot OOBE/specialize successfully
new computer identity
VirtIO storage/network functional
no installer ISO attached
no copied one-time secret/product key unless policy explicitly allows it
```

## 12.4 Storage failures

Test:

```text
no VolumeSnapshotClass
unsupported StorageClass
snapshot timeout
snapshot partial/excluded volume
clone failure
out-of-space
controller restart during snapshot
controller restart during clone
template delete while clone active
source VM delete during template request
template delete with dependent clones
```

Fail closed with actionable status.

---

# 13. EXACT ISO / MEDIA LAB TESTS

Test:

```text
platform admin upload ISO
tenant private upload ISO
HTTPS URL import
malicious/forbidden URL
checksum mismatch
interrupted upload
size limit
retry/cancel
clone global ISO to tenant optical VMDisk
attach to empty CD/DVD slot
replace media
eject media
reboot VM
persistent attachment after reconciliation
remove drive without deleting ISO
prevent deleting ISO while referenced
multiple CD/DVD drives
Windows installer + VirtIO simultaneously
```

---

# 14. EXACT NETWORK / TALOS FAILURE MATRIX

Talos target:

```text
v1.13.6
```

Test at minimum:

```text
valid VLAN + bridge rollout
wrong VLAN
wrong bridge parent
uplink down
wrong/unsupported MTU
management interface selected
control-plane node selected without explicit opt-in
unmanaged same-name bridge
unmanaged same-name VLAN
cross-fabric ownership collision
Talos API timeout
TRY apply success then controller crash
crash after Verify before Confirm
crash after Confirm before status write
Confirm failure
rollback failure
node reboot after confirmed config
stale owned VLAN cleanup
stale owned bridge cleanup
node removed from selector
fabric deletion
fabric deletion while VMNetwork referenced
grant revocation while tenant VMNetwork referenced
```

Never continue rolling to the next node after an unsafe failure.

---

# 15. MIGRATION CERTIFICATION

Exact shipped KubeVirt is v1.8.4 unless the lab proves otherwise.

Verify the live cluster rather than relying only on source assumptions.

Test:

```text
migration NAD exists
all eligible source/destination nodes have physical topology
IPAM/routability proven
MTU consistent
KubeVirt CR points to intended migration network
start VM
live migrate
capture migration pod network attachments
prove data path used intended migration network
repeat with tenant VLAN VM
repeat with Windows VM
failure when destination lacks network
failure when migration network unavailable
```

---

# 16. SECURITY / RBAC TEMPLATE REQUIREMENTS

Tenants must never receive:

```text
Talos credentials
cluster-admin
cross-tenant PVC access
cross-tenant VM snapshot access
platform ISO write privileges
arbitrary cozy-public write access
```

Global template promotion is admin-only.

Tenant template creation can only read the tenant's own source VM/disks through the authoritative resolved workload namespace.

Template cloning must enforce destination Tenant authorization server-side.

Do not trust browser-provided raw namespace strings.

Audit/template status must not contain secrets or full VM cloud-init secret data.

Add policy for sensitive template content:

```text
cloud-init passwords
SSH private keys
Windows unattend credentials
product/license keys
embedded API tokens
static machine identity
TPM state where cloning is unsafe
```

Global promotion should refuse or require explicit administrative override when sensitive material is detected or cannot be proven safe.

---

# 17. NEXT-SESSION EXECUTION ORDER

Do this in order.

## Phase A — establish current truth

1. Fetch actual branch HEAD.
2. Read this context and all mandatory previous contexts.
3. Fetch latest HCI workflow run.
4. If latest gate is red, fix every failure before new feature expansion.
5. Inventory current template feature-gate commits.

## Phase B — finish repository security gaps already known

6. Finish VMDisk source structural exclusivity.
7. Finish secure URL-import validation/SSRF control architecture.
8. Finish NetworkFabric tenant-grant revocation protection.
9. Re-run HCI gate.

## Phase C — VM Template product layer

10. Inspect exact KubeVirt v1.8.4 `template.kubevirt.io/v1alpha1`, `snapshot.kubevirt.io/v1beta1`, and `clone.kubevirt.io/v1beta1` APIs from the exact tag.
11. Design a thin Cozystack VMTemplate product abstraction that preserves VMInstance/VMDisk/Tenant ownership.
12. Add template capability discovery.
13. Add source VM preflight.
14. Add stopped-VM production default.
15. Add storage snapshot-capability validation.
16. Add optical-media exclusion/eject policy.
17. Add sensitive-data/generalization checks.
18. Add tenant template create/copy.
19. Add safe Convert-to-Template transaction.
20. Add Template Library resource/view metadata.
21. Add Clone-from-Template flow that creates independent VMDisk(s) + VMInstance.
22. Add global promotion workflow, admin-only.
23. Add deletion/reference protection.
24. Add template revisions/immutability.
25. Add unit/render/admission/lifecycle tests.
26. Add template tests to mandatory HCI gate.

## Phase D — UI productization

27. Add `Virtualization -> Templates` or Template tab in Image & Template Library.
28. Add VM row/context-menu action `Convert to Template`.
29. Add `Create Template Copy`.
30. Add `Clone` / `Create VM from Template`.
31. Add Template details/status/revision/size/OS/owner.
32. Ensure normal tenant UI never exposes raw namespaces or KubeVirt internals.

If the dashboard UI source lives in a separate repository/package, identify the exact shipped UI source and make the change there only after confirming repository/branch ownership. Do not fake a right-click feature by documenting a button that does not exist.

## Phase E — ISO / Golden Image productization

33. Finish browser CDI upload workflow.
34. Finish secure URL import.
35. Add checksum/progress/retry/cancel.
36. Add platform + tenant ISO Library UI.
37. Add one-click `Attach to VM`.
38. Add Hardware -> CD/DVD -> Library/Upload/URL/Empty.
39. Add eject/remove/delete protection.
40. Keep existing Golden Images backend and productize its management UI.

## Phase F — remaining network/migration/Windows work

41. Complete NetworkFabric UI/uplink discovery.
42. Complete tenant assignment/revocation.
43. Complete migration network validation.
44. Complete Windows two-ISO wizard and post-install cleanup.

## Phase G — lab + production certification

45. Configure self-hosted Windows/Hyper-V GitHub runner.
46. Build/validate 3-node lab.
47. Run exact Talos failure/rollback matrix.
48. Run Template E2E.
49. Run ISO/media E2E.
50. Run Windows install + Windows template clone E2E.
51. Run migration E2E.
52. Run reboot/reconcile tests.
53. Run upgrade/rollback tests.
54. Run broader regression.
55. Re-fetch HEAD/CI.
56. Produce final traceability matrix.
57. Only then decide Production-ready YES/NO.

---

# 18. PRODUCTION GATE FOR THE USER'S 99% REQUIREMENT

Do not use a subjective 99% number.

The release gate is:

```text
P0 defects                              0
P1 defects                              0
Mandatory deferred features             0
Current branch HCI gate                 PASS
Broader Go tests                         PASS
Changed Helm tests                       PASS
Lint/render                              PASS
Generated API/AppDefinition parity       PASS
CRD structural/pruning                   PASS
Security/RBAC                            PASS
NetworkFabric ownership/finalizers       PASS
Tenant isolation                         PASS
Talos v1.13.6 failure/rollback            PASS
ISO upload/import/media lifecycle        PASS
Golden Image provisioning                PASS
Template create/convert/clone             PASS
Windows 2-ISO installation               PASS
Windows Sysprep template clone            PASS
KubeVirt migration network                PASS
Node/controller reboot/reconcile          PASS
Upgrade/rollback                           PASS
Known unexplained TODO/FIXME/501         0
Production-ready                          YES
```

If any mandatory row is not green:

```text
Production-ready: NO
```

---

# 19. REQUIRED FINAL REPORT FORMAT

At the end of the production session report:

```text
Repository:
Branch:
Starting HEAD:
Final HEAD:

Commits added:
- SHA message

P0 findings:
- finding -> resolution -> test evidence

P1 findings:
- finding -> resolution -> test evidence

Requirement traceability:
Networking: X/Y repository, X/Y lab
Namespace/Tenant: X/Y
Security/RBAC: X/Y
ISO/Media: X/Y
Golden Images: X/Y
Templates: X/Y
Windows: X/Y
Migration: X/Y
Upgrade/Reconcile: X/Y

Tests:
- exact command -> result
- GitHub Actions run ID -> result

Lab:
- Hyper-V host details
- 3 node resources
- Talos version
- Cozystack version/commit
- KubeVirt version
- CDI version
- Multus/bridge-CNI version
- StorageClass/VolumeSnapshotClass
- tests run/results

Known blockers:
- NONE
or exact blockers with evidence

Production-ready:
YES only if every mandatory safety/lab gate passed
NO otherwise
```

---

# 20. EMERGENCY SHORT CONTINUATION BLOCK

If context is constrained, retain this exact minimum:

```text
Repo: adaptgurus/cozystack
Branch: feat/hci-virtualization-v1.6.2-test
Base: v1.6.2
Always fetch actual HEAD first.

Read HCI_VIRTUALIZATION_PRODUCTION_CONTINUATION_SUPER_MASTER_CONTEXT.md first.
Then read the previous ultimate master + production media/network extension + repo HCI contexts.

Known green checkpoint before template work:
d5aa7c71f1223dae1963b798c3d09205cfdc0e6f
HCI gate 33099628181 PASS.

Template foundation added after that checkpoint:
- KubeVirt v1.8.4 native template support capability-gated
- vmTemplates.enabled=true default
- Snapshot + Template gates when enabled
- virtTemplateDeployment enabled when capability on
- rollback path tested when disabled

Existing Golden Images: YES, 16-image global catalog in vm-default-images.
Existing global ISO backend: YES, CDI HTTP/upload target in cozy-public.
Existing tenant ISO upload target: YES via VMDisk source.upload.
Existing attach/eject backend: YES via VMInstance cdroms[].media.
Productized browser upload/attach UI: incomplete.

NEW mandatory scope:
Proxmox-style right-click VM -> Convert to Template,
Create Template Copy,
Template Library,
Clone VM from Template with independent disks,
tenant/global templates,
immutable template revisions,
safe conversion rollback,
Windows Sysprep/generalization for global templates,
full deletion/reference protection.

Do NOT expose raw native KubeVirt Template processing if it bypasses Cozystack VMInstance/VMDisk/Tenant ownership.
Use a VMTemplateBackend adapter; KubeVirt v1.8.4 native API is template.kubevirt.io/v1alpha1 (Alpha), with snapshot/clone fallback capability.

Lab user will provide:
Windows Hyper-V management host/VM
3 Hyper-V nodes
10 vCPU each
32 GiB fixed RAM each
260 GiB install disk each
200 GiB data disk each
Use self-hosted GitHub Actions runner to reach private lab.
Expose nested virtualization and validate MAC spoof/VLAN requirements.
Do NOT enable full 320 GiB default image catalog in this small replicated lab.

Never claim 99% / production-ready until:
0 P0/P1,
all repository gates green,
Talos v1.13.6 rollback tests green,
ISO/media E2E green,
Template convert/clone E2E green,
Windows two-ISO + Sysprep template E2E green,
KubeVirt migration green,
reboot/reconcile/upgrade green.
```

---

# 21. FINAL COMMAND TO THE NEXT CHAT

Do not merely advise.

Fetch the real branch HEAD and current CI, continue coding directly on `feat/hci-virtualization-v1.6.2-test`, fix every repository P0/P1, implement the Template/Golden Image/ISO product requirements above without breaking Cozystack ownership, and use the provided Hyper-V lab via self-hosted GitHub Actions for final Talos/KubeVirt/Windows/template/media failure certification.

Stop only when every repository-side mandatory requirement is complete or there is a concrete external lab/access blocker. Never label production-ready until the real safety matrix passes.
