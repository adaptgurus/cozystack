# HCI persistent VM state

LayerSentry HCI stores VM-local security and firmware state separately from guest data disks.

- Persistent vTPM state is **unique per VM**. It is never shared between different guests.
- KubeVirt `VMPersistentState` is enabled and `vmStateStorageClass` defaults to `replicated`.
- A VM that opts into persistent TPM receives a KubeVirt backend-state PVC on the three-way LINSTOR/DRBD storage class. The same backend state can therefore follow the same VM when it restarts on a surviving virtualization node.
- VM disks remain independent replicated DataVolumes/PVCs.
- Inline cloud-init is stored in a Kubernetes Secret and is not tied to a worker node.
- `cloudInitSecretRef` allows multiple VMs to intentionally reference one reusable cloud-init Secret when a shared bootstrap definition is desired.

This design shares the **storage fabric**, not TPM identity, between VMs.
