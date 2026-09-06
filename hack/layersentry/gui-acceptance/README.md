# LayerSentry authenticated GUI acceptance preparation

Status: SOURCE_COMPLETE. This is a read-only GUI acceptance harness, not live module certification. No browser/lab workflow was dispatched while implementing it. Root owns deployments, native persona/project fixture creation, DC/DR runtime reservations and the shared ledger/knowledge graph. No CloudStack core, UI feature or module backend changes are included.

## Source decision and evidence

The existing Cozystack `layersentry-cloudstack-served-ui-verify.yml` checks HTTP/branding/source strings, not authenticated browser behavior; its historical SSH bootstrap is not reused. The new harness retains the current native deployment artifact contract and adds actual browser login and native same-origin reads. Playwright is locked to 1.63.0 with npm integrity hashes, Node to 24.20.0 in the runner. Google Chrome uses the branded `chrome` channel, not a Chromium result relabeled Chrome. Firefox uses Playwright's version-specific patched Firefox (155.0/revision1543); both actual browser versions enter the receipt. This is not proof of stock Firefox or every supported browser release.

Exact official sources: [Playwright 1.63.0 browser inputs](https://github.com/microsoft/playwright/blob/v1.63.0/packages/playwright-core/browsers.json), [version-pinned browser/channel behavior](https://github.com/microsoft/playwright/blob/v1.63.0/docs/src/browsers.md), and [authentication-state handling](https://github.com/microsoft/playwright/blob/v1.63.0/docs/src/auth.md). Exact product source inspected at CloudStack `8f94ee6e2ac1e360e39b71b8247e64b62187ef0d`: `ui/src/views/auth/Login.vue`, `ui/src/store/modules/user.js`, `ui/src/config/router.js`, `ui/src/views/layersentry/KubernetesDataServices.vue`, `ui/src/api/layersentryKubernetes.js`. This bounded harness introduces no orchestration architecture; native CloudStack login/discovery stays authoritative, and XaaS is not applicable. Selenium was considered but would add a separate driver manager rather than reuse one pinned browser API. No product capability is inferred from the tool choice.

## Required artifact and fixture

Obtain the existing deployment-format artifact from the reviewed successful Cozystack build run: `ui-dist.tar.gz`, `ui-dist.tar.gz.sha256`, `build-manifest.json`. `prepare_artifact.py` verifies the independently requested archive SHA256, exact commit and existing deployment manifest schema before reading bounded tar members without extracting them. It rejects traversal, links, duplicates, backend files and oversized archives. Every served non-config asset is compared byte-for-byte by hash in both browser contexts. `config.json` is intentionally separate because the deployment preserves/merges runtime endpoints and module configuration: branding keys must match, API must remain same-origin `/client/api`, and multiple-server mode is rejected. The harness does not claim runtime config is byte-identical to the build or prove backend health from matching assets.

Create one public request under `hack/layersentry/gui-acceptance-requests/<reviewed-id>.json`. No executable request or invented project/user IDs are included with this source commit. Required shape (replace descriptive values with actual evidence):

```json
{
  "schema": 1,
  "target": "dr",
  "transport": "strict-ssh-loopback",
  "cloudstackUiCommit": "<40 hex exact deployed UI commit>",
  "artifactSha256": "<64 hex archive digest>",
  "artifactRunId": "<successful build run ID>",
  "artifactName": "<exact deployment artifact name>",
  "personas": [{
    "id": "platform-admin",
    "expectedUserId": "<native CloudStack user UUID>",
    "projectId": "<native active project UUID>",
    "projectName": "<unique displayed project name>"
  }]
}
```

Supported persona IDs are `platform-admin`, `department-admin`, `operator`, `auditor`. Omitted personas remain NOT_TESTED. A non-platform persona may additionally supply `foreignProjectId` from a verified separate tenant fixture; this read-only negative must return 403, otherwise it fails or reports an unavailable backend. Platform administrators must not supply a foreign-project-denial expectation because their native scope differs. Fixture account/role/project membership and eventual cleanup are established by root through existing native CloudStack APIs, not by this browser script.

For the explicitly authorized first DR operator test, choose workflow `credential_source=existing-operator`: existing `LAYERSENTRY_CLOUDSTACK_USERNAME` / `LAYERSENTRY_CLOUDSTACK_PASSWORD` secrets become a private, current-run temporary file and are removed from the child environment before browser launch. The first browser submits the known operator credential exactly once. Any rejection stops the run without retry; Firefox submits once only after Chrome authenticated the exact persona successfully. Their validity for DR is established only by that actual result. For fixture-created personas choose `protected-personas`, using the fixture-generated `C:\ProgramData\LayerSentry\gui-acceptance-credentials.json`, keyed by persona ID with `username`, `password`, `domain` fields. The wrapper checks owner/ACL, then Node rejects path symlinks/reparse points, nonregular/hardlinked or oversized inputs. The input must grant access only to the runner identity, SYSTEM or Administrators. The fixture owns removal of that original file; the harness removes only its own temporary directory. Linux direct invocation additionally requires current-user ownership and mode0600 (or stricter). Never print credentials, save browser storage state, or copy these files into artifact folders.

The existing native R0 API inventory separately injects `LAYERSENTRY_CLOUDSTACK_API_KEY` / `LAYERSENTRY_CLOUDSTACK_SECRET_KEY` for DC and `LAYERSENTRY_DR_CLOUDSTACK_API_KEY` / `LAYERSENTRY_DR_CLOUDSTACK_SECRET_KEY` for DR. Those are API-signing credentials, not browser passwords; this harness does not convert or guess them. Authentication uses one real GUI submission per browser/persona, binds returned user UUID, and attempts native logout even on failure. MFA/password-reset/intermediate-login failures remain unverified; the harness does not bypass them.

## Runner handoff

Integrate through the lead runner writer and supply a reviewed request from actual build and native persona/project evidence. Root owns workflow target/secret mapping and scheduling browser installation. Both transports spawn the exact Windows `System32/OpenSSH/ssh.exe` child and forward only an ephemeral `127.0.0.1` port to the selected manager's `127.0.0.1:8080`. DR binds `.20` and its existing private key/known-hosts; DC binds `.14/root` and the independently verified Ed25519 host fingerprint through the existing protected askpass mechanism. Native process inspection must prove exactly one loopback listener belongs to that SSH PID, executable and current process start time. The browser repeats this proof immediately before password entry and again before permitting its one native login POST. A rejected proof stops authentication, and cleanup terminates only the owned child and proves the listener absent. No LAN plaintext browser password or host-access change is introduced.

DC additionally requires `target=dc`, exactly one `platform-admin` persona with native `accountType=1`, and `dcFixtureSha256` binding the exact public `dc-fixture.json` bytes from a successful Plan selecting an existing Active project or a correlated Observe result. Pass those bytes via `-DcFixtureEvidencePath`; pending/create proposals do not qualify. Node verifies the observed DC operator UUID, account/domain, username, root login domain, exact project UUID/name/domain and trusted transport before any SSH/browser use. Login must then return that actual user UUID and account type. No DC IDs are copied from DR, and other personas remain NOT_TESTED. The wrapper maps existing DC secrets to `ROCKY_HOST`, `ROCKY_USERNAME`, `ROCKY_PASSWORD`, `DC_KNOWN_HOSTS` plus the existing CloudStack browser username/password; it does not use API-signing credentials for GUI login.

For a direct reviewed invocation, first run `python prepare_artifact.py <bundle> <commit> <sha256> <new-inventory.json>`, then `node accept.mjs <request.json> <inventory.json> <protected-credentials.json> <new-evidence-directory> <protected-tunnel-binding.json>`. The DR protected binding contains `target=dr`, `host=10.10.10.20`, approved SSH `user` and `keyFile`/`knownHostsFile`; DC contains `target=dc`, `host=10.10.10.14`, `user=root` and `passwordFile`/`askPassFile`/`knownHostsFile`/`nativeFixtureFile`. Every referenced file must share the private binding directory. Windows must use the ACL-verifying PowerShell wrapper. Direct LAN HTTP and caller-chosen forwarding targets are rejected; HTTPS support is not implemented in this bounded revision. Evidence directories must be new and private. Exit1 means a harness/GUI assertion failed; exit2 means read-only checks finished but module lifecycles remain PARTIAL/NOT_TESTED. Exit2 intentionally keeps the workflow from advertising whole-product success. `moduleCompletionApproved` is always false.

Only allowlisted `acceptance.json` and a screenshot of the fixed module title are uploaded. No trace, video, HAR, page HTML, raw body, browser console, error stack, session/cookie/header or credential-bearing URL is retained. Generic browser failures are reported using fixed error categories. Full screenshots of customer data and login forms after credential entry are deliberately excluded. The receipt includes artifact/runner/run binding, actual browser versions, per-persona checks, backend HTTP projections, and explicit module gaps. It does not prove Rocky host configuration, TLS, data recovery or account cleanup; those require root's separate evidence.

## Exact current GUI/API coverage and gaps

| Surface | Native browser flow | Required live contract | Honest unmet gate |
| --- | --- | --- | --- |
| Login | `/client/#/user/login`, `#formLogin`, native username/password/domain inputs | CloudStack `login` POST, exact returned `userid`, session cookie | Missing credential, role/MFA/reset or authentication failure is not a pass |
| Kubernetes | `/client/#/kubernetes-data-services`, `.layersentry-k8s-services`, `#k8s-project`, visible unique project option | Native paginated `listProjects`; `/client/layersentry-k8s/v1/kubernetes/readiness`; project-scoped `clusters`, `operations`, `packages` | Closed readiness requires visible warning and disabled Create; provisioning is NOT_TESTED |
| Package screen | Select an existing project-owned cluster by displayed name | Real cluster list/detail plus project catalog/status reads from UI | No cluster fixture or lifecycle execution is NOT_TESTED |
| DBaaS/APaaS/Streaming | Actual module tabs | Current source renders explicit provisioning unavailable messages | BLOCKED; a visible tab is never service completion |
| DR replication | No dedicated route/component in inspected product source | Future provider-backed Protection Plan/Recovery Point UI contract | NOT_TESTED; native Backup/Quick Provision is not a substitute |

The guard aborts cross-origin requests and every module mutation; native CloudStack API allows read commands plus login/logout only. No API is mocked or fulfilled with synthetic data. Tests of the guard/parser are source tests, not replacements for live GUI acceptance. Cluster/package create, scale, delete, asynchronous convergence, application data persistence/restore, cross-site replication, full persona isolation, responsive/accessibility checks and realistic package operations remain separate acceptance tasks. Root must implement the missing DR GUI and DBaaS/APaaS lifecycle contract before those modules can be certified.

## Local qualification and rollback

Run `npm ci --ignore-scripts --no-audit --no-fund`, `npm test`, and `python3 -m unittest discover -s . -p 'test_*.py' -v` in this directory. Six Node tests exercise exact scope/artifact binding, blocked mutations/cross-origin credentials, readiness truthfulness, safe errors, private-file link/mode/size handling and exact SSH forwarding/trust arguments; three Python tests cover archive digest/commit, runtime config separation and malicious members. All nine passed locally. No Chrome/Firefox live login, Windows ACL runtime, backend connection or host change was executed. The workflow YAML and PowerShell wrapper/inline scripts parse successfully with the local PowerShell parser; this is not Windows ACL or SSH runtime verification. Reverting this isolated source commit removes the new workflow/harness; there is no live product rollback from this task. Root owns the ledger/knowledge-graph relationship update: exact UI artifact → authenticated browser evidence → real module prerequisites → lifecycle acceptance.
