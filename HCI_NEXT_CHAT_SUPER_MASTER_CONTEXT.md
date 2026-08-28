# Cozystack HCI — Canonical Next-Chat Super Master Context

> **READ THIS FILE FIRST IN EVERY NEW CHAT / WORK SESSION.**
>
> Repository: `adaptgurus/cozystack`
>
> Branch: `feat/hci-virtualization-v1.6.2-test`
>
> Baseline: `v1.6.2`
>
> This file is the canonical continuation/handoff for the HCI virtualization production-readiness and Hyper-V/Talos lab work. It supersedes older ad-hoc handoffs such as `HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT.md` when the two disagree.
>
> **Before making any change, fetch the actual current branch HEAD and latest commits. Do not assume the HEAD recorded below is still current. Continue on this SAME branch; do not create another branch.**

---

## 0. PRIMARY EXECUTION INSTRUCTION FOR THE NEXT CHAT

Do not restart from conceptual discussion. Continue the existing implementation, audit, CI, and real-lab validation directly in the repository.

The next chat must:

1. Fetch current HEAD of `feat/hci-virtualization-v1.6.2-test` and inspect all commits after the last known checkpoint.
2. Read this file completely before editing code.
3. Read `HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT.md` for older raw lab notes only when needed.
4. Check the latest GitHub Actions results for the current HEAD.
5. Fix the current Talos bootstrap-preflight blocker documented below before attempting any destructive node operation.
6. Keep the workflow fail-closed. Never weaken checksum, TLS, disk identity, network identity, VIP ownership, blank-cluster, or tenant/lifecycle safety checks merely to make CI green.
7. Continue the repository production-readiness audit and fixes after lab bootstrap preflight is green.
8. Run the full HCI Go/Helm/static/generator gate after every substantive change and fix every failure.
9. Use the real Hyper-V/Talos lab for actual Cozystack/Talos/KubeVirt/CDI/Multus E2E, restart, rollback, restore, network, storage, HA/migration, upgrade, and failure tests.
10. Do **not** declare the platform production-ready merely because repository CI is green. Repository code readiness and real-lab production certification are separate gates.

Target: evidence-backed **>=95% repository code readiness** with no known P0/P1 defects. Final “production ready” status requires real-lab E2E/failure/rollback/restore/upgrade evidence.

---

## 1. CURRENT REPOSITORY CHECKPOINT

Last observed branch HEAD before this canonical context file was committed:

```text
629996ffcd2a5cbfbb0b4e5cd82c69e94cecd3f6
```

Commit:

```text
ci(hci): add fail-closed Talos bootstrap preflight
```

Its parent was:

```text
959178179013eac3948ee7eae3c7927ebc25d718
ci(hci): bound closed-port Talos discovery probes
```

Important: the documentation commit that creates this file becomes a newer HEAD. Therefore every new chat MUST re-fetch the branch before writing.

### Important commits already made in this effort

The following commits are important history/evidence and should not be reverted accidentally:

```text
a92db48131d985ff6c79e24a1d827cf111f23ab0
fix(hci): synchronize generated virtualization artifacts

fec7d2e4...
fix(hci): regenerate hardened virtualization artifacts

7f5adaf898bbd633ac46034b4f16599150f36b36
test(hci): enforce generated virtualization safety invariants

ecb18a0b8ffb6e57cd08e82af6624dde50e1c363
fix(hci): ignore canonical generated README blank lines

e9964d5570d4f4397f219e95d92b28c51504fed1
ci(hci): add pinned Talos maintenance discovery gate

92d92eabf88f9f6bfd2bc6dae92cc75a6ffd1262
docs(hci): add Hyper-V/Talos lab troubleshooting handoff

933f6ef349af643f6b269cf651314a5bb832c29d
ci(hci): bound Talos tool download and capture runner egress diagnostics

959178179013eac3948ee7eae3c7927ebc25d718
ci(hci): bound closed-port Talos discovery probes

629996ffcd2a5cbfbb0b4e5cd82c69e94cecd3f6
ci(hci): add fail-closed Talos bootstrap preflight
```

If exact abbreviated SHAs are needed, use GitHub commit history rather than guessing.

---

## 2. CURRENT CI / LAB WORKFLOW STATE

### Normal HCI repository gate

At HEAD `629996ffcd2a5cbfbb0b4e5cd82c69e94cecd3f6`:

```text
Workflow: HCI v1.6.2 Gate
Run ID: 33151753635
Conclusion: SUCCESS
```

This proves the normal repository HCI gate was green on the commit that introduced the Talos bootstrap preflight.

The normal gate includes generator, Go, Helm, schema, VMTemplate, network, NetworkFabric, admission, static invariants, and repository cleanliness coverage described later in this file.

### Talos maintenance discovery

Known successful discovery run:

```text
Workflow: HCI Talos Discovery
Run ID: 33150616365
Job ID: 98781486691
Conclusion: SUCCESS
```

That run successfully verified:

- SYSTEM-account runner egress/DNS/HTTPS
- pinned `talosctl` v1.13.6 checksum
- exact Cozystack ISO fingerprint
- Talos v1.13.6 on all 3 nodes
- disks, WWIDs, links, MACs, addresses and routes
- blank-cluster state (TCP/6443 closed)
- Talos maintenance API TCP/50000 reachable

### Current Talos bootstrap preflight blocker

At HEAD `629996ff...`:

```text
Workflow: HCI Talos Bootstrap Preflight
Run ID: 33151753651
Job ID: 98785110515
Conclusion: FAILURE
```

Failed step:

```text
Verify runner context and install pinned tooling
```

The failure occurs **before any node configuration/apply/bootstrap action**. No Talos node was modified by this failed run.

Exact error:

```text
talm.exe : error loading configuration: error reading configuration file: open Chart.yaml: The system cannot find the file specified.
```

The failing line in the workflow is effectively:

```powershell
$talmVersion = (& $talm version 2>&1 | Out-String)
```

The `talm.exe` binary/archive download itself completed successfully. The failure is the version-validation method: `talm version` is being invoked from the Actions working directory where no Talm `Chart.yaml` project exists.

### Exact next fix

Fix `.github/workflows/hci-talos-bootstrap-preflight.yml` so binary/tool validation does **not** run a project-config-loading Talm command outside an initialized Talm project.

Required behavior:

- preserve pinned `HCI_TALM_VERSION=v0.34.0`
- preserve pinned archive SHA256 validation
- do not disable checksum validation
- do not create or commit secrets
- first perform a non-project binary smoke test such as `talm.exe --help` / another command proven not to require `Chart.yaml`
- if the workflow needs to prove semantic Talm version information using a config-loading command, do it only after creating a disposable `talm init` project containing `Chart.yaml`, or use a supported non-project version flag after verifying its behavior from `talm --help`
- do not assume `talm version` is safe outside a project; the live log has already proven it is not in this environment/version
- after changing the workflow, let the push trigger normal CI and bootstrap preflight, inspect exact logs, and fix every failure

Do not proceed to a real Talos apply/bootstrap until this preflight is fully green.

---

## 3. HYPER-V LAB TOPOLOGY — VERIFIED

Hyper-V host / self-hosted GitHub runner:

```text
Host / runner: TESTSER
Runner account: NT AUTHORITY\SYSTEM
Runner labels: self-hosted, Windows, X64
PowerShell: 5.1.26100.33296
Runner version observed: 2.336.0
Elevated Hyper-V administrator: YES
Hyper-V logical processors: 44
Hyper-V live migration on host: disabled
```

### VMs

| VM | Node IP | vCPU | RAM | OS disk | HCI/data disk | MAC |
|---|---:|---:|---:|---:|---:|---|
| `sen1` | `10.10.10.11` | 10 | 32 GiB | 100 GiB dynamic VHDX | 300 GiB dynamic VHDX | `00-15-5D-0A-0A-11` |
| `sen2` | `10.10.10.12` | 10 | 32 GiB | 100 GiB dynamic VHDX | 300 GiB dynamic VHDX | `00-15-5D-0A-0A-12` |
| `sen3` | `10.10.10.13` | 10 | 32 GiB | 100 GiB dynamic VHDX | 300 GiB dynamic VHDX | `00-15-5D-0A-0A-13` |

Planned cluster VIP:

```text
10.10.10.10
```

Hyper-V networking:

```text
vSwitch: Cozystack-NAT
Switch type: Internal
Host vNIC/gateway: 10.10.10.1/24
Windows NAT name: Cozystack-NAT
NAT prefix: 10.10.10.0/24
Physical host management IP observed: 172.28.0.57/26
VM MAC spoofing: On for sen1/sen2/sen3
DHCP Guard: Off
Router Guard: Off
```

Nested virtualization:

```text
ExposeVirtualizationExtensions = True
```

for all three VMs.

### VM disk paths

```text
C:\HyperV\Cozystack\sen1\sen1-OS-100GB.vhdx
C:\HyperV\Cozystack\sen1\sen1-DATA-300GB.vhdx
C:\HyperV\Cozystack\sen2\sen2-OS-100GB.vhdx
C:\HyperV\Cozystack\sen2\sen2-DATA-300GB.vhdx
C:\HyperV\Cozystack\sen3\sen3-OS-100GB.vhdx
C:\HyperV\Cozystack\sen3\sen3-DATA-300GB.vhdx
```

All are dynamic VHDX files.

---

## 4. COZYSTACK / TALOS ISO — CRYPTOGRAPHICALLY VERIFIED

Mounted ISO path:

```text
C:\HyperV\Cozystack\ISO\metal-amd64.iso
```

Mounted on all three VMs at SCSI controller `0`, location `2`.

VM generation:

```text
Generation 2
Secure Boot: Off
```

Lab fingerprint:

```text
Size: 543502336 bytes
SHA256: d925b18dde9262adbb0804a98a8161b7ebca16bf362c70a1bd40530281d519d6
```

This was independently matched against the official Cozystack `v1.6.2` release asset `metal-amd64.iso`, whose official GitHub release metadata reports the same size and SHA256.

Therefore image provenance mismatch is NOT a current blocker.

---

## 5. TALOS MAINTENANCE-MODE DISCOVERY — VERIFIED FACTS

Pinned/observed Talos version:

```text
v1.13.6
```

Pinned `talosctl` Windows binary:

```text
C:\hci-tools\talosctl.exe
SHA256: 87289b89abc444e9428d067f4e4097757148f4c3283491444ef4cceb9cd58b07
Client tag: v1.13.6
Client SHA: 04318854
```

All 3 Talos servers reported:

```text
Tag: v1.13.6
SHA: 04318854
OS/Arch: linux/amd64
```

### Exact Talos disks / WWIDs

`sen1` (`10.10.10.11`):

```text
sda  ~107 GB  OS candidate
WWID: naa.600224806f287aeacd4f9e6329e29270

sdb  ~322 GB  HCI/data candidate
WWID: naa.600224806dc058308dd8a3bf014a297c

sr0  ~544 MB  mounted virtual DVD
```

`sen2` (`10.10.10.12`):

```text
sda  ~107 GB
WWID: naa.60022480b49d2169f5708f59478f5f15

sdb  ~322 GB
WWID: naa.600224807175cdc319d108c6c7383188

sr0  ~544 MB
```

`sen3` (`10.10.10.13`):

```text
sda  ~107 GB
WWID: naa.600224803650253d9f3d59ac3e984736

sdb  ~322 GB
WWID: naa.6002248070d1f838aed76ca81fff39a0

sr0  ~544 MB
```

**Never identify an install target by size alone.** The bootstrap preflight deliberately checks exact OS/data WWIDs plus size before any install/apply.

### Exact Talos management links

```text
sen1: enx00155d0a0a11  MAC 00:15:5d:0a:0a:11
sen2: enx00155d0a0a12  MAC 00:15:5d:0a:0a:12
sen3: enx00155d0a0a13  MAC 00:15:5d:0a:0a:13
```

All were `up` with link state true.

### Exact node addresses

```text
sen1: 10.10.10.11/24
sen2: 10.10.10.12/24
sen3: 10.10.10.13/24
```

### Confirmed gateway / routes

The default/gateway route was discovered on all nodes through:

```text
10.10.10.1
```

Therefore `10.10.10.1` is not an assumption anymore; it is lab-observed Talos route state.

### Endpoint state before bootstrap

Latest proven state:

```text
10.10.10.11: ICMP=True  TCP/50000=True  TCP/6443=False
10.10.10.12: ICMP=True  TCP/50000=True  TCP/6443=False
10.10.10.13: ICMP=True  TCP/50000=True  TCP/6443=False
```

Neighbor/MAC mapping:

```text
10.10.10.11 -> 00-15-5D-0A-0A-11
10.10.10.12 -> 00-15-5D-0A-0A-12
10.10.10.13 -> 00-15-5D-0A-0A-13
```

VIP pre-bootstrap:

```text
10.10.10.10 ICMP=False
TCP/50000=False
TCP/6443=False
ARP/neighbor incomplete / no MAC owner
```

This is expected and required before first bootstrap.

One very early `sen1` ICMP miss immediately after VM startup was transient. Later hardened runs repeatedly proved `sen1` healthy. Do not reopen a persistent `sen1` networking incident unless new evidence appears.

---

## 6. WINDOWS SELF-HOSTED RUNNER TROUBLESHOOTING FACTS

The Actions runner executes as:

```text
NT AUTHORITY\SYSTEM
```

The SYSTEM PATH initially contained only standard Windows paths. These commands were not initially available through runner PATH:

```text
git
talosctl
talm
kubectl
helm
jq
yq
go
```

Do not assume tools installed for an interactive Administrator account are available to the runner service account.

### Egress / DNS results from SYSTEM context

WinHTTP proxy:

```text
Direct access (no proxy server)
```

DNS and TCP/443 were proven working to:

```text
github.com
api.github.com
objects.githubusercontent.com
release-assets.githubusercontent.com
```

`curl.exe` path:

```text
C:\WINDOWS\system32\curl.exe
```

Version observed:

```text
curl 8.16.0 (Windows)
```

Important PowerShell trap:

- bare `curl` may resolve to the PowerShell `Invoke-WebRequest` alias
- always use `curl.exe` in Windows PowerShell 5.1 workflow scripts

The earlier download-hang suspicion was resolved by bounded `curl.exe` usage and persistent verified binaries under `C:\hci-tools`.

### Persistent diagnostic directory

```text
C:\hci-diagnostics
```

Example existing evidence file:

```text
C:\hci-diagnostics\egress-33150616365.txt
```

Bootstrap preflight failure still wrote non-secret evidence:

```text
C:\hci-diagnostics\bootstrap-preflight-33151753651.txt
```

Do not write Talos secrets, kubeconfig private keys, GitHub tokens, registry secrets, backup credentials, or rendered secret-bearing node configs to Actions logs or persistent diagnostics.

---

## 7. LAB WORKFLOWS PRESENT IN REPOSITORY

### `.github/workflows/hci-hyperv-lab.yml`

Purpose:

- inventory Hyper-V host and VMs
- verify CPU/RAM/disks/network/nested virtualization
- start VMs safely
- verify endpoint readiness

Safety behavior:

- if VM is already running and nested virtualization is missing, fail closed rather than force-powering it off
- only change `ExposeVirtualizationExtensions` while VM is Off
- do not force restart healthy nodes for inventory

Known successful Hyper-V run:

```text
Run ID: 33149679029
Job ID: 98778512122
Conclusion: SUCCESS
```

### `.github/workflows/hci-talos-discovery.yml`

Purpose:

- SYSTEM-context DNS/proxy/HTTPS diagnostics
- install/verify pinned talosctl
- fingerprint ISO
- discover Talos version, disks, links, addresses, routes
- verify blank cluster
- print persistent diagnostics

Important hardening already added:

- exact talosctl checksum
- bounded download timeout/retry
- file-size sanity check
- fast bounded TCP probes instead of slow `Test-NetConnection` waits for known closed ports

Known successful run:

```text
Run ID: 33150616365
Job ID: 98781486691
Conclusion: SUCCESS
```

### `.github/workflows/hci-talos-bootstrap-preflight.yml`

Purpose:

- fail-closed, non-destructive preflight before first Talos/Cozystack bootstrap
- verify exact runner/tooling
- verify exact ISO
- verify exact disk WWIDs/sizes
- verify exact management NIC/MAC/IP/gateway
- verify maintenance API availability
- verify TCP/6443 is still closed
- verify VIP is unowned
- render disposable Talm configs and verify install target without committing secrets

Current status:

```text
Run ID: 33151753651
Conclusion: FAILURE
```

Current blocker is only the Talm version check outside a chart, documented in Section 2.

---

## 8. REPOSITORY HCI CODE-READINESS WORK ALREADY COMPLETED

This work started from two production-readiness execution contracts and has already fixed several P0/P1-quality repository issues.

### Generator/source-of-truth hardening

`packages/apps/vm-disk/values.yaml` includes generator annotations for:

```text
mediaCategory pattern:
^$|^(installer|drivers|rescue|appliance|custom)$
```

VMDisk immutability coverage includes:

- source immutable
- storageClass immutable

`packages/apps/vm-network/values.yaml` includes MTU CEL enforcement:

```text
self == 0 || self >= 576
```

with normal max bound 9216.

Generated virtualization artifacts were regenerated and strict generator-clean checks were proven green.

### Canonical generated README handling

The repository generator emits canonical EOF blank lines in some generated READMEs. `git diff --check` was adjusted to exclude the four generator-owned README files while the strict generator-clean stage remains authoritative for their exact bytes.

This fixed a non-functional whitespace false blocker without weakening generated-artifact correctness.

### Permanent HCI test-gate invariants

`hack/test-hci-v1.6.2.sh` was strengthened to assert, among other things:

- 4-way schema parity including VMTemplate
- VMInstance optical/CD-ROM media source option behavior
- VMDisk source immutability
- VMDisk storageClass immutability
- VMDisk mediaCategory exact pattern
- VMNetwork bridge non-empty constraint
- VMNetwork MTU CEL lower-bound semantics
- VMNetwork root fabricRef/fabricNetwork validation
- VMTemplate sourceVM min/max 1/63 and `vminstance` source
- VMTemplate mode enum exactly `Copy`, `Convert`
- VMTemplate `excludeOpticalMedia` enum `[true]`
- tenant resolver tests
- tenant option provider tests
- VM network admission/controller tests
- VMNetwork NAD rendering and no bridge-CNI VLAN double tagging
- invalid schema tests
- app wiring
- system chart lint/render
- NetworkFabric CRD status
- controller PDB/metrics/topology
- KubeVirt migration-network validation
- prohibition of deprecated `HotplugVolumes`
- fail-closed admission/RBAC
- helm-unittest for VMInstance/VMDisk/VMNetwork/vm-default-images/kubevirt
- repository clean checks

### Strict generator evidence

An earlier strict HCI run proved the generator-clean stage passed after regeneration.

The current normal HCI gate is also green on `629996ff...`.

---

## 9. CODE LOGIC / FUNCTION AUDITS ALREADY PERFORMED

The following code was manually inspected for logic/lifecycle behavior. Re-read current files before editing because later commits may have changed them.

### `pkg/tenantresolver/resolver.go`

Observed design:

- `Tenant.status.namespace` is authoritative workload namespace
- resource namespace resolves by matching tenant status.namespace
- relationship validation compares workload namespace and parent
- RBAC authorization uses resolved tenant resource namespace/name
- parent inheritance supported through parent workload namespace
- cycle detection exists
- child tenant discovery uses parent workload namespace

No obvious P0 was found in the inspected state.

### `pkg/vmnetworkadmission/handler.go`

Observed design:

- AdmissionReview CREATE/UPDATE/DELETE for VMNetwork is fail-closed
- tenant resolved server-side
- fabricRef create/update validates NetworkFabric exists, Ready, referenced fabricNetwork exists, topology/bridge matches, selected node Ready, MTU matches
- bridge/VLAN/fabric binding changes blocked while VMs reference network
- deletion blocked while VM references exist
- VM references found by scanning tenant VM HelmReleases and parsing values networks/subnets
- conversion/parsing errors fail closed

Last-known concern to revalidate:

**TOCTOU deletion/reference race**. A VMNetwork delete admission could see zero refs, then a VM could concurrently be created referencing the network before actual deletion/finalizer completion. The intended closure is server-side VM create/update validation against nonexistent/deleting VMNetwork and/or a VMNetwork finalizer/reference-protection mechanism. Revalidate current branch before implementing because later work may already address this.

### `pkg/networkfabriccontroller/reconciler.go`

Observed design:

- finalizer: `infrastructure.cozystack.io/network-fabric-protection`
- deletion cleanup blocks while VMNetworks reference the fabric
- selected nodes are cleaned before finalizer removal
- rollback/error state retained on cleanup failure
- owned network discovery includes current spec plus status.appliedNetworks
- stale cleanup supported
- validates topology/labels/migration network/bridge uniqueness/fabric bridge reuse/interface protection/VLAN/MTU
- raw HelmRelease reference protection parses VMNetwork fabricRef

Last-known operational gap to revalidate:

A finalizer can remain indefinitely if a selected Kubernetes/Talos node is permanently removed. This is safe/fail-closed, but production operations need an explicit audited operator-only recovery path that cannot be tenant-controlled and does not bypass live references.

### `pkg/networkfabriccontroller/transaction_recovery.go`

Observed design:

- persisted stages `TryApplied` and `Verified`
- receipt persisted before verify
- recovery re-discovers live topology
- pre-deadline requeue
- post-deadline desired/prior topology logic
- explicit rollback where needed
- rollback/prior state verification
- unknown stage fails closed/degraded

No in-memory-only transaction truth was observed.

### `pkg/networkfabric/transaction_observed.go`

Observed pipeline:

```text
Discover
-> management safety validation
-> Plan
-> Validate
-> Try
-> persist TryApplied
-> Verify
-> persist Verified
-> Confirm
```

Verify/Confirm failure triggers rollback and joins rollback failures.

### `pkg/networkfabric/talos_api_adapter.go`

Observed design:

- official Talos/Sidero Go APIs, not shelling out
- ApplyConfiguration Try used with rollback timeout
- NoReboot used otherwise/for confirmation
- revision carries expected/previous digest and mode
- Confirm rediscovery/digest verification
- Rollback builds inverse patch from live state
- Discover gathers links/routes/addresses/machineconfig/topology digest
- inverse patch excludes protected/active management interfaces

Architecture is sound on inspection; real lab confirm/rollback semantics are still mandatory before production certification.

### `pkg/networkfabric/planner.go`

Observed design:

- protects management/active session interface
- stale bridge/VLAN cleanup only for controller-owned previous networks
- receipt revision/digest required for observed transition reconciliation
- live rediscovery before commit
- failure rolls back and verifies prior state

---

## 10. LAST-KNOWN MANDATORY REPOSITORY GAPS TO REVALIDATE / FINISH

These were hard requirements from the production-readiness contract. Re-fetch current code and prove whether they remain unresolved; do not assume absence or completion.

### A. Snapshot / backup / restore correctness

This is a hard readiness gate.

Repository dependencies already include:

```text
kubevirt.io/api v1.8.0
kubevirt.io/containerized-data-importer-api v1.63.1
github.com/vmware-tanzu/velero v1.18.1
```

The next audit must map existing Cozystack backup APIs/controllers before inventing anything new.

Required proof/implementation includes:

- stable VM UID lineage
- immutable snapshot-to-VM association
- tenant isolation for snapshot/backup/restore
- backup target validation
- retention validation
- credential reference handling without secret leakage
- restored disks independent of original disks
- deletion/reference cleanup
- explicit timeout/error states
- restore storage/network revalidation
- rollback/failure behavior
- E2E restore evidence in real lab

If these are missing, readiness score must be capped; do not claim >=95% merely from networking/VM CRUD tests.

### B. VMNetwork reference/deletion TOCTOU

Prove server-side that VM create/update cannot successfully bind a VMNetwork that is:

- missing
- deleting
- cross-tenant
- otherwise invalid at admission/reconcile time

If needed, add VMNetwork finalizer/reference protection and tests.

### C. NetworkFabric orphan/finalizer recovery

Need an operator-only, audited, fail-closed recovery model for definitively removed nodes.

Safe principles:

- only cluster-admin/operator controlled
- never tenant controlled
- reference protection always remains mandatory
- do not treat transient Talos unreachability as node disappearance
- if bypassing cleanup for a node that no longer exists, record explicit degraded/audit status with skipped node identity
- do not silently remove finalizer

### D. Full CI loop

After each substantive fix:

- let direct GitHub connector commit trigger Actions
- inspect actual failed stage/log
- fix every failure
- do not stop at first green sub-stage

---

## 11. EXACT NEXT EXECUTION SEQUENCE

### Phase 1 — Re-sync state

1. Fetch branch HEAD.
2. Fetch recent commits after the HEAD recorded in this file.
3. Fetch all workflow runs for current HEAD.
4. If another chat/automation already fixed the Talm preflight, inspect and verify that fix rather than duplicating it.

### Phase 2 — Fix current preflight failure

Current known failure:

```text
open Chart.yaml: The system cannot find the file specified
```

Root cause:

```text
talm.exe version
```

is being used outside a Talm project.

Fix tool validation while preserving:

```text
HCI_TALM_VERSION=v0.34.0
HCI_TALM_ZIP_SHA256=7b7925660c38bf51938648368d3995ce2e48b7422719e9c8d915e39dba6fc07b
```

Do not guess a replacement flag. First inspect:

```powershell
C:\hci-tools\talm.exe --help
C:\hci-tools\talm.exe version --help
```

Use only a command proven not to require project configuration for the initial binary smoke test. If version semantics require project state, create/use the workflow’s disposable Talm project first and perform the version/project validation there.

Then rerun bootstrap preflight.

### Phase 3 — Require full non-destructive bootstrap preflight green

Before any Talos apply/install/bootstrap, prove:

- runner elevated
- talosctl exact checksum/version
- talm exact pinned archive integrity
- official Cozystack v1.6.2 ISO exact size/hash
- sen1/sen2/sen3 exact maintenance endpoints
- exact sda/sdb WWIDs and sizes
- exact management link and MAC
- exact node IPs
- gateway `10.10.10.1`
- TCP/6443 closed on all nodes
- VIP `10.10.10.10` has no IP/L2/Talos/Kubernetes owner
- disposable rendered configs target `sda`, never `sdb`
- no secrets are printed/persisted in Actions logs

Only after all checks are green may a separate explicitly destructive bootstrap workflow be considered.

### Phase 4 — Bootstrap lab safely

Do not add destructive bootstrap logic to a generic push-triggered workflow without strong safeguards.

Preferred production-safety design:

- bootstrap/apply workflow is manual `workflow_dispatch`
- exact branch/ref guard
- explicit typed confirmation input
- blank-cluster guard
- exact disk WWID guard
- exact ISO/Talos version guard
- VIP unowned guard
- rendered config reviewed/sanitized
- no secret config in logs
- one deliberate bootstrap node only
- verify etcd/control plane health before proceeding
- then join remaining control-plane nodes
- capture rollback/recovery evidence

### Phase 5 — Install/validate Cozystack and HCI stack

After Talos cluster bootstrap:

- validate Talos service health
- validate Kubernetes API/VIP ownership
- validate etcd quorum
- install/validate Cozystack according to v1.6.2 flow
- validate KubeVirt
- validate CDI
- validate Multus/CNI
- validate Block storage/HCI storage behavior
- validate tenant APIs and UI-generated objects

### Phase 6 — Real HCI failure/rollback tests

Must include at minimum:

- NetworkFabric create/update/delete
- Talos bridge/VLAN apply
- stale VLAN/bridge cleanup
- management NIC protection
- try/verify/confirm
- try timeout rollback
- controller restart during TryApplied
- controller restart during Verified
- partial node failure
- missing node/finalizer recovery behavior
- VMNetwork deletion/reference races
- VM create/update/delete
- custom/multus networks
- migration network
- live migration
- HA/restart
- ISO library and mount/eject
- Windows two-ISO install pattern
- snapshots
- backup
- restore to independent disks
- delete/orphan cleanup
- tenant isolation
- upgrade and rollback

### Phase 7 — Production-readiness scoring

Only score repository readiness after all repository gates and required semantics are proven.

Keep two statuses:

```text
Repository code readiness: X/100
Real-lab production certification: PASS/FAIL/INCOMPLETE
```

Never collapse these into one claim.

---

## 12. USEFUL WINDOWS / HYPER-V COMMANDS

### Runner identity and privileges

```powershell
whoami
$PSVersionTable

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
```

### Hyper-V host

```powershell
Get-Command Get-VM, Start-VM, Set-VMProcessor, Get-VHD
Get-VMHost | Format-List *
Get-VMSwitch | Format-List *
Get-NetNat | Format-List *
Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceAlias,IPAddress
Get-NetRoute -AddressFamily IPv4 | Sort-Object InterfaceIndex,DestinationPrefix
Get-NetNeighbor -AddressFamily IPv4 | Sort-Object InterfaceIndex,IPAddress
```

### VM details

```powershell
$names = 'sen1','sen2','sen3'
foreach ($name in $names) {
  Write-Host "===== $name ====="
  Get-VM -Name $name | Format-List *
  Get-VMProcessor -VMName $name | Format-List *
  Get-VMMemory -VMName $name | Format-List *
  Get-VMNetworkAdapter -VMName $name | Format-List *
  Get-VMDvdDrive -VMName $name | Format-List *
  Get-VMFirmware -VMName $name | Format-List *
  Get-VMHardDiskDrive -VMName $name | Format-List *
}
```

### VHD details

```powershell
foreach ($name in 'sen1','sen2','sen3') {
  Get-VMHardDiskDrive -VMName $name | ForEach-Object {
    Get-VHD -Path $_.Path | Format-List *
  }
}
```

### Fast TCP probe — use instead of slow `Test-NetConnection` for expected closed ports

```powershell
function Test-TcpPortFast {
  param(
    [Parameter(Mandatory=$true)][string]$ComputerName,
    [Parameter(Mandatory=$true)][int]$Port,
    [int]$TimeoutMs = 3000
  )

  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}
```

Example:

```powershell
foreach ($ip in '10.10.10.11','10.10.10.12','10.10.10.13','10.10.10.10') {
  $icmp  = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
  $talos = Test-TcpPortFast $ip 50000 3000
  $kube  = Test-TcpPortFast $ip 6443 3000
  Write-Host "$ip ICMP=$icmp TCP50000=$talos TCP6443=$kube"
  Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue
}
```

---

## 13. TALOS MAINTENANCE COMMANDS

Use the checksum-verified binary:

```powershell
$talosctl = 'C:\hci-tools\talosctl.exe'
$nodes = '10.10.10.11','10.10.10.12','10.10.10.13'
```

Version:

```powershell
foreach ($node in $nodes) {
  & $talosctl version --insecure --nodes $node --endpoints $node
}
```

Disks:

```powershell
foreach ($node in $nodes) {
  & $talosctl get disks --insecure --nodes $node --endpoints $node
}
```

Links:

```powershell
foreach ($node in $nodes) {
  & $talosctl get links --insecure --nodes $node --endpoints $node
}
```

Addresses:

```powershell
foreach ($node in $nodes) {
  & $talosctl get addresses --insecure --nodes $node --endpoints $node
}
```

Routes:

```powershell
foreach ($node in $nodes) {
  & $talosctl get routes --insecure --nodes $node --endpoints $node
}
```

Do not use `--insecure` after normal authenticated Talos configuration is applied except where maintenance-mode behavior explicitly requires it.

---

## 14. TOOL DOWNLOAD / EGRESS DIAGNOSTICS

SYSTEM-context diagnostics:

```powershell
$ErrorActionPreference = 'Continue'

whoami
$PSVersionTable
$env:PATH -split ';'

netsh winhttp show proxy
Get-ChildItem Env: | Where-Object Name -match 'proxy'

Resolve-DnsName github.com
Resolve-DnsName api.github.com
Resolve-DnsName objects.githubusercontent.com
Resolve-DnsName release-assets.githubusercontent.com

Get-Command curl.exe -ErrorAction SilentlyContinue
curl.exe --version
curl.exe -I -L --connect-timeout 10 --max-time 30 https://github.com/
```

Pinned Talos download shape:

```powershell
$version = 'v1.13.6'
$url = "https://github.com/siderolabs/talos/releases/download/$version/talosctl-windows-amd64.exe"
$out = 'C:\hci-tools\talosctl.exe.download'

curl.exe --fail --location --connect-timeout 10 --max-time 120 --retry 2 --retry-delay 2 `
  --output $out $url

if ($LASTEXITCODE -ne 0) {
  throw "talosctl download failed with curl.exe exit code $LASTEXITCODE"
}

Get-FileHash -Algorithm SHA256 $out
```

Expected Talos Windows binary SHA256:

```text
87289b89abc444e9428d067f4e4097757148f4c3283491444ef4cceb9cd58b07
```

Never use `-SkipCertificateCheck`, disable TLS verification, or accept an unverified binary.

---

## 15. SAFETY / FAIL-CLOSED RULES

These are mandatory.

1. Never install Talos to a disk identified only by `/dev/sda` without also checking the expected WWID in this lab.
2. Never touch `sdb` as the Talos OS install target; it is the intended HCI/data disk.
3. Never bootstrap if TCP/6443 is already active on any node unless intentionally handling an existing cluster.
4. Never bootstrap if VIP `10.10.10.10` already has an IP/MAC/Talos/Kubernetes owner.
5. Never disable checksum/TLS verification to solve runner egress problems.
6. Never print Talos secrets or kubeconfig keys in Actions logs.
7. Never force-off healthy VMs from a routine CI inventory workflow.
8. Never manually remove NetworkFabric finalizers just to clear a stuck object without following an audited operator-only recovery procedure.
9. Never bypass VMNetwork/NetworkFabric reference protection to make deletion succeed.
10. Never declare backup/restore complete without proving restored disks are independent from originals.
11. Never declare production ready solely from mocks, Helm render, unit tests, or synthetic CI.
12. Never merge into another branch unless the user explicitly asks; continue on `feat/hci-virtualization-v1.6.2-test`.

---

## 16. WHAT THE NEXT CHAT SHOULD REPORT WHILE WORKING

Provide concise progress updates with evidence, not generic statements.

For each issue fixed, report:

```text
- exact defect/root cause
- files changed
- commit SHA
- workflow/run ID
- exact failed/passed stage
- relevant lab evidence
- whether the change is repository-only or real-lab validated
```

When a test fails, pull the exact job log and fix the real failure. Do not guess from the workflow title.

---

## 17. FINAL ACCEPTANCE FORMAT

When the work eventually reaches a stopping point, report:

```text
Final branch HEAD: <sha>

Repository CI:
- HCI v1.6.2 Gate: PASS/FAIL + run ID
- Talos discovery: PASS/FAIL + run ID
- Talos bootstrap preflight: PASS/FAIL + run ID
- any additional HCI workflows: PASS/FAIL + run ID

Real-lab validation:
- Talos bootstrap: PASS/FAIL
- Kubernetes VIP/API: PASS/FAIL
- Cozystack install: PASS/FAIL
- KubeVirt: PASS/FAIL
- CDI: PASS/FAIL
- Multus/networking: PASS/FAIL
- NetworkFabric try/rollback/restart: PASS/FAIL
- VM lifecycle: PASS/FAIL
- migration/HA: PASS/FAIL
- ISO/Windows media: PASS/FAIL
- snapshot: PASS/FAIL
- backup: PASS/FAIL
- restore independence: PASS/FAIL
- tenant isolation: PASS/FAIL
- upgrade/rollback: PASS/FAIL
- destructive/failure/soak tests: PASS/FAIL

Repository code readiness score: X/100
Real-lab production certification: PASS/FAIL/INCOMPLETE
Known P0: ...
Known P1: ...
Known P2: ...
```

No “production-ready” claim is valid until the real-lab certification list is satisfied.

---

## 18. COPY/PASTE STARTING PROMPT FOR A NEW CHAT

Use the following instruction in a new chat:

```text
Open adaptgurus/cozystack and continue on branch feat/hci-virtualization-v1.6.2-test.

Read HCI_NEXT_CHAT_SUPER_MASTER_CONTEXT.md FIRST and treat it as the canonical handoff. Then read HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT.md only for older supporting lab detail when needed.

Fetch the actual current branch HEAD and latest commits before changing anything. Do not create another branch and do not restart from conceptual discussion.

Continue directly from the current blocker. The last-known Talos bootstrap-preflight run failed before any node change because `talm.exe version` attempted to load `Chart.yaml` from a non-Talm working directory. Fix that preflight correctly without weakening checksum, TLS, disk-WWID, NIC/MAC, VIP ownership, blank-cluster, or secret-handling safeguards. Inspect `talm.exe --help` / command behavior first; do not guess a flag. Re-run the preflight and fix every failure until it is green.

After the non-destructive bootstrap preflight is green, continue the full HCI production-readiness work documented in the master context: repository audit/fixes, VMNetwork deletion/reference race closure, NetworkFabric lifecycle/orphan recovery, snapshot/backup/restore correctness, generator/Go/Helm gates, and real Hyper-V/Talos/Cozystack/KubeVirt/CDI/Multus E2E/failure/rollback/restore/upgrade testing.

Use the existing TESTSER self-hosted Windows Hyper-V runner and the sen1/sen2/sen3 lab only through safe, auditable workflows. Keep destructive bootstrap/manual operations strongly gated and fail closed.

Make all changes directly in the same repository branch and commit them. Pull exact GitHub Actions logs for every failure and record new troubleshooting discoveries/commands/run IDs back into HCI_NEXT_CHAT_SUPER_MASTER_CONTEXT.md so future sessions can continue without losing state.

Do not declare production-ready until real lab E2E, destructive/failure, rollback, restore, upgrade and soak tests pass. Keep repository code readiness and real-lab production certification as separate statuses.
```

---

## 19. MAINTENANCE RULE FOR THIS FILE

Every future session that discovers a new meaningful blocker, exact command, device identity, workflow behavior, run ID, root cause, rollback procedure, or production-readiness result should update this file before ending the session.

Do not fill it with raw secrets or entire repetitive logs. Record:

- exact error text
- root cause
- command used to prove/fix it
- important output/state
- commit SHA
- Actions run/job ID
- safety implication
- exact next step

This makes future troubleshooting progressively deeper instead of repeating old discovery work.
