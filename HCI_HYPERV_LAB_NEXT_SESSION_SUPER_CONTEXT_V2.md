# Cozystack HCI Hyper-V Lab — Verified Next-Session Super Context V2

> **THIS IS THE CURRENT CANONICAL LAB HANDOFF. READ THIS FILE FIRST.**
>
> Repository: `adaptgurus/cozystack`
>
> Branch: `feat/hci-virtualization-v1.6.2-test`
>
> Continue on this exact branch. Do not create another branch and do not restart from conceptual design discussion. Fetch the actual branch HEAD and latest Actions runs before every write because CI-assisted commits may advance the branch.
>
> Goal: drive repository and three-node lab readiness toward **99% evidence-backed readiness**. Do **not** call the platform production-ready until the destructive/failure/rollback/backup/restore/upgrade/soak gates in this document pass in the real lab.

---

## 1. Why this V2 file exists

The first handoff file, `HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT.md`, was committed before Talos maintenance-mode discovery completed. This V2 file records the completed discovery results, exact device identities, image provenance, network routes, runner egress state, run IDs and troubleshooting commands.

Read V2 first. Use the first file as historical context for earlier repository/code work.

---

## 2. Current repository state at this checkpoint

Last code/workflow commit tested by both the repository HCI gate and Talos discovery:

```text
933f6ef349af643f6b269cf651314a5bb832c29d
ci(hci): bound Talos tool download and capture runner egress diagnostics
```

This V2 documentation file is committed after that SHA, so **fetch current HEAD before acting**.

Important commits from this lab phase:

```text
92d92eabf88f9f6bfd2bc6dae92cc75a6ffd1262
  docs(hci): add Hyper-V lab troubleshooting handoff context

933f6ef349af643f6b269cf651314a5bb832c29d
  ci(hci): bound Talos tool download and capture runner egress diagnostics
```

The repository already contains earlier HCI code hardening for VM networking, NetworkFabric transactions/rollback/recovery, VMTemplate, generated schemas, KubeVirt migration network checks and other v1.6.2 work. Do not redo those changes without first reading current source/tests.

---

## 3. CI evidence — current checkpoint

### 3.1 Repository HCI code gate

Workflow:

```text
.github/workflows/hci-v1.6.2-gate.yml
```

Run:

```text
Run ID: 33150616354
Job ID: 98781544183
Head: 933f6ef349af643f6b269cf651314a5bb832c29d
Conclusion: SUCCESS
```

Successful steps included:

```text
Checkout code and tags                                      PASS
Set up Go                                                  PASS
Set up Helm                                                PASS
Install helm-unittest                                      PASS
Test canonical VM resource family naming                  PASS
Install Cozystack values generator                         PASS
Verify generated HCI application artifacts are clean      PASS
Test VM template safety backend and transaction controller PASS
Test VM Template product charts/schema parity              PASS
Run HCI v1.6.2 gate                                        PASS
```

This means the strict repository gate is green on the workflow/code checkpoint immediately before this V2 documentation commit.

### 3.2 Hyper-V inventory/start gate

Workflow:

```text
.github/workflows/hci-hyperv-lab.yml
```

Successful run:

```text
Run ID: 33149679029
Job ID: 98778512122
Conclusion: SUCCESS
```

### 3.3 Talos maintenance discovery

Workflow:

```text
.github/workflows/hci-talos-discovery.yml
```

Successful run:

```text
Run ID: 33150616365
Job ID: 98781486691
Head: 933f6ef349af643f6b269cf651314a5bb832c29d
Conclusion: SUCCESS
Completed: 2026-08-28 07:15:04 UTC
```

All discovery steps passed:

```text
Diagnose runner identity proxy DNS and HTTPS       PASS
Install and verify pinned talosctl                 PASS
Record mounted Talos ISO fingerprint               PASS
Verify node Talos versions in maintenance mode     PASS
Discover disks links addresses and routes          PASS
Confirm cluster is not already bootstrapped        PASS
Final diagnostics                                  PASS
```

---

## 4. Hyper-V host / runner — verified facts

Runner and host:

```text
Runner name: TESTSER
Machine name: TESTSER
Runner identity: NT AUTHORITY\SYSTEM
Runner version: 2.336.0
Architecture: Windows X64
PowerShell: 5.1.26100.33296
Elevated administrator: True
Logical processors: 44
Hyper-V live migration: False
```

The GitHub runner has enough privilege to execute Hyper-V administration commands.

Verified Hyper-V cmdlets include:

```powershell
Get-VM
Start-VM
Set-VMProcessor
Get-VHD
```

---

## 5. Hyper-V network topology — verified

```text
Hyper-V switch: Cozystack-NAT
Switch type: Internal
Windows NAT name: Cozystack-NAT
NAT prefix: 10.10.10.0/24
Host vEthernet gateway address: 10.10.10.1/24
Host physical management IP observed: 172.28.0.57/26
```

VM MAC spoofing is enabled. DHCP Guard and Router Guard were off during discovery.

Planned cluster addressing:

```text
VIP  : 10.10.10.10
sen1 : 10.10.10.11/24
sen2 : 10.10.10.12/24
sen3 : 10.10.10.13/24
GW   : 10.10.10.1
```

The gateway is no longer an assumption: Talos route discovery on all three nodes showed the gateway `10.10.10.1` on the active interface.

---

## 6. VM inventory — verified

| VM | IP | vCPU | RAM | OS VHDX | Data VHDX | MAC | State at discovery |
|---|---|---:|---:|---:|---:|---|---|
| `sen1` | `10.10.10.11` | 10 | 32 GiB | 100 GiB | 300 GiB | `00:15:5d:0a:0a:11` | Running / normal |
| `sen2` | `10.10.10.12` | 10 | 32 GiB | 100 GiB | 300 GiB | `00:15:5d:0a:0a:12` | Running / normal |
| `sen3` | `10.10.10.13` | 10 | 32 GiB | 100 GiB | 300 GiB | `00:15:5d:0a:0a:13` | Running / normal |

All three:

```text
Generation: 2
DynamicMemoryEnabled: False
ExposeVirtualizationExtensions: True
Secure Boot: Off
Talos ISO attached at SCSI 0:2
```

VHDX paths:

```text
C:\HyperV\Cozystack\sen1\sen1-OS-100GB.vhdx
C:\HyperV\Cozystack\sen1\sen1-DATA-300GB.vhdx
C:\HyperV\Cozystack\sen2\sen2-OS-100GB.vhdx
C:\HyperV\Cozystack\sen2\sen2-DATA-300GB.vhdx
C:\HyperV\Cozystack\sen3\sen3-OS-100GB.vhdx
C:\HyperV\Cozystack\sen3\sen3-DATA-300GB.vhdx
```

At initial inventory the dynamic disks were essentially unallocated (~4 MiB backing file each), consistent with blank disks before installation.

---

## 7. Cozystack v1.6.2 ISO provenance — VERIFIED EXACT MATCH

Mounted lab image:

```text
Path: C:\HyperV\Cozystack\ISO\metal-amd64.iso
Size: 543502336 bytes
SHA256: d925b18dde9262adbb0804a98a8161b7ebca16bf362c70a1bd40530281d519d6
```

Official `cozystack/cozystack` v1.6.2 GitHub release metadata reports for `metal-amd64.iso`:

```text
Size: 543502336 bytes
SHA256: d925b18dde9262adbb0804a98a8161b7ebca16bf362c70a1bd40530281d519d6
```

Result:

```text
LAB ISO == OFFICIAL COZYSTACK v1.6.2 METAL ISO: VERIFIED
```

Do not replace this ISO unless intentionally testing another build/version.

---

## 8. Talos tooling — verified

Pinned local binary:

```text
C:\hci-tools\talosctl.exe
```

Verified file size observed:

```text
99,392,512 bytes
```

Verified SHA256:

```text
87289b89abc444e9428d067f4e4097757148f4c3283491444ef4cceb9cd58b07
```

Client version output:

```text
Client:
  Tag:        v1.13.6
  SHA:        04318854
  Go version: go1.26.5
  OS/Arch:    windows/amd64
```

The workflow checksum matches the official Sidero Labs Talos v1.13.6 Windows amd64 release asset digest.

---

## 9. Talos server versions — all three VERIFIED

Raw evidence:

```text
10.10.10.11
Server:
  NODE:    10.10.10.11
  Tag:     v1.13.6
  SHA:     04318854
  OS/Arch: linux/amd64

10.10.10.12
Server:
  NODE:    10.10.10.12
  Tag:     v1.13.6
  SHA:     04318854
  OS/Arch: linux/amd64

10.10.10.13
Server:
  NODE:    10.10.10.13
  Tag:     v1.13.6
  SHA:     04318854
  OS/Arch: linux/amd64
```

All three nodes booted the expected Talos release embedded in the Cozystack v1.6.2 image.

---

## 10. Talos disk discovery — exact device identities

### sen1 / 10.10.10.11

```text
sda  107 GB  rw  storvsc_host  WWID naa.600224806f287aeacd4f9e6329e29270  Virtual Disk
sdb  322 GB  rw  storvsc_host  WWID naa.600224806dc058308dd8a3bf014a297c  Virtual Disk
sr0  544 MB  ro  storvsc_host                                      Virtual DVD-ROM
```

### sen2 / 10.10.10.12

```text
sda  107 GB  rw  storvsc_host  WWID naa.60022480b49d2169f5708f59478f5f15  Virtual Disk
sdb  322 GB  rw  storvsc_host  WWID naa.600224807175cdc319d108c6c7383188  Virtual Disk
sr0  544 MB  ro  storvsc_host                                      Virtual DVD-ROM
```

### sen3 / 10.10.10.13

```text
sda  107 GB  rw  storvsc_host  WWID naa.600224803650253d9f3d59ac3e984736  Virtual Disk
sdb  322 GB  rw  storvsc_host  WWID naa.6002248070d1f838aed76ca81fff39a0  Virtual Disk
sr0  544 MB  ro  storvsc_host                                      Virtual DVD-ROM
```

Interpretation for planned install:

```text
sda = Talos OS/install target
sdb = dedicated HCI / workload storage disk
sr0 = Cozystack v1.6.2 boot ISO
```

Do not select disks by a fragile generic size-only selector if a stable WWID selector is supported by the intended Talos/Cozystack install configuration. Prefer stable identity where practical.

---

## 11. Talos active NIC names and MAC addresses

### sen1

```text
Interface: enx00155d0a0a11
MAC:       00:15:5d:0a:0a:11
Oper:      up
Link:      true
IPv4:      10.10.10.11/24
```

### sen2

```text
Interface: enx00155d0a0a12
MAC:       00:15:5d:0a:0a:12
Oper:      up
Link:      true
IPv4:      10.10.10.12/24
```

### sen3

```text
Interface: enx00155d0a0a13
MAC:       00:15:5d:0a:0a:13
Oper:      up
Link:      true
IPv4:      10.10.10.13/24
```

Talos also exposed default/down pseudo interfaces such as `bond0`, `dummy0`, `ip6tnl0`, `lo`, `sit0`, `teql0`, and `tunl0`. Do not confuse those with the active management NIC.

---

## 12. Talos routes — gateway verified

For each node the discovered routes included:

```text
Connected network: 10.10.10.0/24
Default gateway:    10.10.10.1
Active link:        node-specific enx00155d0a0a1X
Metric:             1024
```

Example from sen1:

```text
10.10.10.0/24 -> enx00155d0a0a11
(default)      -> gateway 10.10.10.1 via enx00155d0a0a11
```

This proves the existing maintenance-mode networking is consistent with the Hyper-V internal NAT design.

---

## 13. Endpoint state before bootstrap

Final successful discovery diagnostics:

```text
10.10.10.11 ICMP=True TCP50000=True TCP6443=False
10.10.10.12 ICMP=True TCP50000=True TCP6443=False
10.10.10.13 ICMP=True TCP50000=True TCP6443=False
```

Neighbor state:

```text
10.10.10.11 -> 00-15-5D-0A-0A-11 Reachable
10.10.10.12 -> 00-15-5D-0A-0A-12 Reachable
10.10.10.13 -> 00-15-5D-0A-0A-13 Reachable
```

The explicit blank-cluster gate printed:

```text
No Kubernetes API detected. Nodes remain safe for planned bootstrap.
```

VIP state from the preceding Hyper-V gate:

```text
10.10.10.10 ICMP=False
Neighbor 10.10.10.10 -> 00-00-00-00-00-00 Incomplete
```

This is expected before VIP/control-plane bootstrap.

---

## 14. Runner outbound connectivity / previous download issue — RESOLVED

The self-hosted service runs as `NT AUTHORITY\SYSTEM`, so interactive-user PATH/proxy assumptions are unsafe.

Verified WinHTTP state:

```text
Direct access (no proxy server).
```

A non-HTTP environment variable exists:

```text
wlp_proxy_PROD_config_path=C:\ProgramData\wlpagent\proxy
```

Do not treat this variable as an HTTP(S) proxy without additional evidence.

DNS successfully resolved:

```text
github.com
api.github.com
objects.githubusercontent.com
release-assets.githubusercontent.com
```

TCP/443 succeeded to all four endpoints.

`curl.exe` is present:

```text
C:\WINDOWS\system32\curl.exe
curl 8.16.0 (Windows)
Schannel
```

A bounded HEAD request to the Talos release returned HTTP 200 and exit code 0.

The earlier apparent tool-download hang was resolved by:

1. using `curl.exe`, not the PowerShell `curl` alias;
2. adding `--connect-timeout 10`;
3. adding `--max-time 120`;
4. adding retry limits;
5. checksum-verifying the binary;
6. reusing an already verified binary from `C:\hci-tools`.

Persistent egress diagnostic file created on the runner:

```text
C:\hci-diagnostics\egress-33150616365.txt
```

Observed size:

```text
16876 bytes
```

---

## 15. Important PowerShell 5.1 behavior discovered

Do not use bare:

```powershell
curl
```

PowerShell 5.1 may resolve it to the `Invoke-WebRequest` alias.

Use:

```powershell
curl.exe --version
```

The previous bad diagnostic caused:

```text
WARNING: The remote name could not be resolved: 'version'
```

because `curl version` was interpreted by the PowerShell alias as a request for a host called `version`.

---

## 16. Diagnostic performance issue discovered

`Test-NetConnection -Port 6443` takes a long time when the port is intentionally closed. In run `33150616365`:

- blank-cluster confirmation took ~42 seconds for three nodes;
- final diagnostics took ~75 seconds.

This is not a cluster failure. It is Windows `Test-NetConnection` timeout behavior.

For frequent CI probes, use a bounded .NET TCP helper instead:

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
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
      return $false
    }
    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

Test-TcpPortFast -ComputerName 10.10.10.11 -Port 50000 -TimeoutMs 3000
Test-TcpPortFast -ComputerName 10.10.10.11 -Port 6443 -TimeoutMs 3000
```

The workflow should be converted to this bounded helper before repeated lab/soak use.

---

## 17. Commands to reproduce the verified Talos discovery

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

---

## 18. Commands to reproduce Hyper-V inventory

```powershell
$names = 'sen1','sen2','sen3'

foreach ($name in $names) {
  Write-Host "===== $name ====="
  Get-VM -Name $name | Format-List Name,State,Status,Generation,ProcessorCount,MemoryStartup,DynamicMemoryEnabled
  Get-VMProcessor -VMName $name | Format-List Count,ExposeVirtualizationExtensions
  Get-VMMemory -VMName $name | Format-List Startup,DynamicMemoryEnabled
  Get-VMNetworkAdapter -VMName $name | Format-List Name,SwitchName,MacAddress,MacAddressSpoofing,IPAddresses
  Get-VMDvdDrive -VMName $name | Format-List ControllerNumber,ControllerLocation,Path
  Get-VMFirmware -VMName $name | Format-List SecureBoot,SecureBootTemplate,BootOrder
  Get-VMHardDiskDrive -VMName $name | ForEach-Object {
    Get-VHD -Path $_.Path | Format-List Path,VhdType,VhdFormat,Size,FileSize
  }
}
```

Host network:

```powershell
Get-VMSwitch | Format-Table Name,SwitchType,NetAdapterInterfaceDescription,AllowManagementOS -AutoSize
Get-NetNat | Format-Table Name,InternalIPInterfaceAddressPrefix,Active -AutoSize
Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceAlias,IPAddress
Get-NetRoute -AddressFamily IPv4 | Sort-Object InterfaceIndex,DestinationPrefix
Get-NetNeighbor -AddressFamily IPv4 | Sort-Object InterfaceIndex,IPAddress
```

---

## 19. Commands for runner egress troubleshooting

Run them through Actions, not only from an interactive administrator console, because the runner executes as SYSTEM.

```powershell
$ErrorActionPreference = 'Continue'
whoami
$PSVersionTable
$env:PATH -split ';'
netsh winhttp show proxy
Get-ChildItem Env: | Where-Object Name -Match 'proxy'

foreach ($hostName in 'github.com','api.github.com','objects.githubusercontent.com','release-assets.githubusercontent.com') {
  Resolve-DnsName $hostName
  Test-NetConnection $hostName -Port 443
}

Get-Command curl.exe
curl.exe --version
curl.exe -I -L --connect-timeout 10 --max-time 30 https://github.com/siderolabs/talos/releases/tag/v1.13.6

Get-ChildItem C:\hci-tools -Force
Get-ChildItem C:\hci-diagnostics -Force
```

Do not disable TLS verification to work around download problems.

---

## 20. Current safe state — IMPORTANT

At the successful discovery checkpoint:

```text
All three VMs: Running
Talos maintenance API: reachable
Talos version: v1.13.6 on all three
Cozystack v1.6.2 ISO: exact official digest match
OS target disk: sda on each node
HCI/data disk: sdb on each node
Node static IPs: verified
Default gateway: verified 10.10.10.1
Kubernetes API: not running
VIP: not owned
Cluster bootstrap: NOT YET PERFORMED
```

Therefore this lab is in a clean pre-bootstrap maintenance state.

---

## 21. Immediate next execution sequence

Do these in this order.

### Step 1 — Fetch current repository state

Before any change:

```text
Fetch branch feat/hci-virtualization-v1.6.2-test HEAD.
Fetch latest HCI v1.6.2 Gate run.
Fetch latest HCI Talos Discovery run.
```

Never assume `933f6ef...` is still HEAD.

### Step 2 — Read Cozystack v1.6.2 installation source from this repository

Do not invent Talos machine config from memory. Inspect the v1.6.2 installation/Talm preset and current branch modifications first.

Determine exactly:

- supported `talm init --preset cozystack` path for v1.6.2;
- Talos machine install disk selector;
- VIP configuration field;
- cluster endpoint value;
- required Talos extensions;
- Cozystack image/image-factory references;
- storage preparation expected for the second disk;
- Kubernetes version bundled by Cozystack v1.6.2.

### Step 3 — Create an automated preflight gate before applying machine config

It must hard fail unless:

```text
sen1/2/3 Talos server version == v1.13.6
sen1/2/3 maintenance API reachable
sda is approximately 107 GB
sdb is approximately 322 GB
active NIC MAC matches expected node MAC
IP matches expected node IP
route gateway == 10.10.10.1
VIP 10.10.10.10 is unowned before bootstrap
TCP/6443 is closed before first bootstrap
Cozystack ISO SHA256 matches official v1.6.2 digest
```

### Step 4 — Generate configs and archive only non-secret evidence

Do not commit Talos secrets, talosconfig private material or kubeconfig credentials.

If generated configs contain secrets, keep them on the runner under a protected path and/or GitHub Actions Secrets, not in repository history or Actions logs.

### Step 5 — Apply Talos machine configs safely

Expected targets:

```text
sen1 -> 10.10.10.11 -> sda -> enx00155d0a0a11
sen2 -> 10.10.10.12 -> sda -> enx00155d0a0a12
sen3 -> 10.10.10.13 -> sda -> enx00155d0a0a13
VIP  -> 10.10.10.10
GW   -> 10.10.10.1
```

Do not touch `sdb` as the OS install target.

### Step 6 — Bootstrap exactly once

After configs have converged:

- verify Talos API with secure talosconfig;
- bootstrap etcd/control plane once;
- wait for VIP ownership;
- wait for Kubernetes API on `10.10.10.10:6443`;
- obtain kubeconfig without logging secrets;
- verify all nodes and core control-plane services.

### Step 7 — Install/validate Cozystack from the modified branch

The purpose of this lab is to validate this fork/branch, not merely upstream binaries.

Need an explicit build/deploy strategy for branch-specific controllers/charts/images. Record image digests and Git SHA in evidence.

---

## 22. Repository production-readiness blockers that still require code work

Do not let successful Talos discovery hide remaining code gates.

### A. VMNetwork deletion/reference TOCTOU

Required closure:

- VM create/update rejects missing VMNetwork;
- VM create/update rejects VMNetwork with `deletionTimestamp`;
- VMNetwork deletion blocks while VM references exist;
- cross-tenant references fail closed;
- concurrent create/delete test demonstrates no unsafe race.

### B. NetworkFabric permanent-node-loss / finalizer recovery

Current fail-closed finalizer behavior is safe but may stick forever if a selected node is truly gone.

Required controlled recovery:

- cluster-admin only;
- references always block;
- transient Talos/network failure cannot trigger bypass;
- only definitively removed Kubernetes node can be orphan-skipped;
- status/audit evidence records exactly which cleanup was skipped and why.

### C. Snapshot/backup/restore hard gates

Audit existing Cozystack backup framework before introducing a new one.

Must prove:

- stable immutable VM UID lineage;
- snapshot cannot silently retarget to a recreated same-name VM;
- tenant isolation;
- validated repository/target/credential refs;
- retention semantics;
- restored disks independent of source PVCs/disks;
- restore network/storage dependencies revalidated;
- interrupted operation recovery;
- finalizer/reference cleanup;
- explicit timeout/error states;
- delete-source-then-restore;
- cross-tenant restore denial.

---

## 23. Real lab gates required before a 99% claim

### Talos / cluster lifecycle

- install to sda on all three nodes
- reboot from installed disk without ISO dependency
- three-node control plane healthy
- VIP failover
- etcd health/quorum
- node reboot one at a time
- unexpected node power-off
- node rejoin
- config drift/reconcile
- upgrade
- rollback

### KubeVirt / VM lifecycle

- Linux VM create/start/stop/reboot/delete
- Windows Server installation
- installer ISO + VirtIO ISO two-CD flow
- eject/remount optical media
- data disk persistence
- VM restart after controller restart
- VM reschedule
- live migration sen1 -> sen2 -> sen3
- dedicated migration network
- migration interruption/rollback

### VM networking

- tenant network creation
- NetworkFabric-backed VLAN
- wrong fabric rejection
- wrong bridge rejection
- MTU mismatch rejection
- deleting-network reference protection
- concurrent VMNetwork deletion / VM create
- cross-tenant reference denial

### NetworkFabric failure injection

- TryApplied controller crash
- Verified controller crash
- Talos API unavailable
- selected node reboot during transaction
- stale owned VLAN cleanup
- stale owned bridge cleanup
- management-interface protection
- bad topology rejection
- rollback verify
- restart recovery

### Storage / backup / restore

- second disk initialized for chosen HCI/storage backend
- create VM disk
- write data and hash it
- snapshot
- mutate data
- restore
- verify restored hash
- prove restored disk independence
- delete source VM then restore
- failure during backup
- failure during restore
- retention cleanup
- credential/tenant isolation

### Upgrade / rollback

- create representative workloads
- record hashes/state
- upgrade platform/controllers
- verify workloads/data/network
- reboot nodes
- rollback supported components
- prove data/state retained

### Soak

After functional/destructive gates pass, run repeated reconciliation, migration, VM lifecycle and storage I/O cycles long enough to expose leaks, stuck finalizers and unstable retries.

---

## 24. Evidence matrix at this checkpoint

| Gate | Status | Evidence |
|---|---|---|
| Repository HCI gate | PASS | Run `33150616354`, job `98781544183` |
| Hyper-V runner admin | PASS | Run `33149679029`, job `98778512122` |
| VM sizing | PASS | Hyper-V run |
| Nested virtualization | PASS | Hyper-V run |
| ISO attachment | PASS | Hyper-V run |
| Official Cozystack v1.6.2 ISO digest | PASS | Lab hash + official release digest exact match |
| Node ICMP | PASS | Hyper-V + discovery runs |
| Talos TCP/50000 | PASS | Discovery run |
| Talos v1.13.6 | PASS | Discovery run `33150616365` |
| OS disk discovery | PASS | `sda`, ~107 GB on all nodes |
| HCI disk discovery | PASS | `sdb`, ~322 GB on all nodes |
| NIC identity | PASS | node-specific `enx...` + MAC verified |
| Static IP | PASS | `10.10.10.11/12/13` verified |
| Default gateway | PASS | `10.10.10.1` verified |
| Blank-cluster precondition | PASS | 6443 closed on all nodes |
| VIP pre-bootstrap unowned | PASS | no ARP owner / no endpoint |
| Talos install to disk | PENDING | next phase |
| Secure Talos API after install | PENDING | next phase |
| etcd bootstrap | PENDING | next phase |
| VIP active | PENDING | next phase |
| Kubernetes API | PENDING | next phase |
| Cozystack installed from test branch | PENDING | next phase |
| KubeVirt/CDI/Multus | PENDING | E2E |
| Linux VM | PENDING | E2E |
| Windows/two-ISO | PENDING | E2E |
| VM live migration | PENDING | E2E |
| NetworkFabric destructive rollback | PENDING | failure injection |
| VMNetwork TOCTOU closure | PENDING | code + E2E |
| Backup/snapshot/restore | PENDING | code + E2E |
| Upgrade/rollback | PENDING | destructive E2E |
| Soak | PENDING | final phase |

---

## 25. Safety constraints for next session

1. Never print or commit GitHub PATs, Talos secrets, kubeconfig private keys, registry credentials or backup credentials.
2. Never disable TLS verification to make a download work.
3. Never use `sdb` as Talos OS target unless the test explicitly intends data destruction.
4. Never force-power-off healthy nodes merely to re-run a CI inventory step.
5. Do not manually remove NetworkFabric finalizers as a shortcut.
6. Before destructive tests, record exact workload/data hashes and rollback expectations.
7. Always prove which Git SHA/image digest is actually deployed; do not assume the running cluster uses the test branch.
8. Do not claim 99%/production-ready until evidence exists for all P0/P1 code gates and real lab destructive/rollback/backup/restore/upgrade tests.

---

## 26. Exact continuation prompt for a new ChatGPT/Codex session

```text
Open adaptgurus/cozystack and use branch feat/hci-virtualization-v1.6.2-test.

READ HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT_V2.md FIRST.
Then read HCI_HYPERV_LAB_NEXT_SESSION_SUPER_CONTEXT.md and the earlier HCI virtualization super-context files if present.

Fetch the actual current branch HEAD and latest GitHub Actions runs before changing anything. Do not create another branch and do not restart from conceptual discussion.

The Hyper-V lab is already validated. sen1/sen2/sen3 are running at 10.10.10.11/12/13, Talos maintenance API TCP/50000 is healthy, all nodes report Talos v1.13.6, sda is the ~107GB OS disk, sdb is the ~322GB HCI/data disk, the active NICs and MACs are recorded in V2, gateway 10.10.10.1 is verified, VIP is 10.10.10.10, Kubernetes 6443 is still closed, and the mounted ISO exactly matches the official Cozystack v1.6.2 release digest.

Repository HCI gate run 33150616354 and Talos discovery run 33150616365 passed on commit 933f6ef349af643f6b269cf651314a5bb832c29d.

Continue from the pre-bootstrap state. First inspect the current branch installation/Talm/Cozystack v1.6.2 source and derive the supported Talos machine configuration from repository truth, including install disk, VIP, cluster endpoint, required extensions and storage preparation. Add a fail-closed preflight gate using the exact discovered device/network identities before applying any machine config.

Then bootstrap the three-node lab safely, prove VIP/Kubernetes/etcd health, deploy the modified branch artifacts with traceable Git SHA/image digests, and continue the VM/KubeVirt/CDI/Multus/NetworkFabric/backup/restore/failure/upgrade gates in V2.

In parallel, finish the remaining repository P0/P1 logic gaps: VMNetwork deletion/reference TOCTOU, controlled NetworkFabric orphan-finalizer recovery, and snapshot/backup/restore lineage/isolation/independence/error handling.

Convert every real failure into a reproducible regression test or CI guard where appropriate. Commit permanent fixes directly to the same branch.

Do not declare production-ready or 99% until the real destructive/failure/rollback/backup/restore/upgrade/soak evidence is green.
```
