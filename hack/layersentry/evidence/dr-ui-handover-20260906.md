# DR UI deployment handover

Status: `SOURCE_COMPLETE`; live retry evidence pending.

Requested target: disposable Rocky Linux 9 management host `10.10.10.20:8080/client/`. Authorized UI source: `adaptgurus/cloudstack` commit `c4a2bb29457634e38a9375d5de33b04eb3a9c825`. Deployment base: `adaptgurus/cozystack` branch `ops/layersentry-hyperv-inventory`, commit `4df9d26326ede9b1c45be6274d657785cee0b2d9`.

Run `33997775237` failed with `Required command is missing: rsync`. Source inspection places that failure before staging, backup, service stop or UI replacement. The previous transport fixes are preserved. Latest eight workflow records inspected before the fix were completed; no newer DR UI deployment appeared in that snapshot.

Keep the existing rsync deployment/rollback implementation, which preserves CloudStack WEB-INF/META-INF, ACLs and extended attributes. Replacing it with a new copy/delete algorithm creates avoidable rollback risk. Provision only the missing prerequisite through the target's configured DNF repositories, after Rocky/version/service and artifact validation, with a bounded timeout. Installation failure blocks UI mutation. Do not disable repository signature verification. Package installation is an R3 test-host change; the installed prerequisite is retained if subsequent deployment fails. The existing webapp/config backup and rollback protect the UI deployment.

Merge remote script diagnostics into stdout before the Windows PowerShell transport, so native stderr does not skip evidence capture. Compare all deployed artifact files except the separately validated runtime config and compare HTTP entry HTML/JS/CSS against the exact staged artifact. CloudStack core/API/database and UI source are unchanged. Backend directories remain excluded from UI replacement. These checks do not certify every GUI/API workflow or the wider DR product.

Validation: Bash syntax and ShellCheck passed. Isolated prerequisite checks passed for already-installed rsync (no package mutation), missing rsync (successful provisioning), and failed provisioning (UI mutation blocked). Live Rocky verification remains pending until the next runner artifact records success. The requested exact artifact is rebuilt and qualified by the existing pinned workflow; no build occurs on the management host.

Next gate: one request-driven deployment, inspect its exact run and evidence, diagnose any subsequent failure before retry, and record final source/run/artifact identity and truthful acceptance scope.

## Dedicated-session handoff

The user reassigned DR to another Codex session. No further deployment is dispatched by this session. Runner branch now contains prerequisite/transport/hash-verification change `c4765bfd6` and read-only probe `1d4c4ccdf`.

Deployment run `33998290057` passed its hosted build and qualification but failed before UI mutation with `cloudstack-ui is not exact version 4.22.1.1`. Deployment evidence artifact name: `layersentry-dr-cloudstack-ui-evidence-33998290057-1`. The rsync provisioning block was not reached because package checks precede it.

Read-only probe run `33998699769`, artifact `dr-ui-readonly-probe-33998699769`, established Rocky Linux 9.8, `cloudstack-management-4.22.1.1-1.noarch`, absent `cloudstack-ui`, and ownership of `/usr/share/cloudstack-management/webapp/index.html` by `cloudstack-management-4.22.1.1-1.noarch`. The management service is active; localhost and Windows-runner requests to `http://10.10.10.20:8080/client/` returned HTTP 200. This is existing-service evidence, not proof that requested LayerSentry UI commit is deployed. This session's direct network path to the private address timed out.

Confirmed next fix: validate exact `cloudstack-management` version and its ownership of the served webapp rather than require the separate `cloudstack-ui` package. The CloudStack source `packaging/el8/cloud.spec` packages management webapp assets inside the management RPM; `cloudstack-ui` is a separate subpackage, not a management dependency. Keep backend WEB-INF/META-INF preservation and all immutable artifact/config/hash checks. Then retry once after checking current branch and in-flight workflows; the missing-rsync provisioning fix remains unverified on Rocky until reached.

DR owner must record final run/artifact/digest and actual Rocky assertions. Full GUI/API/persona/browser regression and broader DR certification have not been claimed. Local source worktree for these committed changes is `/home/opc/layersentry/dr-ui-handover-fix`; another writer should use an isolated worktree. Other module work belongs to the receiving session, with conflicting lab mutations serialized with the dedicated DR owner.
