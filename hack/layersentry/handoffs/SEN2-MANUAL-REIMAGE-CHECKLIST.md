# LayerSentry sen2 manual reimage checklist

## Scope and safety boundary

This procedure applies only to the Hyper-V VM named `sen2` on `TESTSER`.

Do not modify, reboot, reinstall, detach disks from, or change networking for `sen1` or `sen3`.
Do not delete RKE2 data from a working node. Do not use the obsolete direct-sen1 join endpoint `https://10.10.10.11:443`.
The verified join endpoint is the cluster VIP `https://10.10.10.10:443`.

A manual reimage is permitted only after the read-only Hyper-V diagnostic identifies the current `sen2` OS disk, data disk, NIC, ISO/DVD state, and boot order. Preserve the existing data disk unless an explicit, separately authorized destructive operation is issued.

## Authoritative network and node values

| Field | Required value |
|---|---|
| Hyper-V VM | `sen2` |
| Host | `TESTSER` |
| Hyper-V switch | `Cozystack-NAT` |
| Installation mode | Join an existing Harvester cluster |
| Hostname | `sen2` |
| Management IPv4 address | `10.10.10.12/24` |
| Default gateway | `10.10.10.1` |
| Cluster VIP / server | `10.10.10.10` |
| Expected rancherd server URL | `https://10.10.10.10:443` |
| DNS servers | `8.8.8.8,1.1.1.1` |
| NTP servers | `time.cloudflare.com,time.google.com` |
| Time zone | `UTC` |
| HTTP proxy | blank |
| HTTPS proxy | blank |
| No-proxy | installer/platform default unless a proxy is intentionally configured |

## Credentials

Use the existing protected values in:

`C:\ProgramData\LayerSentry\bootstrap-credentials.json`

- Node login/install password: property `nodePassword`. This is the same protected node password used by the other LayerSentry VMs.
- Existing-cluster join token: property `clusterToken`. This is separate from the node password.
- Installer SSH user after installation: `rancher`.

Never paste either protected value into chat, commit history, workflow logs, screenshots, or evidence artifacts.

## ISO identity

Required destination on `TESTSER`:

`C:\Users\opc\Downloads\final iso\layersentry-v1.0-amd64.iso`

Expected ISO properties:

- Size: `8571445248` bytes
- SHA-256: `bc1ca4549bd5e166824ded366a88884353c4d158b945cc9cf4a816913f0afc82`
- SHA-512: `e85212091995091a329220068657dd43b737a42e8ea35825972e89604375624e6fe93bdb63e44902f8b5f25ff23b6c5709644ba8d75979575fea851ee1ad66fd`

Do not boot or install from a differently named or differently hashed ISO.

## Hyper-V checks before starting the installer

1. Confirm the VM is exactly `sen2`.
2. Confirm the management NIC is connected to `Cozystack-NAT`.
3. Record the existing NIC MAC address; do not replace the NIC unless a separate repair explicitly requires it.
4. Identify the existing OS VHD and confirm its maximum size is at least 250 GB.
5. Identify the existing data VHD and confirm its maximum size is at least 300 GB.
6. Preserve the data VHD. Do not delete, recreate, initialize, or select it as the installation target.
7. Mount only the verified LayerSentry ISO.
8. Temporarily put the DVD drive first in the firmware boot order for installation.
9. Keep Secure Boot disabled for this Generation 2 VM.
10. Keep the VM at 10 vCPU, 32 GB static memory, and the existing nested-virtualization/MAC-spoofing settings.

## Installer selections

1. Select the NIC attached to `Cozystack-NAT`.
2. Configure static address `10.10.10.12/24`.
3. Configure gateway `10.10.10.1`.
4. Configure DNS `8.8.8.8,1.1.1.1`.
5. Select only the verified OS disk as the installation disk.
6. Do not select, format, or recreate the existing data disk during reimage unless the installer requires an explicit data-disk assignment and its identity has been verified from the read-only diagnostic.
7. Select **Join an existing Harvester cluster**.
8. Set hostname to `sen2`.
9. Enter cluster server/VIP `10.10.10.10`.
10. Enter the protected `clusterToken` as the join token.
11. Enter the protected shared `nodePassword` as the installation/login password and confirmation.
12. Configure NTP `time.cloudflare.com,time.google.com`.
13. Set time zone to `UTC`.
14. Leave proxy fields blank.
15. Do not enable automatic EULA acceptance. Complete any first-run GUI EULA/password step manually.
16. Review the summary carefully and verify that no field contains `10.10.10.11` as the cluster server.

## First boot after installation

1. After the installer completes, power off/reboot only `sen2` as requested by the installer.
2. Detach the ISO from the `sen2` DVD drive.
3. Put the verified OS disk first in the firmware boot order.
4. Boot only `sen2`.
5. Confirm that `10.10.10.12` responds on TCP/22 before starting any automated recovery workflow.
6. Do not run `.github/workflows/layersentry-resume-sen2-idempotent.yml`; it contains the obsolete direct-sen1 endpoint.
7. Run a fresh post-reimage observation gate before applying any mutation. The observation must establish the new persisted rancherd/Harvester configuration hashes, service roles, node identity, Kubernetes registration, KubeVirt state, and Longhorn state.

## Acceptance sequence

A reimaged node is not accepted merely because SSH works. Qualification must proceed in this order:

1. Hyper-V/host network reachability.
2. SSH using the protected shared node password.
3. Persisted rancherd role is `agent` and installation mode is `join`.
4. Persisted rancherd server is exactly `https://10.10.10.10:443`.
5. `rke2-server` is disabled and `rke2-agent` is enabled/running.
6. Kubernetes reports `sen2` Ready through `https://10.10.10.10`.
7. KubeVirt validation passes.
8. Longhorn reports the expected `sen2` node/storage state.
9. Twenty-four consecutive 30-second stability samples pass.
10. Browser/private-label validation and manual first-run EULA/password completion are recorded separately.

Repository build success, node recovery success, browser validation, air-gap validation, and release approval remain separate gates.
