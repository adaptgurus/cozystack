# VM Template

Captures a halted Cozystack VMInstance as a tenant-local KubeVirt VirtualMachineTemplate through the hardened VMTemplateOperation controller. Copy keeps the source VMInstance. Convert retires it only after the reusable template is verified Ready, optical and one-time bootstrap material has been sanitized, and the source UID/generation still match the preflight checkpoint.

## Parameters

### VM template capture

| Name                  | Description                                                                                                                                                            | Type     | Value  |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------ |
| `sourceVM`            | Tenant-local Cozystack VMInstance to capture. The source must be halted and have no active VMI.                                                                        | `string` | `""`   |
| `mode`                | Copy keeps the source VMInstance. Convert retires it only after the sanitized template is verified Ready and the source UID/generation still match preflight.          | `string` | `Copy` |
| `excludeOpticalMedia` | Exclude installer, VirtIO-driver, rescue and other optical VMDisk attachments from the reusable template. Production template capture requires this to remain enabled. | `bool`   | `true` |
| `description`         | Optional human-readable template description.                                                                                                                          | `string` | `""`   |

