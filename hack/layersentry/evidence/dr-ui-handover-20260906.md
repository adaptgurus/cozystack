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

## Package-preflight correction

Status: `SOURCE_COMPLETE`; live retry remains the integration owner's next gate. The bounded source change is based on cozystack `b9bc68574ba5de9a06ad4e4f4e0829aa14953d10`, branch `codex/dr-preflight-tests`. No workflow was dispatched and no live host was mutated by this change.

Exact CloudStack tag `4.22.1.1`, `packaging/el8/cloud.spec`, copies `ui/dist/*` into the management webapp at line 284 and includes that path in `%files management` at line 644. The separate `%files ui` package owns `/usr/share/cloudstack-ui/*` at line 695. This confirms the probe's package layout and supports checking the package that owns the served entry HTML instead of installing an unrelated standalone UI package. Native API/plugin/XaaS changes are unnecessary for this package-preflight defect; no CloudStack core or architecture policy changes are involved.

The deployment now requires a successful exact `cloudstack-management` version query and a successful ownership query for the served `index.html` returning only `cloudstack-management 4.22.1.1`. Missing, wrong, ambiguous or failed query results block deployment before prerequisite provisioning or UI mutation. Backend-directory checks, immutable artifact checks, config/hash verification, rsync provisioning, backup and rollback remain intact. This validates RPM database ownership, not untouched original RPM file bytes: a previously deployed LayerSentry UI may legitimately differ from its packaged content.

Validation: `python3 -m unittest discover -s hack/layersentry -p 'test_deploy_dr_cloudstack_ui.py' -v` passed all 11 tests (16 fixture cases). The tests execute the actual package/filesystem/service/bundle preflight block with mocked RPM/service queries and temporary local files; no root or live service is required. Cases cover management-owned webapp with no standalone UI RPM, missing/wrong management version, query errors despite matching output, missing/wrong/multiple owners, missing entry HTML/backend directories, inactive management and incomplete bundle. The happy-path test was also executed against the unchanged base script and reproduced its `cloudstack-ui is not exact version 4.22.1.1` failure. `bash -n`, ShellCheck and `git diff --check` passed.

This source-level regression test does not prove rsync provisioning, deployment/rollback, browser behavior or DR recovery on Rocky. The integration owner must run the exact corrected script/artifact through the existing runner, inspect its evidence and record the actual assertions. Reverting this source commit restores the former preflight; no runtime rollback is needed for this source-only work. Shared ledger and knowledge-graph integration remain with the lead; no stable architecture or policy changed.
