# LayerSentry HCI Talos Image Audit

This document defines the release and certification boundary for the LayerSentry HCI Talos image based on Talos v1.13.6 / Linux 6.18.38-talos.

## Kernel provenance

- Talos tag: `v1.13.6`, upstream commit `04318854eb64c90e99308b844b45b26b0077489e`.
- Talos v1.13.6 pins `siderolabs/pkgs` to `d8c80cc52d6c60a25c7ab2a80fa78814c08a04da`.
- LayerSentry preserves that exact kernel source/config baseline and changes only `CONFIG_INFINIBAND_ISER` from disabled to `m`.
- Talos' amd64 module allow-list is extended with `kernel/drivers/infiniband/ulp/iser/ib_iser.ko` so the module is actually present in the generated initramfs.

## Release-blocking host capabilities

| Capability | Image status | Notes |
| --- | --- | --- |
| Linux bridge | PASS | Talos/Linux kernel capability. |
| bond/LACP | PASS | Talos/Linux kernel capability. |
| VLAN 802.1Q | PASS | Talos/Linux kernel capability. |
| Cilium eBPF | PASS - CONFIG GATED | `kubeProxyReplacement=true`, `bpf.masquerade=true`, and `bpf.hostLegacyRouting=false` are pinned in the Cozystack Cilium values. Runtime cluster E2E remains required. |
| iptables-free normal datapath | PASS - CONFIG GATED | kube-proxy replacement and BPF masquerading are explicit. Netfilter/conntrack compatibility primitives are deliberately retained. |
| DM-Multipath | PASS | `multipath-tools` plus `dm_multipath`, `dm_round-robin`, and managed `multipathd` configuration. |
| `lsscsi` | PASS | Deliberately supplied by `trident-iscsi-tools`. |
| `ethtool` | PASS - TOOLBOX | Pinned Alpine package is present in the LayerSentry HCI tools extension service rootfs. |
| RDMA diagnostics | PASS - TOOLBOX | `rdma`, `ibv_devices`, and `ibv_devinfo` are present in the LayerSentry HCI tools extension rootfs. |
| iSCSI initiator | PASS | `iscsi-tools` supplies `iscsid`/`iscsiadm`; kernel iSCSI/TCP support is release-gated. |
| iSCSI target daemon | PASS - USERSPACE TARGET | LayerSentry custom `scsi-tgt` extension provides `tgtd`, `tgtadm`, and `tgtimg`; no target is exposed automatically. |
| iSER | PASS - CUSTOM KERNEL / HARDWARE E2E REQUIRED | Exact upstream config disables iSER; LayerSentry enables `CONFIG_INFINIBAND_ISER=m`, packages `ib_iser`, embeds module loading, and boot-gates `/proc/config.gz` plus `/proc/modules`. Real RDMA NIC/fabric login still requires hardware certification. |
| NFS v3/v4.x client | PASS | `nfs-utils` + `nfsrahead`. |
| NFS server/export engine | PASS - NO DEFAULT EXPORT | `nfsd` plus custom export userspace service; no reusable ISO export is created automatically. |
| NVMe local/TCP/RDMA/FC | PASS - KERNEL/TOOL GATED | `nvme-cli` and exact kernel symbols are gated. RDMA/FC transports still require real hardware/fabric certification. |
| LLDP | PASS | `lldpd` extension. |
| SR-IOV | CONDITIONAL PASS | `CONFIG_PCI_IOV=y`; hardware/operator policy required. |
| VFIO PCI passthrough | CONDITIONAL PASS | Exact kernel VFIO PCI capability is gated; IOMMU and explicit device binding required. |
| GPU passthrough | CONDITIONAL PASS | NVIDIA production extensions are present; actual VFIO/GPU validation requires hardware. |
| GPUDirect RDMA prerequisites | CONDITIONAL PASS | NVIDIA GDR extension plus `CONFIG_PCI_P2PDMA=y`; topology/NIC/GPU E2E required. |
| Fibre Channel SCSI/NVMe-FC | HARDWARE CERTIFICATION REQUIRED | Exact kernel FC/NVMe-FC capability and QLogic firmware are image-gated; zoning/login/failover require a real SAN. |

## Release rule

A release is publishable only after CI builds the custom Talos iSER kernel, packages `ib_iser`, builds all LayerSentry custom extensions, regenerates digest-pinned Talos profiles, builds the ISO with the custom installer/imager, boots that exact ISO in QEMU, reaches the Talos maintenance API, verifies `CONFIG_INFINIBAND_ISER=m`, verifies `ib_iser` is loaded, verifies the expected extension inventory, and emits SHA-256 checksums. Hardware-dependent RDMA/RoCE/FC/SR-IOV/VFIO/GPU behavior remains image-capable rather than production-certified until physical E2E testing passes.
