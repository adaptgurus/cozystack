# LayerSentry HCI Talos Image Audit

This document defines the certification boundary for the LayerSentry HCI Talos image based on Talos v1.13.6.

## Release-blocking host capabilities

| Capability | Image status | Notes |
| --- | --- | --- |
| Linux bridge | PASS | Talos/Linux kernel capability; configured through Talos networking resources. |
| bond/LACP | PASS | Talos/Linux kernel capability; configured through Talos networking resources. |
| VLAN 802.1Q | PASS | Talos/Linux kernel capability; configured through Talos networking resources. |
| nftables | PASS | Talos/Linux kernel capability. |
| conntrack | PASS | Talos/Linux kernel capability. |
| Device Mapper | PASS | Talos/Linux kernel capability. |
| DM-Multipath | PASS | `multipath-tools` is baked into the image and `layersentry-hci-machine-config.yaml` loads `dm_multipath` + `dm_round-robin` and configures `multipathd`. Array-specific WWID/product overrides remain site/controller policy. |
| `lsscsi` | PASS | Deliberately supplied by the Sidero `trident-iscsi-tools` Talos extension. |
| iSCSI initiator | PASS | `iscsi-tools` provides `iscsid`/`iscsiadm`; stock Talos kernel has iSCSI/TCP support. |
| NFS v3/v4.x client | PASS | `nfs-utils` + `nfsrahead` are baked into the image; stock Talos kernel has NFS client support. |
| NVMe/TCP | PASS | `nvme-cli` is baked into the image and stock Talos kernel provides NVMe/TCP. |
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
| Fibre Channel SCSI | HARDWARE CERTIFICATION REQUIRED | Stock Talos kernel includes FC transport/QLogic support and the image contains QLogic firmware plus SCSI/multipath tooling. Full HBA zoning/login/failover lifecycle must be certified against real FC hardware and SAN. |

## Explicit non-capabilities / separate services

| Capability | Status | Reason |
| --- | --- | --- |
| iSER | NOT AVAILABLE IN STOCK TALOS v1.13.6 | `CONFIG_INFINIBAND_ISER` is disabled in the stock kernel. Enabling it requires a custom Talos kernel build, not a normal system extension. |
| NVMe/FC | NOT AVAILABLE IN STOCK TALOS v1.13.6 | Stock kernel does not enable NVMe/FC. |
| iSCSI target | NOT PROVIDED | Initiator support does not create an iSCSI target service. |
| NFS server/export lifecycle | NOT PROVIDED BY HOST IMAGE | NFS client utilities are not an HCI NFS server/controller. |
| Ceph/RBD/CephFS | NOT PART OF CURRENT HCI ENGINE | LayerSentry HCI is currently oriented around LINSTOR/DRBD/ZFS and external storage integrations. |
| SMB/CIFS managed storage | NOT PROVIDED | Requires a separate service, credentials and lifecycle controller. |

## Release rule

A LayerSentry HCI Talos release may be published only after CI successfully builds the ISO, verifies every required extension in the generated digest-pinned profile, verifies the embedded multipath configuration, generates a SHA-256 checksum, and uploads the full ISO plus audit metadata as GitHub Release assets.
