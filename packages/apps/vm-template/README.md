# VM Template

Captures a halted Cozystack VMInstance as a tenant-local KubeVirt VirtualMachineTemplate through the hardened VMTemplateOperation controller. Copy keeps the source VMInstance. Convert retires it only after the template is verified Ready and the source UID/generation still match the preflight checkpoint.
