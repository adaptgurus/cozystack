# DC DHCP and Pod phase review

Current status: no DHCP or Pod configuration request has been submitted. The source Basic Zone remains Disabled. Native primary/image storage and the official SystemVM template are verified; SystemVM instances and guest routing are not ready. The owned guest NIC is disconnected after Apply `34060879767` stopped at an unowned NetworkManager profile collision; this does not authorize an Apply replay.

## DHCP phase

The only proposed submissions run on exact Hyper-V host TESTSER against existing active scope `10.10.10.0`, range `.10–.250`, mask `/24`:

```powershell
Add-DhcpServerv4ExclusionRange -ComputerName TESTSER -ScopeId 10.10.10.0 -StartRange 10.10.10.14 -EndRange 10.10.10.14 -ErrorAction Stop
Add-DhcpServerv4ExclusionRange -ComputerName TESTSER -ScopeId 10.10.10.0 -StartRange 10.10.10.20 -EndRange 10.10.10.20 -ErrorAction Stop
```

`DcDhcpExclusions.psm1` verifies exact existing Cozystack-NAT switch UUID, both attached sen/DR VM UUIDs and MACs, host `.1/24`, scope bounds, exclusions and public lease/reservation identity. A reservation at `.14` or `.20` blocks because it overrides an exclusion. Plan performs no write; Apply requires its exact reviewed receipt hash. The private Windows journal stores a durable per-address intent before each single submission. Reconciliation may observe an exclusion after an uncertain call, but cannot resubmit an absent unresolved exclusion. Lease/reservation records, scope endpoints, NAT and VM NICs are preserved. In particular, the observed old-MAC `.14` lease is retained: these exclusions do not prove revocation or resolution of any client still holding an earlier lease.

Before DHCP Apply: execute and review the read-only Plan, retain its byte-exact receipt, confirm the known `.14/.20` static addresses and unchanged authoritative host inventory, review source and schedule the shared live queue. After Apply: verify the two exact exclusions and preserved leases/reservations, then record the actual journal status. The existing controller tests execute intent ordering, both additions and no-replay behavior; read-only DHCP Plan proof is recorded below.

## Pod phase

The only proposed native API mutation is `updatePodManagementNetworkIpRange(podid=020dc658-af4e-4e2e-bed5-0607de8a787f,currentstartip=10.10.10.2,currentendip=10.10.10.254,newstartip=10.10.10.2,newendip=10.10.10.9)`. The eight-address subset is inside the existing Pod range and outside the positively observed DHCP `.10–.250`, fixed `.14/.20` and gateway `.1`; it is not selected from ping silence. The earlier `.21–.254` candidate was rejected because it overlapped DHCP.

Before Pod Apply: collect actual `listPods.ipranges` role/VLAN and top-level gateway/netmask, exact Zone/Pod/host identity and Disabled state, no SystemVM/router/user instances, and fresh scoped type-5 private-IP capacity with zero used and total 253. `fetchlatest=true` refreshes native derived capacity records and must be reported as such; it does not change address allocation or Zone configuration. Current source provisionally requires serialized `forsystemvms="0"` and `vlanid="vlan://untagged"`; those values need actual API confirmation before invocation. The native response does not populate nested gateway/CIDR, so top-level gateway `.1` and mask `/24` supply that binding. Preserve the native taken-address rejection rather than bypassing it with SQL.

`dc-pod-range.py` prepares durable intent, one native async submission, returned job-ID polling and exact endpoint/count reconciliation on uncertainty. A strict executable wrapper tied to reviewed host evidence is still required. Apply must leave the Zone Disabled and verify the eight-address total with zero allocated afterward. DHCP/Pod completion alone is not SystemVM connectivity or production readiness; guest bridge/label, gateway routing, native SystemVM boot and GUI tests remain separate gates.


## Actual DHCP Plan

Read-only Plan `34063102956` passed at source `16d9494edbe81ac3ee099967c89af1a1e46963ed`. Its original public receipt is preserved byte-for-byte as `dc-dhcp-reviewed-plan.json`, SHA-256 `05c0bc5cb4625662a8b9e292f2eebd71d9eb9d44f5951598414f819ea0434cae`. It observes the same scope, empty exclusions, reservations `.11/.12/.13`, six unchanged leases including old-MAC `.14`, exact attached VM identities and only the two proposed single-address additions. exclusionMutationAttempted is false. Actual Windows enumeration returned unsorted lease/reservation arrays; a source correction now compares canonical address/client/state-or-type tuples independent of row ordering, while still rejecting any actual identity/state change. The original receipt is not normalized or rewritten. No DHCP Apply request exists; source and actual Plan await lead review.
