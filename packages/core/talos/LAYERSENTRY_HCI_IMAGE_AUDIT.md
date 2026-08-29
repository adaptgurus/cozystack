# LayerSentry HCI/dHCI Talos Production Image Audit

This file defines the evidence boundary for the universal LayerSentry Talos v1.13.6 / Linux 6.18.38-talos image. A GitHub release is not production-eligible merely because the imager exits successfully: the release workflow must pass every software gate below. Hardware-dependent paths remain separately certified.

## Exact provenance

- Talos: `v1.13.6`, commit `04318854eb64c90e99308b844b45b26b0077489e`.
- `siderolabs/pkgs`: `d8c80cc52d6c60a25c7ab2a80fa78814c08a04da`.
- `siderolabs/extensions`: `f16e62f2d5927589f62643332dae9c07489cbf47` (signed `v1.13.6` tag).
- Kernel baseline: Linux `6.18.38-talos`.
- LayerSentry kernel delta: stock `# CONFIG_INFINIBAND_ISER is not set` becomes `CONFIG_INFINIBAND_ISER=m`.
- `ib_iser.ko` is added to the exact Talos amd64 module allow-list.
- External/kernel-bearing DRBD, ZFS, NFSD, AMDGPU, i915, Broadcom and NVIDIA module extensions are rebuilt against the same LayerSentry pkgs/kernel build so module signing and symbol versions are not mixed with stock-kernel artifacts.

## Universal storage ownership rule

This ISO is intentionally usable for both HCI and dHCI/external-storage nodes. Capability must never imply ownership.

- Never format, import, export, mount, claim or erase a disk/LUN because it is merely visible.
- SAN identity is WWID/WWN/NQN/serial based; `/dev/sdX` is never authoritative for destructive operations.
- `multipathd` uses `find_multipaths yes` and `user_friendly_names no`; no universal vendor path selector is forced.
- The upstream Talos v1.13.6 ZFS extension starts `zpool import -fal`. LayerSentry rebuilds the ZFS extension against the custom kernel and removes that automatic service while retaining the ZFS module/tools. Pool lifecycle is controller-owned.
- NFS server and iSCSI target capability is installed but dormant until LayerSentry explicitly creates the controller-owned activation marker. A generic NAS/SAN consumer node must not open NFS/RPC/iSCSI-target listeners merely because it booted this ISO.
- The image does not embed a globally open `NetworkDefaultActionConfig`; Talos/Cilium/site policy owns host/fabric security.

## Production software gates

| Capability | Release gate | Hardware boundary |
| --- | --- | --- |
| Linux bridge / VLAN filtering | exact kernel config + installed-node boot | software testable |
| bond/LACP | exact kernel config + installed-node boot | physical LACP switch test still recommended |
| VLAN 802.1Q | exact kernel config | physical fabric test still recommended |
| Cilium eBPF | `kubeProxyReplacement=true`, `bpf.masquerade=true`, `hostLegacyRouting=false`, host firewall enabled | full cluster datapath regression is separate from ISO boot |
| netfilter/conntrack compatibility | retained in kernel | normal Kubernetes datapath remains Cilium/eBPF |
| DM-Multipath / ALUA substrate | `multipath-tools`, `dm_multipath`, stable WWID policy | real array failover/ALUA requires SAN lab |
| iSCSI initiator | `iscsid`, `iscsiadm`, `iscsi-iname`, kernel iSCSI/TCP | real target/login/failover certification required |
| iSCSI target | `tgtd`, `tgtadm`, `tgtimg`; dormant on generic boot | controller lifecycle/HA acceptance required |
| iSER | custom `CONFIG_INFINIBAND_ISER=m`, `ib_iser` packaged and loaded after disk installation | real RDMA NIC/fabric login required |
| NFS client | kernel NFS v3/v4/v4.1/v4.2 + `mount.nfs` | real NAS regression required |
| NFS server/export | rebuilt `nfsd` + complete userspace; dormant on generic boot | export lifecycle/HA acceptance required |
| NVMe local/TCP | exact kernel symbols + `nvme-cli` | target/failover acceptance required |
| NVMe/RDMA | exact kernel/module capability | real RDMA hardware required |
| FC SCSI | `qla2xxx` and `lpfc` kernel capability + QLogic firmware | zoning/login/multipath/failover requires real SAN |
| NVMe/FC | exact NVMe-FC capability | real FC fabric required |
| RDMA/RoCE | core/vendor modules + `rdma`, `ibv_devices`, `ibv_devinfo` | real NIC/switch/PFC/ECN test required |
| SR-IOV | `CONFIG_PCI_IOV=y` | real PF/VF lifecycle required |
| VFIO | VFIO PCI + Intel/AMD IOMMU capability | real passthrough/IOMMU test required |
| GPU passthrough | custom-kernel NVIDIA extension set retained | physical GPU required |
| GPUDirect RDMA prerequisites | NVIDIA GDR + PCI P2P/RDMA prerequisites | supported GPU/NIC/topology required |
| LLDP | `lldpd` binary/extension | physical neighbor validation required |
| `ethtool` | LayerSentry read-only diagnostics extension | physical NIC validation required |
| `lsscsi` | `trident-iscsi-tools` binary gate | software testable |

## Boot/install persistence gate

The production workflow must:

1. Build the exact custom kernel and all selected custom-kernel module packages.
2. Rebuild selected kernel-bearing system extensions from the exact v1.13.6 extension source.
3. Generate digest-pinned profiles and build both `metal-amd64.iso` and `metal-amd64-installer.tar` with Talos Imager.
4. Boot the exact ISO through a legacy/BIOS QEMU path and reach the Talos API.
5. Boot the exact ISO through UEFI, install to a blank virtual disk using the custom installer image, and reach the secured Talos API after installation.
6. Stop that VM and boot the installed disk again with the ISO completely detached.
7. On that disk-only UEFI node verify the exact kernel configuration, `dm_multipath`, DRBD, ZFS, NFSD and `ib_iser` module loading, the complete expected extension inventory, absence of the upstream ZFS auto-import service, and absence of generic NFS/RPC/iSCSI target listeners.
8. Publish the paired installer OCI image to GHCR and record its immutable digest. Installation and upgrades must use the LayerSentry installer digest/tag rather than the stock Sidero installer.
9. Publish ISO + installer checksums and re-download the release assets to verify the published bytes.

## Production certification boundary

A successful software release proves that the universal LayerSentry image is built, boots, installs, persists its custom kernel/extensions, and preserves the software capability required for HCI/dHCI and external NAS/SAN attachment. It does **not** turn virtual QEMU evidence into physical certification. FC zoning/failover, iSER/RoCE, NVMe/RDMA, NVMe/FC, SR-IOV/VFIO, GPU passthrough and GPUDirect RDMA stay hardware-certification items until the corresponding physical lab tests pass.

Secure Boot is not certified by this release profile (`secureboot: false`).
