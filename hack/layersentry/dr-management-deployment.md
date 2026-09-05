# DR CloudStack Management deployment

The workflow deploys only to root@10.10.10.20 from the reviewed `adaptgurus/cloudstack` branch `layersentry/4.22.1.1-ui`. The checked-out branch must equal the request's exact source SHA. The installer owns package signature verification, SELinux, firewalld, database initialization checkpoints, service configuration and encrypted database backup. This workflow does not implement an automatic rollback or claim production readiness.

Store credentials in repository Actions secrets: `LAYERSENTRY_DR_ROCKY_HOST` (`10.10.10.20`), `LAYERSENTRY_DR_ROCKY_USER` (`root`), `LAYERSENTRY_DR_SSH_PRIVATE_KEY`, `LAYERSENTRY_DR_SSH_KNOWN_HOSTS` (independently verified OpenSSH known_hosts line), `LAYERSENTRY_DR_BACKUP_RECIPIENT_CERTIFICATE` (PEM public recipient certificate), and `LAYERSENTRY_ROCKY_R0_PASSWORD` (the authorized test-platform password). The workflow constructs the installer's five-field secret document in a private runner directory and never commits or uploads it. Retain the matching backup recipient private key separately for restore validation; never place it in the workflow bundle. GitHub encrypts repository secrets at rest. The SSH key is materialized temporarily for noninteractive SSH and is not an encrypted-key/passphrase integration.

Create a reviewed request at `hack/layersentry/dr-management-requests/<id>.json` with exactly these fields:

```json
{
  "request_id": "dr-first-node",
  "source_sha": "REPLACE_WITH_REVIEWED_40_CHARACTER_COMMIT",
  "configuration": {
    "schema_version": 1,
    "mode": "combined",
    "management_ip": "10.10.10.20",
    "db_host": "localhost",
    "initialize_database": true
  },
  "repositories": {
    "cloudstack.repo": "REPLACE_WITH_REVIEWED_HTTPS_GPG_CHECKED_REPOSITORY_CONTENT"
  }
}
```

Complete `configuration` with the exact installer-validated package NEVRAs, MySQL series, current hostname, firewall zone, scoped UI/agent CIDRs and optional backup settings. Omit `repo_files` and `backup_recipient_certificate`; the adapter supplies stable runtime paths for these inputs. This example deliberately cannot install until the missing reviewed fields and trust material are supplied. Repository text belongs in the request and must contain no credentials. The first-node adapter supports combined mode only.

Each operation uses a new committed envelope in `hack/layersentry/dr-management-actions/<unique-id>.json`:

```json
{
  "request": "hack/layersentry/dr-management-requests/dr-first-node.json",
  "phase": "Preflight",
  "authorization": ""
}
```

Use `Apply` with `authorization` equal to `dr-first-node:Apply` only after a successful separate `Preflight`. Apply repeats preflight and requires a receipt from the same request, source SHA, repository content and recipient certificate within 24 hours. Use `Status` with empty authorization to report current service, UI HTTP and checkpoint state. Status success means the inspection completed; check service and HTTP fields for health. Push exactly one new envelope to `ops/layersentry-hyperv-inventory`, or use workflow_dispatch with its committed path after the workflow is registered on the repository default branch.

`RecoverDatabaseBootstrap` is a separate exceptional phase requiring authorization `dr-first-node:RecoverDatabaseBootstrap`. It invokes only the installer's guarded interrupted-bootstrap recovery: initialized MySQL identity, stopped service, absent temporary input, authenticated administrator access and absence of both CloudStack schemas must all be proven before the database journal marker is cleared. It neither creates nor deletes schemas. Run a new Preflight and Apply afterward.

Preflight performs the integrated installer's read-only OS/network/security checks and writes only a workflow receipt under `/var/lib/layersentry/dr-deployment`. Package availability and database schema gates still run in the installer during Apply. The GitHub global concurrency group and a remote file lock serialize execution. Configuration input paths stay fixed across attempts so the installer journal recognizes a retry. Apply preserves the installer's interrupted-database guard and does not select repair or bypass journal checks.

The remote bundle is staged under a per-run root-only `/run/layersentry-dr-deploy-<run>-<attempt>` directory. Runtime configuration and secrets use `/run/layersentry-dr-management-inputs`, which is deleted on normal and handled-error completion. Existing runtime input directories stop execution for operator inspection rather than deleting evidence of an interrupted operation. An abrupt runner, network or host failure may require root-only staging cleanup; the artifact reports whether cleanup was confirmed. The installed service credentials and encrypted keys remain where the installer requires them to run services; runtime-only refers to deployment input files, not to deleting operational credentials.

Artifacts contain only fixed, allowlisted evidence fields. Native SSH, installer, database, system journal and exception output are never published, and private staging is never uploaded. A failed artifact identifies a failure stage, exit code and safe checkpoint states. The operator can inspect sensitive native details directly on the VM. Successful Apply requires active database/Management/firewall/backup timer, SELinux Enforcing and a responding local UI. Authenticated API, browser, restart and isolated backup restore verification remain separate acceptance work.
