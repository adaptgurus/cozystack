# Verified OpenNebula WSL access and live inventory

Observed on 2026-09-11. Latest frontend timestamp: 2026-09-11T03:16:56Z (08:46:56 IST). These are observations from completed read-only executions, not the original handoff's expected values.

## Execution evidence

- Repository: `adaptgurus/cozystack`
- Branch: `ops/opennebula-p1-resume-20260911`
- Latest verified execution commit: `60e895ab6e7a6c7ca95b31924fd5576972de405e`
- Latest successful workflow run: `34557831573`
- Latest successful job: `103134184863`
- Earlier successful full inventory run: `34557688814`, job `103133754850`
- Workflow: `.github/workflows/opennebula-wsl-opc-check.yml`
- Read-only Linux payload: `ops/opennebula-lab/wsl-readonly.sh`

## Working connection route

The TESTSER runner service remains `NT AUTHORITY\SYSTEM`. Its PowerShell process is already administrative, but WSL rejects this account with `Wsl/WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`. WSL is installed, and Ubuntu-22.04 is registered to the Windows `opc` account. A temporary, on-demand Windows Task Scheduler task using `TESTSER\opc`, `LogonType Interactive` and `RunLevel Highest` successfully ran PowerShell and the existing WSL distribution. This route requires an existing logged-on opc session. No Windows user password was extracted or supplied, no runner service account was changed, and no persistent task was left behind.

Within WSL, the Linux account is `opc`. The existing administrative identity is `~/.ssh/opennebula-admin`; the existing SSH configuration maps `rocky-01`, `rocky-02` and `rocky-03` to their 10.10.10.21-23 addresses and the `oneadmin` user. The private key remained on TESTSER and was never printed, copied out or replaced. Earlier raw-IP probes had not explicitly selected this nondefault identity. Both explicit identity selection and the existing aliases have now been tested successfully.

Exact selected lines from the latest job output:

```text
WINDOWS_USER=TESTSER\opc ADMINISTRATOR=True
WSL_HOST=testser WSL_USER=opc
DIRECT_WSL_ALIAS=rocky-01 AUTHENTICATED=true OUTPUT=rocky-01,oneadmin
DIRECT_WSL_ALIAS=rocky-02 AUTHENTICATED=true OUTPUT=rocky-02,oneadmin
DIRECT_WSL_ALIAS=rocky-03 AUTHENTICATED=true OUTPUT=rocky-03,oneadmin
ROCKY01_ONEADMIN_SSH_AUTHENTICATED=true; OPENNEBULA_READ_ONLY_BEGIN
OpenNebula 7.4.1 (0fea39ec)
OPENNEBULA_READ_ONLY_COMPLETE; SERVER_MUTATIONS=false; GUEST_NETWORK_TESTS_PERFORMED=false; KUBERNETES_HEALTH_VERIFIED=false
OPC_WSL_REPORT={"error":"","administrator":true,"windows_user":"TESTSER\\opc","exit_code":0}
TEMPORARY_TASK_REMOVED=true
TEMPORARY_WORK_FILES_REMOVED=true; OPENNEBULA_SERVER_MUTATIONS=false; SSH_KEYS_CHANGED=false; RUNNER_SERVICE_CHANGED=false; REBOOT_REQUESTED=false
```

## Live platform observations

| Item | Verified observation |
|---|---|
| Frontend | Rocky-01; OpenNebula 7.4.1 (0fea39ec); operations executed as oneadmin |
| Compute host 0 | rocky-02; ON; allocated CPU 800/900; allocated memory 10.5G/32.2G |
| Compute host 1 | rocky-03; ON; allocated CPU 600/900; allocated memory 10.5G/32.2G |
| Local system datastore 0 on rocky-02 | Total 339.8G; used 17.7G; free 322.2G |
| Local system datastore 0 on rocky-03 | Total 339.8G; used 28.2G; free 311.6G |
| Both compute filesystems | /dev/mapper/rlm-one--ds, XFS, mounted at /var/lib/one/datastores |
| Both compute bridges | br0 UP with the expected 10.10.10.22/24 and 10.10.10.23/24 addresses |
| POC-LAN | Network 0; READY; br0; fw; pool 10.10.10.100-149; gateway 10.10.10.1; DNS 8.8.8.8 and 1.1.1.1 |
| Additional existing network | Network 1, ls-poc-rke2-private; READY |

The OpenNebula controller, FireEdge, OneFlow, OneGate, Guacamole, Hook Execution Service and OpenNebula SSH agent services were active. `opennebula-scheduler.service` has `LoadState=not-found`: an earlier `systemctl is-active` result for that name must not be represented as proof of a stopped installed scheduler. This inspection did not establish how scheduling is configured internally.

The default bare `virsh list --all` invocation returned an empty list. Explicit `virsh -c qemu:///system list --all` correctly showed the running OpenNebula domains. Do not confuse the default connection's empty list with missing guest VMs.

## Existing Rocky image and template

Image 0 is `Rocky-9-PoC`, in image datastore 1 (`default`), size 10240 MiB. Its XML contains `TEMPLATE/FROM_APP=54`, positively confirming the import from Marketplace application 54. Its current state is USED, and the image reports five VM references. No new image import is needed merely to obtain the Rocky base image.

Template 0 is `Rocky-9-PoC`, with CPU 1, memory 1536 MiB, disk image 0, `CONTEXT/NETWORK=YES`, and an SSH_PUBLIC_KEY contextualization field. It has no saved NIC element. The existing test VMs do have POC-LAN NICs; do not claim that template 0 itself already contains the POC-LAN NIC definition.

Other existing utility/service images and templates were present and left untouched. The current lab is not an empty first-VM environment.

## Existing VM inventory

| VM ID | Role/name | Guest IP addresses | Placement | Observed VM state |
|---|---|---|---|---|
| 0 | ls-poc-vm01 | 10.10.10.100 | rocky-02, system datastore 0 | POWEROFF |
| 1 | ls-poc-vm02 | 10.10.10.101 | rocky-03, system datastore 0 | POWEROFF |
| 34 | Virtual router, cp-0 | 10.10.10.118; 172.20.80.28 | rocky-02, system datastore 0 | RUNNING |
| 35 | Virtual router, cp-1 | 10.10.10.119; 172.20.80.29 | rocky-03, system datastore 0 | RUNNING |
| 36 | controlplane-layersentry-poc-standalone-4366810918b3-gwzph | 172.20.80.30 | rocky-02, system datastore 0 | RUNNING |
| 38 | nodegroup-layersentry-poc-small-8af41fab1085-6twm7-fltbh | 172.20.80.31 | rocky-03, system datastore 0 | RUNNING |
| 39 | nodegroup-layersentry-poc-small-8af41fab1085-6twm7-r6hwm | 172.20.80.32 | rocky-03, system datastore 0 | RUNNING |

POC-LAN also reserves 10.10.10.117 for virtual router 2. No Kubernetes API health claim is made for that address in this inspection.

VMs 0, 1, 36, 38 and 39 reference Rocky image 0. VMs 34 and 35 reference utility image 5. Direct system-libvirt checks confirmed domains one-34 and one-36 running on rocky-02, and one-35, one-38 and one-39 running on rocky-03.

The running guest disk backing paths were confirmed with `virsh -c qemu:///system domblklist --details`. For example, VM 36 uses `/var/lib/one//datastores/0/36/disk.0.snap/0`; VM 38 uses `/var/lib/one//datastores/0/38/disk.0.snap/0`; VM 39 uses `/var/lib/one//datastores/0/39/disk.0.snap/0`. The double slash is how libvirt reported the paths.

## Continuation boundary

Authenticated administration access to all three OpenNebula servers is verified. No reinstallation, image import, VM creation, VM power operation, guest reconfiguration, networking/storage change, SSH-key change or OpenNebula database change was performed by these checks. The temporary Windows tasks and their temporary working files were removed after collecting results.

Guest gateway reachability, guest Internet connectivity, direct DNS resolution against the two specified resolvers, VM lifecycle operations, RKE2 service health, Kubernetes node Ready state, CNI/CSI functionality and application-level tests have not been tested in this connection-verification session. Running VM state is not evidence of Kubernetes readiness. Continue from the existing VMs rather than creating another control plane, worker set or duplicate Rocky image. Preserve powered-off test VMs unless the next authorized validation explicitly needs a lifecycle operation.

When invoking the saved read-only workflow, keep opc logged on. Its temporary task uses the existing interactive session, not a service-account change. Keep the read-only script and no-mutation reporting accurate; do not insert deployment operations into it while retaining its read-only labels.
