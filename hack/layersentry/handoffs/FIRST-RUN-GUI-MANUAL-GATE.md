# LayerSentry / Harvester first-run GUI manual gate

This gate is intentionally **manual**. No workflow, script, browser automation, or API call may accept the Harvester EULA on the operator's behalf.

## Prerequisite

Proceed only when `hack/layersentry/handoffs/LATEST-SEN2-RECOVERY.md` records all of the following:

- `Cluster recovery gate passed: True`
- `sen2 consecutive stability samples: 24 / 24`
- `Authenticated Kubernetes/KubeVirt/Longhorn validation passed: True`
- `EULA automatically accepted: False`
- `Production release approved: False`

If any prerequisite is false or the latest handoff is absent, stop. Do not change node configuration, rerun an old request, rebuild the cluster, wipe disks, or delete RKE2 state.

## Manual browser procedure

1. From the trusted administrative session on `TESTSER`, open `https://10.10.10.10`.
2. Confirm the page is served by the expected Harvester management/API VIP. Do not use `https://10.10.10.11:443` as the management URL; that address is the rancherd bootstrap/join endpoint established by the recovery gate.
3. Read the administrator credential only from `C:\ProgramData\LayerSentry\bootstrap-credentials.json` in the protected local session. Never paste the credential into GitHub Actions logs, issues, commits, chat, screenshots, or evidence files.
4. Enter the first-run administrator password manually if the UI requests it.
5. Read the displayed EULA and accept it only through an explicit human action. Do not automate the checkbox, click, form submission, or related API request.
6. After login, confirm that the GUI opens normally and shows `sen1`, `sen2`, and `sen3` without a first-run redirect loop.
7. Confirm that the host, virtualization, and storage pages load. Do not create or delete workloads as part of this gate.
8. Record only the sanitized completion fields below. Do not record a password, token, cookie, authorization header, kubeconfig, certificate private key, or Kubernetes Secret payload.

## Sanitized completion record

Create a new uniquely named file under `hack/layersentry/evidence/first-run-gui/` containing only:

```json
{
  "schemaVersion": "1.0",
  "managementUrl": "https://10.10.10.10",
  "completedAtUtc": "<UTC timestamp>",
  "completedByHumanOperator": true,
  "firstRunPasswordEnteredManually": true,
  "eulaReviewedAndAcceptedManually": true,
  "firstRunRedirectCleared": true,
  "threeHostsVisible": true,
  "virtualizationPageLoaded": true,
  "storagePageLoaded": true,
  "credentialValuesWrittenToEvidence": false,
  "tokenWrittenToEvidence": false,
  "kubeconfigWrittenToEvidence": false,
  "productionReleaseApproved": false
}
```

The frontend-only `adaptgurus/harvester-ui-extension` LayerSentry rebranding continuation may start only after both the cluster recovery handoff and this human first-run record pass. This gate does not approve production release, HA, upgrades, backup/restore, workload qualification, or true-air-gap qualification.
