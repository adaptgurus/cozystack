# DC GUI transport and fixture draft

Status: SOURCE_COMPLETE for the draft and focused tests; native Windows/DC SSH/API/GUI execution remains NOT_TESTED. Scope is new source files only; no workflow dispatch, host trust change, SSH key enrollment, project creation or GUI execution is authorized for this worker. Root owns live integration and reviews any Apply request.

The trusted Windows wrapper uses existing Rocky R0 host/user/password and independently verified DC known_hosts. The only destination is root@10.10.10.14 with verified Ed25519 fingerprint SHA256:ibF5v8VUj3Iawmgn/czLeJK7zUAM2kIqIJdzV04uFPw. Reuse proven OpenSSH askpass, not PuTTY: a protected helper reads the SSH password from its child-only environment; no password appears in arguments, source or logs. Fixed -N/-T forwarding binds only 127.0.0.1 to remote127.0.0.1:8080. Native Windows listener ownership must match the exact spawned ssh.exe PID, executable and start time before any API/browser credential is sent. Cleanup terminates only that child and verifies its listener closed. Existing harness files remain untouched; root can integrate the matching openDcTunnel interface.

Read-only Plan signs CloudStack API requests and sends POST bodies only over the authenticated SSH loopback forward. Native getUser(userapikey) binds the API credential to exact enabled userid, username, account/accountid/accounttype and domainid; username must match the existing GUI operator credential reference. Raw UserResponse is never retained because it can contain API/secret keys. Native listDomains confirms the root login domain for the initial platform-admin persona. Native listProjects with exact account/domain filters provides active project UUID/name. A suitable existing project is selected only from that observed scope; otherwise Plan proposes one uniquely named empty disposable GUI project without inventing its UUID.

Apply is an explicit draft consuming exact Plan SHA. It re-observes operator/project state, writes a durable exclusive submission intent before the single native createProject request, and records job/created identity. A timeout or lost response leaves UNKNOWN; no automatic resubmission occurs. Observation can reconcile a known async job or exact uniquely owned project name. No accounts, users, VMs, networks, storage, zones, roles or settings are created/changed. The root-owned journal is retained for review; no automatic project deletion is attempted.

Exact source contracts: CloudStack4.22.1.1 GetUserCmd (userapikey), UserResponse (sensitive response), ListProjectsCmd (account/domain/state/page filters), ListDomainsCmd and CreateProjectCmd (BaseAsyncCreateCmd; explicit userid/accountid/domainid ownership). The existing dr-dc-trust launcher demonstrates the askpass environment and Legacy-safe remote argv convention; this local-forward transport has no remote shell command or nested command quoting.

## Integration inputs and review sequence

Only six new files in this directory are changed. Existing `accept.mjs`, `contract.mjs`, `tunnel.mjs`, `invoke-acceptance.ps1`, root UI deployment, workflows and ledgers are untouched. `dc-tunnel.mjs` exports `openDcTunnel(binding)` returning `{base,proof,alive,assertReady,close}`; root must integrate DC routing while preserving existing request/persona/artifact checks. `assertReady()` rechecks listener ownership before API requests and should run before browser credential delivery. No keyscan/enrollment fallback exists.

Map existing protected refs to wrapper environment: `ROCKY_HOST/ROCKY_USERNAME/ROCKY_PASSWORD` from `LAYERSENTRY_ROCKY_R0_HOST/USERNAME/PASSWORD`; `DC_KNOWN_HOSTS` from the verified DC known_hosts reference (current inventory workflow uses `LAYERSENTRY_DC_SSH_KNOWN_HOSTS`); `CLOUDSTACK_API_KEY/CLOUDSTACK_SECRET_KEY` from the existing DC API pair; `LAYERSENTRY_CLOUDSTACK_USERNAME` from the GUI operator username. No credential values were read or recorded here. The GUI password is unnecessary for Plan.

Root runs Plan first under its existing global `layersentry-live-environment` reservation, with a fresh output directory:

```powershell
./hack/layersentry/gui-acceptance/invoke-dc-fixture.ps1 -Mode Plan -EvidenceDirectory $PlanEvidenceDirectory
```

Sanitized `dc-fixture.json` contains native operator metadata and, when available, an owned Active project. Its `persona` has `expectedUserId`, `accountType`, `projectId` and `projectName` for the later GUI request. Raw getUser responses, keys and HTTP bodies never enter evidence. This is API identity evidence, not GUI login proof. Initial existing-operator scope requires accountType1 and an observed level0 ROOT domain before setting loginDomain `/`; other domains/personas block instead of receiving guessed identity. Additional personas remain NOT_TESTED.

If Plan proposes an empty disposable project, root reviews its exact observed owner/domain/user and unique name, then supplies the exact file SHA for one Apply:

```powershell
./hack/layersentry/gui-acceptance/invoke-dc-fixture.ps1 -Mode Apply -EvidenceDirectory $ApplyEvidenceDirectory -ReviewedPlanPath $ReviewedPlanPath -ReviewedPlanSha256 $ReviewedPlanSha256
```

The sole native mutation is createProject with observed accountid/domainid/userid, unique name and correlation displaytext; CloudStack owns the internal project-account creation. The persistent journal is `%ProgramData%\LayerSentry\gui-fixtures\dc\<requestId>.json`. Protected ACL, no links/hardlinks, exclusive creation and flushed intent precede submission. Every existing journal blocks Apply, including after restart or UNKNOWN. Keep it; deleting a journal to retry would defeat the no-replay contract. Root separately reviews eventual native project cleanup after proving ownership and emptiness; this draft does not delete projects or mutate accounts/roles/VMs/network/zone/host trust.

Use Observe with the same Plan/hash to query the stored async job or correlate the exact native project, without another create:

```powershell
./hack/layersentry/gui-acceptance/invoke-dc-fixture.ps1 -Mode Observe -EvidenceDirectory $ObserveEvidenceDirectory -ReviewedPlanPath $ReviewedPlanPath -ReviewedPlanSha256 $ReviewedPlanSha256
```

A missing or ambiguous project, pending job or transport error cannot certify success. Existing-project Plan is not a create plan. Apply re-observes native identity/project state and rejects drift before durable intent. Plan uses explicit nonempty sentinel arguments for non-applicable fields, preserving positions under Windows PowerShell Legacy native argument passing; there is no nested remote command quoting.

## Verification and remaining gates

17 focused tests PASS with Node24.20.0: exact public host-key binding, fixed target/argv, foreign/stale listener owner rejection, sensitive response filtering, real-identity persona projection, owned/Active project selection, truncated-list/root-domain rejection, native signed POST and redirect refusal, explicit owner-scoped single create, UNKNOWN/restart/replay, concurrent exclusive intent, Plan/journal correlation and mutation-free Observe. The actual new PowerShell listener proof runs against mocked process/socket inspection; both new PowerShell scripts parse successfully. Run:

```bash
LAYERSENTRY_TEST_PWSH=/path/to/pwsh node --test hack/layersentry/gui-acceptance/dc-fixture.test.mjs
```

There was no live dispatch, DC connection, credential retrieval, project creation, browser login or GUI test from this worker. Actual Windows askpass/listener operation, DC native operator/project IDs and rendered UI remain NOT_TESTED. Test UUIDs are mock values, not lab evidence. Root performs live Plan and reviews any Apply before integration.

Knowledge relationships for integration: verified OOB DC key → fixed strict password SSH → exact owned listener → encrypted-loopback native API → observed operator/owned project → later browser identity assertion. Durable fixture journal → one immutable create intent → observation-only ambiguous recovery; it never authorizes another submission.


## Shared browser fence and launch diagnostics

The DC and DR transports now share `owned-tunnel.mjs` and the explicit target-aware listener inspector. The process PID, executable and start-time proof is refreshed before password fill and native login POST; a wrong listener never receives the credential callback. DC GUI integration consumes only hash-pinned successful native fixture evidence and checks the actual operator, account type and Active project; root owns workflow mapping and live acceptance. Focused source tests include both targets, wrong PID/path/start time, denied listener inspection, fixture drift and credential callback rejection.

The first DC Plan run `34062346063` failed before API discovery with only `DC_SSH_TUNNEL_FAILED`. Root's separate TLS Plan `34062472402` subsequently proved `C:\WINDOWS\System32\OpenSSH\ssh.exe` / `OpenSSH_for_Windows_9.5p2` exists and strict password SSH reaches DC, so executable absence is not an established cause. No executable substitution or password retry was added. Future failed launches write a public receipt containing only spawn error code, numeric exit/safe signal, exact target/PID/port, prerequisite booleans, bounded stderr category and cleanup outcome. Stderr is limited to 32 KiB in process memory, classified then erased; raw output, environment values and arguments are never retained. The categories are conservative indicators; UNKNOWN remains unresolved and no category authorizes a retry. Patterns follow [Windows OpenSSH 9.5 askpass source](https://github.com/PowerShell/openssh-portable/blob/v9.5.0.0/readpass.c) and [client source](https://github.com/PowerShell/openssh-portable/blob/v9.5.0.0/ssh.c), with no source changes to SSH itself. Actual Windows transport/browser verification remains pending.
