# LayerSentry / Harvester sen2 recovery handoff

- Evidence captured at UTC: 2026-09-02T16:46:17.5024318Z
- Branch: ops/layersentry-hyperv-inventory
- Recovery workflow run: $env:TARGET_RUN_ID
- Recovery head SHA: $env:TARGET_RUN_HEAD_SHA
- Workflow conclusion: **failure**
- Evidence artifact: $env:TARGET_ARTIFACT_ID
- Artifact digest: $env:TARGET_ARTIFACT_DIGEST
- Authoritative worker source verification passed: **True**
- Read-only endpoint verification passed: **False**
- Exact expected/observed rancherd URL match passed: **False**
- Exit-code-64 regression guard passed: **False**
- sen2 consecutive stability samples: **0 / 24**
- Authenticated Kubernetes/KubeVirt/Longhorn validation passed: **False**
- Cluster recovery gate passed: **False**
- First-run GUI password/EULA action remains manual: **True**
- EULA automatically accepted: **False**
- Production release approved: **False**
- Failure: Read-only authoritative plan verification through sen1 failed with SSH exit code 1.

Sanitized evidence is stored under hack/layersentry/evidence/sen2-recovery-run-33655993805/.
No password, token, kubeconfig, protected credential-file contents, or raw secret payload was committed.
