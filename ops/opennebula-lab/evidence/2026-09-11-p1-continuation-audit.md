# P1 continuation audit — 11 September 2026

Latest receipt inspection: 2026-09-11T04:08:28Z (09:38:28 IST). Central authority: adaptgurus/codexagentlogic, commit ab55a25f4b1421a63718242d8a8f99359d2ab24e, existing capability run d5db2181-14e4-4ab0-8464-493b643130b9. The central PR #1 remains open and unmerged. This audit continued through TESTSER, elevated Windows opc, Ubuntu-22.04 WSL and the existing OpenNebula SSH identity. No private keys or kubeconfig credentials were exported.

## Fresh runtime results

OpenNebula 7.4.1 was confirmed on rocky-01; rocky-02 and rocky-03 were ON. The exact Kubernetes API target https://10.10.10.117:6443 returned readyz=ok. The three existing Kubernetes nodes were Ready on v1.36.4+rke2r1, with provider IDs one://36, one://38 and one://39. Their MemoryPressure, DiskPressure, PIDPressure and NetworkUnavailable conditions were false. Active system pods inspected were Running with ready containers; completed installation jobs were not treated as failures.

| Role | VM | IP | Host | Configured resources |
|---|---|---|---|---|
| Control plane | 36 | 172.20.80.30 | rocky-02 | 6 vCPU / 8 GiB |
| Worker 1 | 38 | 172.20.80.31 | rocky-03 | 2 vCPU / 4 GiB |
| Worker 2 | 39 | 172.20.80.32 | rocky-03 | 2 vCPU / 4 GiB |

All three guests passed ICMP to 10.10.10.1, HTTPS to example.com with status 200, and direct DNS queries to 8.8.8.8 and 1.1.1.1. DNS assertions checked response identifier, responder address, zero error code and nonempty answers. The private-cluster guests use native router 172.20.80.27 as their configured resolver/default gateway; direct public-DNS success does not mean resolv.conf lists those public resolvers.

The first independent audit exited 141 because rke2 --version | head -1 produced SIGPIPE under pipefail. The diagnostic was corrected to drain output with sed, after which the three-guest network audit passed. No cluster repair was needed for that diagnostic error.

## Capacity and requested extra worker

| Host | Allocated CPU / capacity | Nominal CPU remaining | Allocated memory / total | DS0 free |
|---|---|---|---|---|
| rocky-02 | 800 / 900 | 1 vCPU | 10.5 / 32.2 GiB | 322.2 GiB |
| rocky-03 | 600 / 900 | 3 vCPU | 10.5 / 32.2 GiB | 311.6 GiB |

These are scheduler allocations, not physical CPU performance guarantees in nested Hyper-V. The requested 1-vCPU/1-GB worker is below the official RKE2 minimum recommendation of 2 CPUs and 4 GB RAM. No worker was provisioned. A nominal 2-vCPU/4-GiB worker could fit on rocky-03 according to these allocations, but no larger size was substituted. Current readiness did not establish a need for an extra worker. Both workers are on rocky-03; another there would not add compute-host diversity. Official sizing source: https://docs.rke2.io/install/requirements.

## Tests and accepted scope

Completed central regression run 34560076244, job 103140805385, tested central commit ab55a25f4b1421a63718242d8a8f99359d2ab24e with Python 3.12.14: all 152 unit tests passed. Synthetic model/SSH/live-verifier fixtures in that suite are not evidence of a deployed RKE2 cluster.

The existing P1 build, unit and live test receipts were read and SHA-256 verified. All three report PASS against source snapshot 86b0fe62098a959f74cdd42af3d08b2519dbbfa2659416b7f9b948c98c1761e4. Unit coverage records Go race, OneKS profiles, native bootstrap recovery, seed RSpec and HAProxy RSpec. The live receipt records nine checks: approved images, dual-LB placement, endpoints 6443/9345, node join, pod/DNS, kubeconfig authorization, duplicate/restart, LB failover and safe cleanup. Those historical destructive/lifecycle scenarios were not replayed in this audit.

| Receipt | Verified SHA-256 |
|---|---|
| Build | 859e312827e4024934cbd3ec047dab3e345937598c1a6bcfea21f448dee29ba9 |
| Unit | 1e30af85fcbe8eff82c6d285e1be08994a018668735865eb7684361354a3c796 |
| Live | 89d7f169f4d2bd5328363af10eae962820bd707e0c8d64dce07e333bbfdc4348 |

The recorded final review is ACCEPT for the scoped one-control-plane, two-worker nested POC only. It explicitly says worker rejoin required operator assistance, and production HA and unattended recovery are not certified. A single control plane is not control-plane HA. CAPONE had historical restarts while being Ready at inspection; every restart cause was not established by this audit.

## Publication: incomplete, not merged

All three local worktrees are clean on layersentry/p1-rke2-provisioning.

| Repository | Verified local commit | Target | Observed publication |
|---|---|---|---|
| adaptgurus/one | 6746b9e22d63a0d7ef64154fd22a8161087e7b68 | one-7.4 | Remote feature branch exists, one commit ahead of target; no matching PR; not merged |
| adaptgurus/one-apps | e1bd9602c8bd0aea7839fe9e4a4356a11af4daad | master | COMMITTED locally; expected remote feature branch absent; not merged |
| adaptgurus/layersentry-platform | 8b5fa534008c0a517fa924ddca3e8a52ab4e3dfc | main | COMMITTED locally; expected remote feature branch absent; not merged |

GitHub target refs were independently checked: one-7.4 is 0fea39ec3bca95aed9d126adc9b1ce401cc819a3, one-apps master is cc93b4f4af763ba29bcbf64d22a1d09130ad94bd, and layersentry-platform main is de86df337cedd3177697fd6c7c0da568eb0819a5.

The supervisor state remains PUBLICATION_UNKNOWN. Its recorded GitHub command failed with Unknown JSON field: "headRefOid". The bound tool is /usr/bin/gh, version 2.4.0+dfsg1 (2022-03-23), SHA-256 2b61ea0d3a5654bbefaf6f75def59d13d37a791a95196764db19414ac50d0524. This is a CLI schema compatibility failure, not evidence that SSH or Kubernetes failed. It also does not establish whether later GitHub authentication would succeed.

No unchanged publication retry was made with this deterministically incompatible executable. The central supervisor rejects tool-hash changes after approval. The next publication step is a reviewed compatible CLI/publication path and explicit binding reconciliation, followed by resume of the existing accepted capability. No tool was replaced in place, accepted evidence rewritten, supervisor state manually marked successful, or product branch merged. Product code and evidence are retained rather than recreated.

## Execution references

- Central regression: run 34560076244, job 103140805385.
- Initial cluster/capacity audit: run 34560541606, job 103142185090; partial diagnostic, exit 141.
- Completed three-guest network audit: run 34560881786, job 103143180598.
- Successful receipt/publication reconciliation: run 34561026630, job 103143612912.
- Audit script commit: 5f4c4b3437e0fed25f11c15b4677ddb6b38a83d1, branch ops/opennebula-p1-audit-20260911.

Temporary Windows tasks and working files were removed. No new VM or image, VM power operation, network/storage/SSH-key change, OpenNebula reinstallation, product-source change, merge or UI/DR advancement was performed in this independent continuation audit.
