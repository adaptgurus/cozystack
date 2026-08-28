# VM Network

Creates a tenant-scoped Multus `NetworkAttachmentDefinition` for attaching KubeVirt virtual machines to an external Linux bridge.

The selected Linux bridge must exist on every KubeVirt-capable node on which the VM may run or migrate. For managed physical networks, VLAN tagging is owned by the Talos VLAN interface underneath the Linux bridge; bridge CNI receives the already-presented L2 bridge and therefore does not add a second VLAN tag. Guest addressing is external to this chart by default and can be provided by DHCP or configured inside the guest.

## Parameters
