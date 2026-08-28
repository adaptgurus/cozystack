# LayerSentry HCI Talos Image Audit

This document defines the release and certification boundary for the LayerSentry HCI Talos image based on Talos v1.13.6.

## Release-blocking host capabilities

| Capability | Image status | Notes |
| --- | --- | --- |
| Linux bridge | PASS | Talos/Linux kernel capability; configured through Talos networking resources. |
| bond/LACP | PASS | Talos/Linux kernel capability; configured through Talos networking resources. |
| VLAN 802.1Q | PASS | Talos/Linux kernel capability; configured through Talos networking resources. |
| nftables/netfilter | RETAINED FOR KUBERNETES DATAPATH | The kernel/userspace capability remains available because Cilium/Kubernetes may require netfilter/iptables compatibility paths. LayerSentry does not use it as a default host ingress firewall. |
| Talos host ingress filtering | DISABLED / ACCEPT | `NetworkDefaultActionConfig` explicitly sets `ingress: accept`, so the generic LayerSentry image does not impose a Talos host-ingress deny policy. External fabric/firewall policy remains site policy. |
| conntrack | PASS | Talos/Linux kernel capability. |
| Device Mapper | PASS | Talos/Linux kernel capability. |
| DM-Multipath | PASS | `multipath-tools` is baked into the image and `layersentry-hci-machine-config.yaml` loads `dm_multipath` + `dm_round-robin` and configures `multipathd`. Array-specific WWID/product overrides remain site/controller policy. |
| `lsscsi` | PASS | Deliberately supplied by the Sidero `trident-iscsi-tools` Talos extension. |
| iSCSI initiator | PASS | `iscsi-tools` provides `iscsid`/`iscsiadm`; stock Talos kernel has iSCSI/TCP initiator support. |
| iSCSI target daemon | PASS - USERSPACE TARGET | LayerSentry custom system extension contains Alpine `scsi-tgt` (`tgtd`, `tgtadm`, `tgtimg`) and runs `tgtd` as a privileged Talos extension service with host `/dev` access. No LUN is exposed automatically; target/LUN/ACL lifecycle is controller policy. This avoids depending on the stock kernel's disabled Linux LIO `CONFIG_TARGET_CORE`. |
| NFS v3/v4.x client | PASS | Sidero `nfs-utils` + `nfsrahead` are baked into the image; stock Talos kernel has NFS client support. |
| NFS server kernel | PASS | Sidero `nfsd` extension plus explicit `nfsd` module loading are included. |
| NFS server/export engine | PASS - NO DEFAULT EXPORT | LayerSentry custom NFS server extension contains `exportfs`, `rpc.nfsd`, `rpc.mountd`, `rpc.statd` and rpcbind dependencies in an isolated extension-service rootfs. The service exports nothing until LayerSentry writes an explicit export policy, preventing an ISO from exposing arbitrary disks by default. |
| NVMe/TCP | PASS | `nvme-cli` is baked into the image and stock Talos kernel provides NVMe/TCP. |
| NVMe/FC host | PASS - HARDWARE CERTIFICATION REQUIRED | Exact Talos v1.13.6 kernel configuration enables `CONFIG_NVME_FC=y`. QLogic FC, Emulex LPFC and QEDF-related FC drivers are available, while the image includes `nvme-cli` and QLogic firmware. Real HBA, fabric zoning/login, namespace discovery and failover still require lab certification. |
| LLDP | PASS | `lldpd` is baked into the image. |
| Ethernet link/driver operations | PASS WITH TALOS API | Talos exposes NIC configuration/status through its API/resources. A general-purpose interactive `ethtool` host CLI is not deliberately installed. |

## Hardware-dependent capabilities

| Capability | Image status | Notes |
| --- | --- | --- |
| SR-IOV | CONDITIONAL PASS | Kernel capability is present; requires compatible NIC/firmware, enabled SR-IOV and Kubernetes/operator/device-plugin policy. |
| VFIO PCI passthrough | CONDITIONAL PASS | Kernel capability is present; actual device binding requires IOMMU and Talos/KubeVirt PCI rebind configuration. |
| RDMA/RoCE | CONDITIONAL PASS | Talos kernel provides RDMA/InfiniBand and Mellanox RDMA support. Workload-side RDMA libraries/device plugins/operators remain cluster/hardware policy. |
| NVMe/RDMA | CONDITIONAL PASS | Talos kernel provides NVMe/RDMA and `nvme-cli` is present; requires compatible RDMA NIC/SAN and RDMA device exposure. |
| GPU passthrough | CONDITIONAL PASS | NVIDIA production open kernel modules/toolkit are present; VFIO passthrough remains device/IOMMU policy. |
| GPUDirect RDMA | CONDITIONAL PASS | `nvidia-gdrdrv-device` plus NVIDIA production driver/toolkit are present. Requires supported GPU, RDMA NIC, topology, drivers and Kubernetes GPU/RDMA configuration. |
| NVIDIA NVLink/NVSwitch Fabric Manager | OPTIONAL / NOT BAKED | `nvidia-fabricmanager-production` is required only on NVIDIA platforms that need NVLink/NVSwitch Fabric Manager; it is intentionally not made a universal host service. |
| Fibre Channel SCSI | HARDWARE CERTIFICATION REQUIRED | Stock Talos kernel includes FC transport/QLogic/LPFC-related support and the image contains QLogic firmware plus SCSI/multipath tooling. Full HBA zoning/login/failover lifecycle must be certified against real FC hardware and SAN. |

## Explicit limitations / separate lifecycle work

| Capability | Status | Reason |
| --- | --- | --- |
| iSER | NOT ENABLED IN STOCK TALOS v1.13.6 | `CONFIG_INFINIBAND_ISER` is disabled in the stock Talos kernel. Enabling kernel iSER requires a custom Talos kernel. `scsi-tgt` can be built with userspace iSER support separately, but this release does not claim it. |
| Linux LIO/targetcli iSCSI target | NOT USED | Exact Talos v1.13.6 has `CONFIG_TARGET_CORE` disabled. LayerSentry therefore uses userspace `tgtd` instead of falsely shipping `targetcli` without its kernel backend. |
| Automatic iSCSI LUN/ACL provisioning | CONTROLLER POLICY | The target daemon is available, but the ISO intentionally creates no targets or LUNs automatically. LayerSentry must bind only explicitly selected volumes and enforce initiator ACL/CHAP policy. |
| Automatic NFS exports | CONTROLLER POLICY | The server engine is available, but the ISO intentionally has an empty controller-owned export policy. LayerSentry must choose the backing path, clients, squash mode and export options. |
| Ceph/RBD/CephFS | NOT PART OF CURRENT HCI ENGINE | LayerSentry HCI is oriented around LINSTOR/DRBD/ZFS and external storage integrations. |
| SMB/CIFS managed storage | NOT PROVIDED | Requires a separate service, credentials and lifecycle controller. |

## Release rule

A LayerSentry HCI Talos release may be published only after CI successfully builds both LayerSentry custom storage-server extensions, validates their required binaries and Talos service definitions, builds the Talos ISO, verifies every required official extension in the generated digest-pinned profile, verifies embedded multipath/NFSD/open-ingress configuration, generates SHA-256 checksums, and uploads the full ISO plus audit metadata as GitHub Release assets.

Hardware-dependent items remain *image-capable* rather than production-certified until real HBA/NIC/GPU/SAN testing proves discovery, failover, rollback and recovery behavior.
