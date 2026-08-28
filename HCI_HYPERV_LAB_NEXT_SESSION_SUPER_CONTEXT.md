# Cozystack HCI Hyper-V Lab — Next Session / Troubleshooting Super Context

> **READ THIS FILE FIRST BEFORE CHANGING ANYTHING.**
>
> Continue work directly on branch `feat/hci-virtualization-v1.6.2-test` in repository `adaptgurus/cozystack`. Do not create a new branch. Fetch the current branch HEAD before every write because this branch is being changed by CI-assisted work.
>
> The objective is **99% evidence-backed repository/lab readiness**, but do **not** declare the platform production-ready until real Cozystack/Talos/KubeVirt/CDI/Multus E2E, failure, rollback, upgrade, restore and soak tests pass on this lab.

## 1. Current lab topology

Hyper-V host / self-hosted GitHub runner:

- Host / runner name: `TESTSER`
- Runner service identity observed in Actions: `NT AUTHORITY\SYSTEM`
- Runner architecture: Windows X64
- Windows PowerShell: `5.1.26100.33296`
- Hyper-V administration: **elevated administrator = true**
- Hyper-V logical processors: **44**
- Hyper-V live migration on host: **disabled**

Cozystack/Talos VMs:

| VM | Node IP | vCPU | RAM | OS disk | HCI/data disk | MAC |
|---|---:|---:|---:|---:|---:|---|
| `sen1` | `10.10.10.11` | 10 | 32 GiB | 100 GiB dynamic VHDX | 300 GiB dynamic VHDX | `00-15-5D-0A-0A-11` |
| `sen2` | `10.10.10.12` | 10 | 32 GiB | 100 GiB dynamic VHDX | 300 GiB dynamic VHDX | `00-15-5D-0A-0A-12` |
| `sen3` | `10.10.10.13` | 10 | 32 GiB | 100 GiB dynamic VHDX | 300 GiB dynamic VHDX | `00-15-5D-0A-0A-13` |

Cluster VIP planned by user:

- `10.10.10.10`

Hyper-V networking observed:

- vSwitch: `Cozystack-NAT`
- switch type: **Internal**
- host vNIC IP: `10.10.10.1/24`
- Windows NAT name: `Cozystack-NAT`
- NAT prefix: `10.10.10.0/24`
- physical host management IP observed: `172.28.0.57/26`
- VM MAC spoofing: **On** for all three VMs
- DHCP Guard: Off
- Router Guard: Off

Talos ISO:

- mounted on all three VMs at SCSI controller `0`, location `2`
- path: `C:\HyperV\Cozystack\ISO\metal-amd64.iso`
- VM generation: 2
- Secure Boot: Off
- ISO is mounted on all three VMs

Disk paths:

- `C:\HyperV\Cozystack\sen1\sen1-OS-100GB.vhdx`
- `C:\HyperV\Cozystack\sen1\sen1-DATA-300GB.vhdx`
- `C:\HyperV\Cozystack\sen2\sen2-OS-100GB.vhdx`
- `C:\HyperV\Cozystack\sen2\sen2-DATA-300GB.vhdx`
- `C:\HyperV\Cozystack\sen3\sen3-OS-100GB.vhdx`
- `C:\HyperV\Cozystack\sen3\sen3-DATA-300GB.vhdx`

All six VHDX files were reported as `Dynamic` and only ~4 MiB allocated at first inventory, which is consistent with blank/thin disks before Talos installation.

## 2. Current repository / CI state

Repository:

- `adaptgurus/cozystack`
- branch: `feat/hci-virtualization-v1.6.2-test`
- last HEAD observed before this handoff file was created: `e9964d5570d4f4397f219e95d92b28c51504fed1`
- commit message: `ci(hci): add pinned Talos maintenance discovery gate`

Normal HCI code gate:

- workflow: `.github/workflows/hci-v1.6.2-gate.yml`
- run on `e9964d5570d4f4397f219e95d92b28c51504fed1`: **SUCCESS**
- Actions run ID: `33150019020`
- this is important evidence that the current repository HCI gate was green before this documentation-only commit.

Hyper-V lab workflow:

- workflow: `.github/workflows/hci-hyperv-lab.yml`
- successful run ID: `33149679029`
- job ID: `98778512122`
- conclusion: **SUCCESS**

Talos discovery workflow:

- workflow: `.github/workflows/hci-talos-discovery.yml`
- first run ID: `33150019104`
- job ID: `98779603796`
- state when this handoff was prepared: still in `Install and verify pinned talosctl`
- likely current blocker: runner-side download/tool bootstrap, not Hyper-V or Talos reachability.

Always re-fetch run state because this job may have completed or failed after this file was committed.

## 3. Hyper-V / node validation already completed

The self-hosted runner successfully proved:

1. `Get-VM`, `Start-VM`, `Set-VMProcessor`, `Get-VHD` are callable.
2. Runner is elevated Administrator.
3. All VMs exist.
4. Each VM has 10 vCPU.
5. Each VM has 32 GiB static startup RAM.
6. Each VM has a 100 GiB OS VHDX.
7. Each VM has a 300 GiB HCI/data VHDX.
8. Nested virtualization is enabled on all three VMs:
   - `ExposeVirtualizationExtensions = True`
9. All three VMs reached `Running` / `Operating normally`.
10. All three node IPs became reachable.
11. Talos maintenance API TCP/50000 is reachable on all three nodes.
12. Kubernetes API TCP/6443 is not listening yet, which is expected before bootstrap.
13. VIP is not currently owned, which is expected before control-plane/VIP configuration.

Latest successful endpoint results:

```text
Target       ICMP
------       ----
10.10.10.11  True
10.10.10.12  True
10.10.10.13  True
10.10.10.10  False
```

Talos maintenance API / Kubernetes API:

```text
10.10.10.11 TCP/50000 = True
10.10.10.11 TCP/6443  = False

10.10.10.12 TCP/50000 = True
10.10.10.12 TCP/6443  = False

10.10.10.13 TCP/50000 = True
10.10.10.13 TCP/6443  = False

10.10.10.10 TCP/50000 = False
10.10.10.10 TCP/6443  = False
```

ARP/neighbor observations:

```text
10.10.10.11 -> 00-15-5D-0A-0A-11 Reachable
10.10.10.12 -> 00-15-5D-0A-0A-12 Reachable
10.10.10.13 -> 00-15-5D-0A-0A-13 Reachable
10.10.10.10 -> 00-00-00-00-00-00 Incomplete
```

Interpretation:

- `sen1` had one earlier transient ICMP failure immediately after startup, but the hardened workflow added a startup grace period and the next run proved `sen1` healthy.
- Do not treat the earlier single failed ping as a persistent `sen1` problem.
- VIP absence is expected until Talos/Cozystack control-plane VIP logic is applied.

## 4. Runner tooling problem found

The Windows self-hosted runner is running as `NT AUTHORITY\SYSTEM` and the following commands were not available in the runner process PATH during the Hyper-V inventory run:

```text
MISSING git
MISSING talosctl
MISSING talm
MISSING kubectl
MISSING helm
MISSING jq
MISSING yq
MISSING go
```

`curl` was misleading because Windows PowerShell resolved `curl` as the `Invoke-WebRequest` alias instead of `curl.exe`. The workflow command `curl version` therefore tried to access a host named `version` and returned:

```text
WARNING: The remote name could not be resolved: 'version'
```

**Important:** when testing curl on Windows PowerShell 5.1, use `curl.exe`, never bare `curl`.

The Talos discovery workflow was added to install a pinned `talosctl` under:

```text
C:\hci-tools\talosctl.exe
```

Pinned version configured:

```text
v1.13.6
```

Pinned SHA256 currently configured in workflow:

```text
87289b89abc444e9428d067f4e4097757148f4c3283491444ef4cceb9cd58b07
```

Before trusting this value, verify it against the official Talos v1.13.6 release asset if changing the workflow or binary.

## 5. Immediate next troubleshooting target

The next session must start by checking the current result of Talos discovery run `33150019104`.

If it is still stuck or failed in `Install and verify pinned talosctl`, diagnose outbound connectivity from the **SYSTEM account context** used by the runner.

Run these through a GitHub Actions step on the self-hosted runner so the execution context is identical to the service:

```powershell
$ErrorActionPreference = 'Continue'

Write-Host '=== identity ==='
whoami
$PSVersionTable

Write-Host '=== PATH ==='
$env:PATH -split ';'

Write-Host '=== proxy ==='
netsh winhttp show proxy
Get-ChildItem Env: | Where-Object Name -match 'proxy'

Write-Host '=== DNS ==='
Resolve-DnsName github.com
Resolve-DnsName objects.githubusercontent.com
Resolve-DnsName release-assets.githubusercontent.com
Resolve-DnsName api.github.com

Write-Host '=== TCP/443 ==='
Test-NetConnection github.com -Port 443
Test-NetConnection objects.githubusercontent.com -Port 443
Test-NetConnection release-assets.githubusercontent.com -Port 443
Test-NetConnection api.github.com -Port 443

Write-Host '=== curl.exe ==='
Get-Command curl.exe -ErrorAction SilentlyContinue
curl.exe --version
curl.exe -I -L --connect-timeout 10 --max-time 30 https://github.com/

Write-Host '=== tools dir ==='
Get-ChildItem C:\hci-tools -Force -ErrorAction SilentlyContinue
```

Then attempt the Talos binary with bounded timeouts, never an unbounded `Invoke-WebRequest`:

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

If DNS/HTTPS is blocked for the runner service account, do not disable TLS verification. Fix proxy/DNS/service environment or place a checksum-verified binary in `C:\hci-tools` through an approved host provisioning mechanism.

## 6. Talos maintenance-mode discovery commands to run next

Once `talosctl.exe` is available and checksum-verified:

```powershell
$talosctl = 'C:\hci-tools\talosctl.exe'
$nodes = '10.10.10.11','10.10.10.12','10.10.10.13'

foreach ($node in $nodes) {
  Write-Host "===== VERSION $node ====="
  & $talosctl version --insecure --nodes $node --endpoints $node

  Write-Host "===== DISKS $node ====="
  & $talosctl get disks --insecure --nodes $node --endpoints $node

  Write-Host "===== LINKS $node ====="
  & $talosctl get links --insecure --nodes $node --endpoints $node

  Write-Host "===== ADDRESSES $node ====="
  & $talosctl get addresses --insecure --nodes $node --endpoints $node

  Write-Host "===== ROUTES $node ====="
  & $talosctl get routes --insecure --nodes $node --endpoints $node
}
```

Expected pre-bootstrap state:

- Talos maintenance API reachable on TCP/50000.
- Nodes should identify expected Talos version.
- 100 GiB disk and 300 GiB disk should both be visible from Talos.
- Node addresses should be exactly:
  - `10.10.10.11/24`
  - `10.10.10.12/24`
  - `10.10.10.13/24`
- default gateway should be validated before bootstrap; likely host NAT gateway is `10.10.10.1`, but **do not assume** — confirm from Talos routes.
- no Kubernetes API should be listening on 6443 yet.

## 7. Hyper-V diagnostic commands already proven useful

Host / runner identity and Hyper-V permissions:

```powershell
Write-Host "Runner: $env:RUNNER_NAME"
Write-Host "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

Get-Command Get-VM, Start-VM, Set-VMProcessor, Get-VHD
Get-VMHost | Format-List *
```

VM configuration:

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

VHD details:

```powershell
foreach ($name in 'sen1','sen2','sen3') {
  Get-VMHardDiskDrive -VMName $name | ForEach-Object {
    Get-VHD -Path $_.Path | Format-List *
  }
}
```

Network topology:

```powershell
Get-VMSwitch | Format-List *
Get-NetNat | Format-List *
Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceAlias,IPAddress
Get-NetRoute -AddressFamily IPv4 | Sort-Object InterfaceIndex,DestinationPrefix
Get-NetNeighbor -AddressFamily IPv4 | Sort-Object InterfaceIndex,IPAddress
```

Endpoint checks:

```powershell
foreach ($ip in '10.10.10.11','10.10.10.12','10.10.10.13','10.10.10.10') {
  Write-Host "===== $ip ====="
  Test-Connection -ComputerName $ip -Count 2
  Test-NetConnection -ComputerName $ip -Port 50000
  Test-NetConnection -ComputerName $ip -Port 6443
  Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue
}
```

## 8. Safety rules for the lab workflows

The Hyper-V workflow was deliberately hardened to avoid CI becoming destructive:

- If a VM is already running and nested virtualization is missing, **fail closed** instead of force-powering it off.
- Only call `Set-VMProcessor -ExposeVirtualizationExtensions $true` while a VM is Off.
- Do not force-restart healthy nodes just to rerun inventory.
- Before destructive storage/network tests, confirm workload state and capture rollback evidence.
- Do not remove NetworkFabric finalizers manually unless an audited operator-only recovery path explicitly requires it.
- Do not weaken TLS verification to work around downloads.
- Do not print Talos secrets, kubeconfig client keys, GitHub PATs, registry credentials or backup credentials into Actions logs.

## 9. Repository HCI code work already completed before lab bootstrap

The branch already contains substantial HCI code hardening. Do not restart from design discussion.

Important previously completed items include:

- strict generated virtualization artifact synchronization
- VMDisk source immutability
- VMDisk storageClass immutability
- VMDisk mediaCategory schema restriction
- VMNetwork MTU CEL validation
- four-way schema parity checks including VMTemplate
- VMTemplate schema and backend/controller tests
- fail-closed VM network admission logic
- NetworkFabric Talos transactional apply / verify / confirm / rollback flow
- persisted NetworkFabric transaction recovery
- stale controller-owned VLAN/bridge cleanup design
- NetworkFabric finalizer/reference protection
- management-interface protection
- KubeVirt migration network validation/static checks
- generated README canonical blank-line workaround while preserving strict generator-clean checks
- full `hack/test-hci-v1.6.2.sh` repository gate green on the pre-handoff HEAD

Do not claim these are fully production-certified until lab E2E verifies them.

## 10. Remaining high-priority production-readiness work

After Talos/Cozystack bootstrap succeeds, continue in this order.

### P0/P1-A — Complete cluster bootstrap

- verify exact Talos version and ISO fingerprint
- verify node disk enumeration
- verify static node addresses and routes
- generate Talos/Cozystack machine configuration from current supported Cozystack v1.6.2 process
- configure VIP `10.10.10.10`
- apply configs safely
- bootstrap control plane once
- wait for API availability
- validate all nodes Ready
- validate reboot persistence

### P0/P1-B — VMNetwork deletion/reference TOCTOU

Audit and close the race where VMNetwork deletion can pass the reference check and a VM can concurrently start referencing the network.

Required behavior:

- VM create/update must reject a referenced VMNetwork that is missing or has `deletionTimestamp` set.
- VMNetwork deletion/finalizer path must continue blocking while references exist.
- test concurrent/reference lifecycle explicitly.
- keep all checks tenant-aware and fail closed.

### P0/P1-C — NetworkFabric orphan/finalizer recovery

Existing deletion behavior is safe/fail-closed but can remain stuck if a selected node is permanently removed.

Implement/test a narrowly scoped cluster-admin recovery path if still absent:

- references must still block deletion
- never bypass a merely transiently unreachable existing node
- only allow an audited operator-only orphan escape when Kubernetes node identity is definitively gone
- record Degraded/reason/status evidence listing skipped cleanup
- never expose the bypass to tenant APIs

### P0/P1-D — Snapshot / backup / restore hard gates

Audit the actual existing Cozystack backup framework before adding a parallel implementation.

Required evidence:

- immutable/stable source VM UID lineage
- snapshot-to-VM association cannot silently retarget
- tenant isolation
- target validation
- retention validation
- credential references are server-side validated
- restored disks are independent of source disks
- restore revalidates network/storage dependencies
- finalizer/reference cleanup is safe
- explicit timeouts/errors
- interrupted restore recovery
- delete-source-then-restore test
- cross-tenant restore rejection

### P1-E — Real KubeVirt tests

- Linux VM creation
- Windows VM creation
- ISO attach
- two-ISO Windows installer + VirtIO driver flow
- ISO eject/remount
- VM reboot
- host/node reboot
- HA/reschedule behavior
- disk persistence
- live migration node1 -> node2 -> node3
- dedicated migration network
- failed migration rollback

### P1-F — Failure injection

- kill NetworkFabric controller during TryApplied
- kill controller during Verified stage
- reboot Talos node during transaction
- temporarily break Talos API
- wrong VLAN / wrong bridge / MTU mismatch
- management-interface safety rejection
- stale bridge/VLAN cleanup
- repeated reconciliation idempotency
- API outage and restart recovery

### P1-G — Upgrade / rollback

- install supported baseline
- create workloads
- upgrade to modified branch build
- verify VM/network/storage data
- reboot nodes
- rollback to supported baseline if required
- verify no data loss and no stale fabric resources

## 11. Evidence matrix expected before 99% claim

A future session should keep a table like this updated with actual Actions run IDs / logs:

| Gate | Result | Evidence |
|---|---|---|
| Repository HCI test gate | PASS | run `33150019020` on pre-handoff HEAD |
| Hyper-V admin/runner | PASS | run `33149679029`, job `98778512122` |
| VM sizing | PASS | same Hyper-V job |
| Nested virtualization | PASS | same Hyper-V job |
| Node ICMP | PASS | same Hyper-V job |
| Talos TCP/50000 | PASS | same Hyper-V job |
| Talos version | PENDING | discovery workflow |
| Disk discovery | PENDING | discovery workflow |
| Static IP/routes | PENDING | discovery workflow |
| VIP ownership | PENDING | after bootstrap |
| Kubernetes API | PENDING | after bootstrap |
| Cozystack install | PENDING | after bootstrap |
| KubeVirt | PENDING | after Cozystack |
| CDI | PENDING | after Cozystack |
| Multus | PENDING | after Cozystack |
| NetworkFabric real apply | PENDING | lab E2E |
| Talos rollback | PENDING | destructive test |
| Controller restart recovery | PENDING | destructive test |
| Linux VM | PENDING | lab E2E |
| Windows VM | PENDING | lab E2E |
| two-ISO lifecycle | PENDING | lab E2E |
| live migration | PENDING | lab E2E |
| snapshot | PENDING | lab E2E |
| backup | PENDING | lab E2E |
| restore independence | PENDING | lab E2E |
| upgrade | PENDING | lab E2E |
| rollback | PENDING | lab E2E |
| soak | PENDING | lab E2E |

## 12. Definition of readiness

Keep two scores separate.

### Repository/code readiness

Can reach 95–99% when:

- all static/schema/generator tests are green
- all Go/Helm/unit/integration tests are green
- no known P0/P1 logic gaps remain
- VMNetwork deletion race is closed
- NetworkFabric orphan recovery is controlled/audited
- snapshot/backup/restore hard gates are implemented and unit/integration tested

### Lab/production certification readiness

Can only approach 99% after:

- real three-node Talos/Cozystack deployment succeeds
- real KubeVirt/CDI/Multus workloads work
- failure/restart/rollback tests pass
- backup/restore tests pass
- upgrade/rollback tests pass
- repeated destructive and soak testing passes

**Never collapse these two numbers into one unsupported production-readiness claim.**

## 13. Exact instruction for next ChatGPT/Codex session

Use this as the continuation command:

```text
Open adaptgurus/cozystack and continue directly on branch feat/hci-virtualization-v1.6.2-test.

Read HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT.md FIRST.
Then read the earlier HCI super-context files if present.

Fetch the actual current branch HEAD and current GitHub Actions runs before changing anything.
Do not create another branch.
Do not restart from conceptual discussion.

First inspect the current result/logs of HCI Talos Discovery run 33150019104. If talosctl installation is stuck or failed, diagnose SYSTEM-account DNS/proxy/HTTPS/curl.exe behavior with bounded timeouts, fix the workflow, and rerun it.

Then complete Talos maintenance discovery for sen1/sen2/sen3 at 10.10.10.11/12/13, verify the 100GB and 300GB disks and static network/routes, configure VIP 10.10.10.10, bootstrap the three-node Cozystack lab, and continue the production-readiness gates documented in this file.

Every failure must be investigated from Actions logs and converted into a reproducible test or guard where appropriate. Commit all permanent fixes to the same branch.

Do not declare production-ready until the repository gate plus real Cozystack/Talos/KubeVirt/CDI/Multus destructive/failure/rollback/backup/restore/upgrade tests pass.
```
