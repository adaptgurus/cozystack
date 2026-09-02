#!/usr/bin/env bash
set -Eeuo pipefail

stage='initialization'
repo_root="$(git rev-parse --show-toplevel)"
ui_root="$repo_root/hack/layersentry/ui-production-v3"
request_path="${REQUEST_PATH:?REQUEST_PATH is required}"
request="$repo_root/$request_path"
evidence_root="${EVIDENCE_ROOT:?EVIDENCE_ROOT is required}"
source_commit="${GITHUB_SHA:?GITHUB_SHA is required}"
run_id="${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
source_epoch="${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required}"
release_archive="$ui_root/layersentry-production-ui-v3.tar.gz"
release_archive_checksum="$ui_root/layersentry-production-ui-v3.tar.gz.sha256"
mkdir -p "$evidence_root"

write_terminal_result() {
  local rc="$1"
  local passed=false
  local failure=''
  local archive_sha=''
  if (( rc == 0 )); then
    passed=true
  else
    failure="Qualification stopped at stage: $stage"
  fi
  if [[ -s "$release_archive_checksum" ]]; then
    archive_sha="$(awk 'NR == 1 {print $1}' "$release_archive_checksum")"
  fi

  jq -n \
    --arg sourceCommit "$source_commit" \
    --arg workflowRunId "$run_id" \
    --arg requestPath "$request_path" \
    --arg completedStage "$stage" \
    --arg failure "$failure" \
    --arg releaseArchiveSha256 "$archive_sha" \
    --argjson passed "$passed" \
    '{
      schemaVersion: "1.0",
      product: "LayerSentry",
      component: "production-ui",
      sourceCommit: $sourceCommit,
      workflowRunId: $workflowRunId,
      requestPath: $requestPath,
      completedStage: $completedStage,
      failure: (if $failure == "" then null else $failure end),
      dependencyFreeBuild: true,
      responsiveCorrectionVerified: $passed,
      securityHeaderInheritanceVerified: $passed,
      reproducibleAssemblyVerified: $passed,
      integrityManifestVerified: $passed,
      spdxSbomVerified: $passed,
      hardenedDeploymentTemplateVerified: $passed,
      releaseArchiveSha256: (if $releaseArchiveSha256 == "" then null else $releaseArchiveSha256 end),
      liveClusterDeploymentPerformed: false,
      bootstrapCredentialFileRead: false,
      credentialValuesWrittenToEvidence: false,
      kubeconfigPublished: false,
      productionReleaseApproved: false,
      qualificationGatePassed: $passed
    }' > "$evidence_root/terminal-result.json"

  cat > "$evidence_root/STATUS.md" <<EOF
# LayerSentry UI authoritative release qualification

- Source commit: \`$source_commit\`
- Release request: \`$request_path\`
- Completed stage: **$stage**
- Qualification gate passed: **$passed**
- Dependency-free build: **required**
- Responsive correction: **verified only when gate passes**
- Security-header inheritance: **verified only when gate passes**
- Reproducible assembly: **verified only when gate passes**
- Integrity manifest and SPDX SBOM: **verified only when gate passes**
- Hardened deployment template: **verified only when gate passes**
- Live cluster deployment performed: **false**
- Protected bootstrap credential file read: **false**
- Credential values written to evidence: **false**
- Kubeconfig published: **false**
- Production release approved: **false**
- Failure: ${failure:-none}
EOF
}

on_exit() {
  local rc="$?"
  trap - EXIT
  set +e
  write_terminal_result "$rc"
  exit "$rc"
}
trap on_exit EXIT

stage='request-validation'
[[ -f "$request" ]]
request_bytes="$(wc -c < "$request")"
(( request_bytes > 0 && request_bytes <= 8192 ))

jq -e '
  def allowedKeys: [
    "schemaVersion",
    "requestId",
    "operation",
    "authorization",
    "sourcePackage",
    "expectedProduct",
    "expectedReleaseChannel",
    "requireDependencyFreeBuild",
    "requireResponsiveCorrection",
    "requireSecurityHeaderInheritanceProof",
    "requireReproducibleAssembly",
    "requireIntegrityManifest",
    "requireSpdxSbom",
    "requireHardenedDeploymentTemplate",
    "liveClusterDeploymentAuthorized",
    "readBootstrapCredentialFile",
    "writeCredentialValuesToEvidence",
    "publishKubeconfig",
    "productionReleaseApprovalImplied"
  ];
  ((keys | sort) == (allowedKeys | sort)) and
  .schemaVersion == "1.0" and
  (.requestId | type == "string" and test("^qualify-layersentry-ui-[a-z0-9-]+$")) and
  .operation == "QUALIFY_LAYERSENTRY_UI_RELEASE_CANDIDATE" and
  .authorization == "REPOSITORY_BUILD_AND_TEST_ONLY" and
  .sourcePackage == "hack/layersentry/ui-production-v3" and
  .expectedProduct == "LayerSentry" and
  .expectedReleaseChannel == "release-candidate" and
  .requireDependencyFreeBuild == true and
  .requireResponsiveCorrection == true and
  .requireSecurityHeaderInheritanceProof == true and
  .requireReproducibleAssembly == true and
  .requireIntegrityManifest == true and
  .requireSpdxSbom == true and
  .requireHardenedDeploymentTemplate == true and
  .liveClusterDeploymentAuthorized == false and
  .readBootstrapCredentialFile == false and
  .writeCredentialValuesToEvidence == false and
  .publishKubeconfig == false and
  .productionReleaseApprovalImplied == false
' "$request" >/dev/null

if jq -r '.. | strings' "$request" | grep -E -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|Bearer[[:space:]]+[A-Za-z0-9._~-]{10,}'; then
  echo 'Release request contains private-key or bearer-token material.' >&2
  exit 1
fi

stage='runtime-validation'
node --version
npm --version
node_major="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
[[ "$node_major" =~ ^[0-9]+$ ]]
(( node_major >= 20 ))
[[ ! -d "$ui_root/node_modules" ]]
node -e '
  const p = require(process.argv[1]);
  if (Object.keys(p.dependencies || {}).length !== 0 || Object.keys(p.devDependencies || {}).length !== 0) {
    throw new Error("LayerSentry UI must remain dependency-free");
  }
' "$ui_root/package.json"
[[ "$source_epoch" =~ ^[0-9]+$ ]]
[[ "$source_commit" =~ ^[a-f0-9]{40}$ ]]

cd "$ui_root"

stage='source-validation'
npm run validate

stage='contract-tests'
SOURCE_DATE_EPOCH="$source_epoch" LAYERSENTRY_BUILD_SHA="$source_commit" npm test

stage='canonical-assembly'
SOURCE_DATE_EPOCH="$source_epoch" LAYERSENTRY_BUILD_SHA="$source_commit" npm run build
node scripts/finalize-release.mjs
npm run verify-dist
node scripts/verify-server-policy.mjs
(
  cd release
  sha256sum --check SHA256SUMS
)

stage='reproducibility-proof'
first_release="$(mktemp -d)"
cp -a release/. "$first_release/"
rm -rf release
SOURCE_DATE_EPOCH="$source_epoch" LAYERSENTRY_BUILD_SHA="$source_commit" npm run build
node scripts/finalize-release.mjs
diff -qr "$first_release" release
npm run verify-dist
node scripts/verify-server-policy.mjs

stage='metadata-sbom-validation'
jq -e --arg sha "$source_commit" '
  .schemaVersion == "1.0" and
  .product == "LayerSentry" and
  .component == "production-ui" and
  .canonicalAssembler == "ui-production-v3" and
  .commit == ($sha | ascii_downcase) and
  .externalRuntimeDependencies == 0 and
  .browserCredentialStorage == "none" and
  .apiSessionMode == "same-origin-cookie" and
  .serverPolicy == "nginx-secure-v2" and
  .serverSecurityHeaderInheritanceReviewed == true and
  .canonicalReleaseFinalized == true and
  .liveClusterDeploymentPerformed == false and
  .productionReleaseApprovalImplied == false
' release/release-metadata.json >/dev/null

jq -e '
  .schemaVersion == "1.0" and
  .product == "LayerSentry" and
  (.files | has("www/index.html")) and
  (.files | has("www/assets/layersentry.css")) and
  (.files | has("www/assets/layersentry.js")) and
  (.files | has("deploy/nginx.conf")) and
  ([.files[].sha256 | test("^[a-f0-9]{64}$")] | all) and
  ([.files[].integrity | test("^sha384-[A-Za-z0-9+/]+={0,2}$")] | all)
' release/asset-manifest.json >/dev/null

jq -e '
  .spdxVersion == "SPDX-2.3" and
  .dataLicense == "CC0-1.0" and
  ((.packages | length) == 1) and
  ((.files | length) >= 7) and
  ((.relationships | length) == (.files | length))
' release/sbom.spdx.json >/dev/null

stage='deployment-contract-validation'
grep -Fx 'ARG BASE_IMAGE' Containerfile
grep -Fx 'FROM ${BASE_IMAGE}' Containerfile
if grep -E '^FROM[[:space:]]+[^$]' Containerfile; then
  echo 'Containerfile contains a hard-coded base image.' >&2
  exit 1
fi
grep -F 'USER 101:101' Containerfile
grep -F 'readOnlyRootFilesystem: true' deploy/kubernetes/deployment.yaml
grep -F 'allowPrivilegeEscalation: false' deploy/kubernetes/deployment.yaml
grep -F 'type: RuntimeDefault' deploy/kubernetes/deployment.yaml
grep -F 'automountServiceAccountToken: false' deploy/kubernetes/deployment.yaml
grep -F 'registry.invalid/layersentry/production-ui@sha256:0000000000000000000000000000000000000000000000000000000000000000' deploy/kubernetes/deployment.yaml
grep -F 'pod-security.kubernetes.io/enforce: restricted' deploy/kubernetes/namespace.yaml
grep -F 'egress: []' deploy/kubernetes/network-policy.yaml
if grep -RInE '^[[:space:]]*kind:[[:space:]]*Secret[[:space:]]*$|^[[:space:]]*stringData:[[:space:]]*$|^[[:space:]]*data:[[:space:]]*$' deploy/kubernetes; then
  echo 'Kubernetes UI template contains a Secret resource or inline secret data.' >&2
  exit 1
fi

stage='release-security-scan'
if grep -RInE --exclude='*.svg' 'https?://|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|Bearer[[:space:]]+[A-Za-z0-9._~-]+' release/www release/deploy; then
  echo 'Release contains an external URL or secret indicator.' >&2
  exit 1
fi
if grep -RInE '(password|passwd|secret|token)[[:space:]]*[:=][[:space:]]*["'"'][^"'"']{4,}["'"']' release/www release/deploy; then
  echo 'Release appears to contain a hard-coded credential.' >&2
  exit 1
fi
if grep -RInE '\.innerHTML[[:space:]]*=|insertAdjacentHTML|document\.write|(^|[^[:alnum:]_])eval[[:space:]]*\(' release/www; then
  echo 'Release contains an unsafe browser-code primitive.' >&2
  exit 1
fi
if find release -type f \( -name '*.map' -o -name '*.pem' -o -name '*.key' -o -name 'kubeconfig*' \) -print -quit | grep -q .; then
  echo 'Source maps, private keys or kubeconfigs are forbidden in the release.' >&2
  exit 1
fi

stage='deterministic-archive'
rm -f "$release_archive" "$release_archive_checksum"
tar \
  --sort=name \
  --mtime="@$source_epoch" \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -cf - release | gzip -n -9 > "$release_archive"
sha256sum "$(basename "$release_archive")" > "$release_archive_checksum"

stage='complete'
