# Virtual Machine Disk

A Virtual Machine Disk

> `storageClass` is annotated as immutable in the chart schema — see [`docs/storage-immutability.md`](../../../docs/storage-immutability.md) for the contract and which consumers enforce it.

## Parameters

### Common parameters

| Name                | Description                                                                                                                          | Type       | Value        |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ---------- | ------------ |
| `source`            | The source used to create the disk or optical-media object.                                                                          | `object`   | `{}`         |
| `source.image`      | Use a golden disk image from the platform collection.                                                                                | `*object`  | `null`       |
| `source.image.name` | Name of the image to use.                                                                                                            | `string`   | `""`         |
| `source.iso`        | Clone an ISO from the platform ISO Library. This source is always treated as optical media.                                          | `*object`  | `null`       |
| `source.iso.name`   | Name of the platform ISO to use.                                                                                                     | `string`   | `""`         |
| `source.upload`     | Upload local content. Set optical=true when uploading ISO media.                                                                     | `*object`  | `null`       |
| `source.http`       | Download content from an HTTP source. Set optical=true when importing ISO media.                                                     | `*object`  | `null`       |
| `source.http.url`   | URL to download the content from.                                                                                                    | `string`   | `""`         |
| `source.disk`       | Clone an existing vm-disk.                                                                                                           | `*object`  | `null`       |
| `source.disk.name`  | Name of the vm-disk to clone.                                                                                                        | `string`   | `""`         |
| `optical`           | Defines if this tenant object is optical media. Platform source.iso entries are automatically optical even when this value is false. | `bool`     | `false`      |
| `displayName`       | Optional human-readable media name shown in catalog metadata.                                                                        | `string`   | `""`         |
| `mediaCategory`     | Optional optical-media category: installer, drivers, rescue, appliance, or custom.                                                   | `string`   | `""`         |
| `osFamily`          | Optional operating-system family metadata, for example Linux or Windows.                                                             | `string`   | `""`         |
| `osName`            | Optional operating-system/distribution name metadata.                                                                                | `string`   | `""`         |
| `osVersion`         | Optional operating-system version metadata.                                                                                          | `string`   | `""`         |
| `architecture`      | Optional CPU architecture metadata, for example amd64 or arm64.                                                                      | `string`   | `""`         |
| `description`       | Optional human-readable disk/media description.                                                                                      | `string`   | `""`         |
| `storage`           | The size of the disk/media object allocated for the virtual machine.                                                                 | `quantity` | `5Gi`        |
| `storageClass`      | StorageClass used to store the data.                                                                                                 | `string`   | `replicated` |

