# VM Network

Creates a tenant-scoped Multus `NetworkAttachmentDefinition` for attaching KubeVirt virtual machines to an external Linux bridge.

The selected Linux bridge must exist on every KubeVirt-capable node on which the VM may run or migrate. VLAN tagging is owned by this chart when `vlan` is non-zero. Guest addressing is external to this chart by default and can be provided by DHCP or configured inside the guest.
