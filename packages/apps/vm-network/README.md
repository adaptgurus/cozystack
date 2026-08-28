# VM Network

Creates a tenant-scoped Multus `NetworkAttachmentDefinition` for attaching KubeVirt virtual machines to an external Linux bridge.

The selected Linux bridge must exist on every KubeVirt-capable node on which the VM may run or migrate. For managed physical networks, VLAN tagging is owned by the Talos VLAN interface underneath the Linux bridge; bridge CNI receives the already-presented L2 bridge and therefore does not add a second VLAN tag. Guest addressing is external to this chart by default and can be provided by DHCP or configured inside the guest.

## Parameters

### External VM network

| Name            | Description                                                                                                                                         | Type     | Value   |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------- |
| `bridge`        | Linux bridge on KubeVirt-capable nodes that carries this external VM network.                                                                       | `string` | `""`    |
| `vlan`          | 802.1Q VLAN ID. Use 0 for an untagged/native network. Tagging is performed by the Talos VLAN interface below the Linux bridge, never by bridge CNI. | `int`    | `0`     |
| `mtu`           | Interface MTU. Use 0 to inherit/default; otherwise use 576-9216.                                                                                    | `int`    | `0`     |
| `fabricRef`     | Optional cluster NetworkFabric backing this tenant network. Set together with fabricNetwork for verified node placement.                            | `string` | `""`    |
| `fabricNetwork` | Network name inside fabricRef. Set together with fabricRef.                                                                                         | `string` | `""`    |
| `description`   | Human-readable description of the physical VM network.                                                                                              | `string` | `""`    |
| `promiscMode`   | Enable promiscuous mode on the bridge CNI interface.                                                                                                | `bool`   | `false` |
| `macspoofchk`   | Enable MAC spoof checking when supported by the bridge CNI.                                                                                         | `bool`   | `false` |
| `hairpinMode`   | Enable bridge hairpin mode for this network.                                                                                                        | `bool`   | `false` |

