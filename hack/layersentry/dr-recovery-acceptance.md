# Native recovery acceptance adapter

This is a fixture-driven acceptance harness for CloudStack 4.22.1.1 NAS `createVMFromBackup`, not a DR controller. It performs no provisioning, backup creation, guest boot, repository configuration, failover or fencing. Default mode only reads CloudStack. Executed restores create two stopped clones on explicit recovery networks using the older and latest backup UUIDs. Guest content and full E2E remain `NOT_TESTED` in every output; API success does not prove restored data.

The exact source audit established `CreateVMFromBackupCmd` → `UserVmManagerImpl.allocateVMFromBackup` → native destination volume preparation → `BackupManagerImpl.restoreBackupToVM` → `NASBackupProvider` → `LibvirtRestoreBackupCommandWrapper`. Repository selection uses the original backup offering. The source VM database row, backup metadata and both Zones must belong to the same management database. Installing an independent DR management/database does not make NAS files discoverable. See [native B&R documentation](https://docs.cloudstack.apache.org/en/4.22.1.0/adminguide/backup_and_recovery.html#creating-a-new-instance-from-backup-in-another-zone); audited backend files were identical to CloudStack tag `4.22.1.1` at LayerSentry `75f2689a7d471d92758a7466eb2c2e4a94d06299`.

## Fixture preparation

Create a reviewed JSON fixture with exactly the fields below. UUIDs and hashes here are examples, never live targets. All fixture IDs must be canonical lowercase UUIDs. Account names use the restricted ASCII subset shown; project/shared-network cases are deliberately outside this first adapter. `network_map` must cover every current source NIC network once, have unique destination networks, and list the intended default network first. Destination networks must be owned by the specified account/domain and be Allocated or Implemented. The source VM must be stopped, retained and KVM; both Zones must be Enabled. The selected repository must be NAS with cross-Zone creation enabled, and the offering's external ID must identify that repository.

```json
{
  "run_id": "00000000-0000-4000-8000-000000000001",
  "source_vm_id": "00000000-0000-4000-8000-000000000002",
  "source_zone_id": "00000000-0000-4000-8000-000000000003",
  "destination_zone_id": "00000000-0000-4000-8000-000000000004",
  "account_id": "00000000-0000-4000-8000-000000000005",
  "account": "test-account",
  "domain_id": "00000000-0000-4000-8000-000000000006",
  "repository_id": "00000000-0000-4000-8000-000000000007",
  "offering_id": "00000000-0000-4000-8000-000000000008",
  "template_id": "00000000-0000-4000-8000-000000000009",
  "service_offering_id": "00000000-0000-4000-8000-000000000010",
  "network_map": [{
    "source": "00000000-0000-4000-8000-000000000011",
    "destination": "00000000-0000-4000-8000-000000000012"
  }],
  "points": {
    "older": {
      "backup_id": "00000000-0000-4000-8000-000000000013",
      "disk_hashes": {"0": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    },
    "latest": {
      "backup_id": "00000000-0000-4000-8000-000000000014",
      "disk_hashes": {"0": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    }
  }
}
```

Before preparing these backup UUIDs, write distinct markers on every disk, flush/quiesce consistently, record their SHA-256 hashes and create the older backup. Change every marker, then create the latest backup. Each `disk_hashes` key is CloudStack's numeric device ID, including root device `0`; values are marker-file SHA-256 hashes, not whole-volume hashes. Both points must have identical disk sets, distinct IDs and different marker hashes for every disk. The harness compares disk sets against each backup's volume metadata and verifies backup creation-time ordering. It does not infer marker content from this expected-value fixture. Preserve source VM records and backups throughout the run.

Repository mountability, free primary capacity, source B&R framework configuration, real backup payload availability and recovery network isolation must also be established by the runner/operator. They are not certified by this metadata preflight. CloudStack remains authoritative for create-time RBAC, allocation and storage checks.

The stopped-source requirement is this adapter's minimal isolated baseline, not a CloudStack limitation: native NAS also supports running-VM backups through libvirt backup APIs. Running-source consistency/quiesce and concurrent-workload gates require additional guest instrumentation and remain outside this baseline.

## Runner invocation

Use Python 3.9+ on the trusted Linux/Rocky runner or a controlled Linux runner transport. The client uses standard CloudStack HMAC-SHA1 request signing, sends secrets only in the POST body, verifies HTTPS certificates, disables proxies/redirects and bounds each request at 30 seconds. HTTP is permitted only for literal loopback `127.0.0.1` or `::1`, for example through an approved SSH tunnel. Inject `LAYERSENTRY_CLOUDSTACK_API_URL`, `LAYERSENTRY_CLOUDSTACK_API_KEY` and `LAYERSENTRY_CLOUDSTACK_SECRET_KEY` through the existing runtime secret path. Do not place them in fixtures, arguments or artifacts. Native response bodies and exception text are never emitted. The account doing acceptance needs supported inventory permissions; lack of visibility fails closed.

```bash
python3 hack/layersentry/dr_recovery_acceptance.py /approved/fixture.json
```

For mutation, provide a persistent private directory owned by the runner with mode `0700`, outside the checkout. Keep this same directory and the exact fixture/endpoint for the entire run, including cleanup. One runner holds its exclusive lock at a time. The directory contains no API credentials; it contains the authoritative mutation journal and must not be accepted from PR-controlled inputs. Preserve it across runner restarts and upload it through a trusted evidence path. Lost journals must be reconciled by the operator before a new execute run; a new journal is not a retry.

```bash
python3 hack/layersentry/dr_recovery_acceptance.py /approved/fixture.json --mode execute --journal-dir /private/run-journal
python3 hack/layersentry/dr_recovery_acceptance.py /approved/fixture.json --mode resume --journal-dir /private/run-journal
```

Each invocation queries each relevant async job once; there are no fixed sleeps or mutation retry loops. Pending state returns evidence for later reconciliation. `resume` is read-only against CloudStack and never submits an unstarted checkpoint. Once the older clone is complete, another explicit `execute` can submit the latest checkpoint; already recorded creations are never repeated. Exit zero means the invocation produced valid evidence, including pending state; it is not an E2E pass. The wrapper must inspect point states. Nonzero reports a fixed failure code.

The journal writes and fsyncs submission intent before calling the mutation API. If the response is lost, it leaves `SUBMITTING` and refuses another submission. Recover the exact job identity from trusted CloudStack audit/job evidence and the journal's request parameters; this initial adapter intentionally provides no blind name-based adoption or reset switch. Do not delete the journal to get past this gate. Failure after allocation may leave resources even when CloudStack attempts expunge; inspect the recorded job and residual resources. No automatic cleanup occurs on failure.

Explicit cleanup calls `destroyVirtualMachine` with `expunge=false` only for completed, recorded recovery IDs after rechecking name, account/domain, destination Zone, stopped state and network set. It never deletes source VMs, backups, networks or repositories. Destroyed VMs remain recoverable subject to the platform's normal expunge policy; physical expunge is outside this adapter. Pending cleanup jobs are reconciled by repeating cleanup with the same journal.

```bash
python3 hack/layersentry/dr_recovery_acceptance.py /approved/fixture.json --mode cleanup --journal-dir /private/run-journal
python3 -m unittest discover -s hack/layersentry -p test_dr_recovery_acceptance.py -v
```

## Missing guest acceptance adapter

The lead's trusted runner must establish recovery-network isolation, start only the recorded clones, verify allocated IP/DNS/network behavior, and collect actual per-device marker hashes from each guest using approved SSH/console access. Match observed hashes against `points.<label>.disk_hashes`, keyed by disk identity as well as mount path; verify older content and absence of any latest-only marker. Capture exact runner commit/run/job/artifact IDs, CloudStack source/artifact identity, fixture digest, backup/restore job IDs, clone UUIDs, observation timestamps and actual hashes. Keep expected fixtures separate from measured evidence and never accept a user-supplied `PASS` as guest proof. Stop clones before this harness's cleanup. This adapter does not ingest guest evidence yet, so a separate reviewed evidence record must report actual guest assertions.

Also pending live work: wrong-account/direct-API negatives, cross-Zone-disabled rejection, missing repository payload/reachability failure and retry reconciliation, retained-source-record negative in a disposable management database, measured timings and exact storage-path evidence. Offline tests cover fixture rejection and client lifecycle behavior only. They cannot promote runtime functionality to `LIVE_VERIFIED`.

Repeated in-place `restoreBackup` is a distinct path with a reported multi-disk corruption issue, [upstream PR #13922](https://github.com/apache/cloudstack/pull/13922). Its report explicitly excludes `createVMFromBackup`; this adapter uses fresh clones and does not broaden a successful native clone test into certification of in-place restore, storage replication, failover or failback.
