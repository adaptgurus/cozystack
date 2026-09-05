# DR UI deployment handover

Status: `SOURCE_COMPLETE`; live retry evidence pending.

Requested target: disposable Rocky Linux 9 management host `10.10.10.20:8080/client/`. Authorized UI source: `adaptgurus/cloudstack` commit `c4a2bb29457634e38a9375d5de33b04eb3a9c825`. Deployment base: `adaptgurus/cozystack` branch `ops/layersentry-hyperv-inventory`, commit `4df9d26326ede9b1c45be6274d657785cee0b2d9`.

Run `33997775237` failed with `Required command is missing: rsync`. Source inspection places that failure before staging, backup, service stop or UI replacement. The previous transport fixes are preserved. Latest eight workflow records inspected before the fix were completed; no newer DR UI deployment appeared in that snapshot.

Keep the existing rsync deployment/rollback implementation, which preserves CloudStack WEB-INF/META-INF, ACLs and extended attributes. Replacing it with a new copy/delete algorithm creates avoidable rollback risk. Provision only the missing prerequisite through the target's configured DNF repositories, after Rocky/version/service and artifact validation, with a bounded timeout. Installation failure blocks UI mutation. Do not disable repository signature verification. Package installation is an R3 test-host change; the installed prerequisite is retained if subsequent deployment fails. The existing webapp/config backup and rollback protect the UI deployment.

Merge remote script diagnostics into stdout before the Windows PowerShell transport, so native stderr does not skip evidence capture. Compare all deployed artifact files except the separately validated runtime config and compare HTTP entry HTML/JS/CSS against the exact staged artifact. CloudStack core/API/database and UI source are unchanged. Backend directories remain excluded from UI replacement. These checks do not certify every GUI/API workflow or the wider DR product.

Validation: Bash syntax and ShellCheck passed. Isolated prerequisite checks passed for already-installed rsync (no package mutation), missing rsync (successful provisioning), and failed provisioning (UI mutation blocked). Live Rocky verification remains pending until the next runner artifact records success. The requested exact artifact is rebuilt and qualified by the existing pinned workflow; no build occurs on the management host.

Next gate: one request-driven deployment, inspect its exact run and evidence, diagnose any subsequent failure before retry, and record final source/run/artifact identity and truthful acceptance scope.
