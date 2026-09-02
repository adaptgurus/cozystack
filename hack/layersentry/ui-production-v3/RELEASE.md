# LayerSentry production UI release procedure

## Build the canonical release

Node.js 20 or newer is required. No package installation or public network access is required.

```bash
cd hack/layersentry/ui-production-v3
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
export LAYERSENTRY_BUILD_SHA="$(git rev-parse HEAD)"
npm run validate
npm test
npm run build
node scripts/finalize-release.mjs
npm run verify-dist
node scripts/verify-server-policy.mjs
(
  cd release
  sha256sum --check SHA256SUMS
)
```

The canonical web root is `release/www`. The canonical server configuration is `release/deploy/nginx.conf`. Use the generated `release-metadata.json`, `asset-manifest.json`, `sbom.spdx.json` and `SHA256SUMS` as the release evidence set.

## Build a container image

The `Containerfile` requires an approved base image by immutable digest. Do not provide a mutable tag.

```bash
podman build \
  --build-arg BASE_IMAGE='approved-registry.example/nginx-unprivileged@sha256:<verified-digest>' \
  --build-arg VERSION='1.0.0-rc.1' \
  --build-arg REVISION="$(git rev-parse HEAD)" \
  --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --tag 'approved-registry.example/layersentry/production-ui:1.0.0-rc.1' \
  --file Containerfile \
  .
```

Before promotion, record the resulting image digest, vulnerability-policy result, signature, provenance and SBOM association. The Kubernetes deployment must be changed from the deliberately invalid placeholder to that verified digest.

## Route the application

Configure the trusted LayerSentry ingress/API gateway so these paths share one origin:

```text
/                                  release/www
/assets/*                          release/www/assets
/v1/layersentry/ui/overview       authenticated read-only adapter
/dashboard/*                       existing management console
```

Do not proxy the protected bootstrap credential file, cluster join material, kubeconfigs or Kubernetes Secret resources through the UI route.

## Guarded deployment

Do not deploy while a cluster node is being reimaged or while a recovery workflow is pending. Required preconditions are defined in `PRODUCTION-READINESS.md`.

Once the three-node runtime is healthy:

1. substitute the verified UI image digest in `deploy/kubernetes/deployment.yaml` in a release workspace, not by committing a secret or mutable tag;
2. label only the trusted ingress namespace with `layersentry.io/ui-ingress=allowed`;
3. review the rendered manifests;
4. apply the bundle to the lab cluster;
5. verify two Ready UI replicas and the PodDisruptionBudget;
6. verify every HTTP security header at the cluster VIP;
7. verify the overview route enforces authentication and read-only RBAC;
8. execute browser, accessibility, failure-state and air-gap acceptance tests;
9. record explicit release approval separately.

Repository qualification does not authorize live deployment and does not constitute production approval.
