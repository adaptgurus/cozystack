# VM Template

Captures a halted Cozystack VMInstance as a tenant-local KubeVirt VirtualMachineTemplate through the hardened VMTemplateOperation controller. Copy keeps the source VMInstance. Convert retires it only after the reusable template is verified Ready, optical and one-time bootstrap material has been sanitized, and the source UID/generation still match the preflight checkpoint.

## Parameters
