# HCI storage engine core

`storageengine` is the product-domain boundary between physical/external storage and customer-facing Storage Profiles.

The first implementation slice is intentionally **side-effect free**:

- discovers StorageClasses, CSI drivers and devices/LUNs as inventory only;
- safely adopts the existing `replicated` and `local` StorageClasses without recreating them;
- keeps Kubernetes StorageClass names as an implementation detail behind Storage Backends and Storage Profiles;
- gates new HCI/ZFS/LVM/LVM Thin/NFS/iSCSI/FC/NVMe/TCP/External-CSI backend creation on an explicit provider capability probe;
- validates profile purposes, topology, volume mode, expansion, provisioning and replication against proven backend capabilities.

Discovery must never format, wipe, repartition, initialize ZFS/LVM/LINSTOR, or otherwise modify a discovered device. Provider-specific mutation belongs in separate controllers with explicit safety checks and verified WWID/device identity.
