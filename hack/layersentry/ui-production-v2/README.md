# LayerSentry production UI v2

This package is the production-hardening layer for the LayerSentry management experience. It is deliberately dependency-free so the compiled bundle can be built, reviewed and operated in an air-gapped environment without npm registry access, CDN fonts, telemetry or third-party browser code.

It does not modify Hyper-V VMs, cluster plans, credentials, EULA state or Rancher/Harvester resources. Deployment remains a separate, explicitly authorised gate after the three-node cluster is healthy.

## Production design objectives

- LayerSentry-only product identity in the operator-facing shell.
- Responsive desktop, tablet and mobile layouts down to 320 CSS pixels.
- Keyboard navigation, skip link, semantic landmarks, live regions, visible focus, reduced-motion and high-contrast support.
- Explicit loading, healthy, degraded, critical, offline, authentication-required and unavailable states.
- Same-origin browser sessions only; the frontend never constructs an `Authorization` header.
- No credential, token, kubeconfig or API response persistence in browser storage.
- Strict content security policy and hardened static-serving headers.
- Deterministic air-gap build with no runtime dependency on public networks.
- Bounded API responses, request timeouts, content-type checks and schema normalisation.
- Safe DOM construction through `textContent` and `createElement`; no `innerHTML`, `eval` or dynamic code generation.
- Reproducible release metadata, SHA-256 checksums and SHA-384 integrity values.

## Repository layout

```text
ui-production-v2/
├── nginx.conf
├── package.json
├── public/
│   ├── index.html
│   └── assets/
│       ├── favicon.svg
│       ├── layersentry-mark.svg
│       ├── layersentry.css
│       └── layersentry.js
├── scripts/
│   ├── build.mjs
│   └── validate.mjs
└── tests/
    └── ui-contract.test.mjs
```

## Build and test

Node.js 20 or newer is required. The package has no installable dependencies and does not require `npm install`.

```bash
cd hack/layersentry/ui-production-v2
npm run ci
```

The output is written to `dist/` and includes:

- deployable static assets;
- `release-metadata.json`;
- `asset-manifest.json` with file size, SHA-256 and SHA-384 integrity values;
- `SHA256SUMS`.

For deterministic timestamps in reproducible builds, set `SOURCE_DATE_EPOCH`. In GitHub Actions, `GITHUB_SHA` is recorded automatically as build provenance.

## Runtime configuration

The shell uses safe defaults and accepts an optional same-origin runtime object before `layersentry.js` loads:

```js
globalThis.__LAYERSENTRY_UI_CONFIG__ = {
  environment: "Production",
  overviewEndpoint: "/v1/layersentry/ui/overview",
  consolePath: "/dashboard",
  refreshIntervalMs: 30000,
  requestTimeoutMs: 8000,
  buildVersion: "v1.0.0"
};
```

Only absolute same-origin paths beginning with a single `/` are accepted. External URLs, protocol-relative URLs and invalid timing values are discarded. Do not put credentials, bearer tokens, kubeconfigs or cluster join material in this object.

## Overview API contract

`GET /v1/layersentry/ui/overview` must be routed through the same origin as the UI. The browser sends existing same-origin cookies and requests JSON with `cache: no-store`. The endpoint must enforce the platform's existing authentication and RBAC model.

Expected response:

```json
{
  "health": "healthy",
  "environment": "Production",
  "version": "v1.0.0",
  "observedAt": "2026-09-03T00:00:00Z",
  "nodes": {
    "ready": 3,
    "total": 3,
    "items": [
      {
        "name": "sen1",
        "address": "10.10.10.11",
        "role": "Management",
        "state": "ready",
        "cpuPercent": 21,
        "memoryPercent": 48
      }
    ]
  },
  "virtualMachines": {
    "running": 4,
    "total": 5
  },
  "storage": {
    "usedBytes": 1099511627776,
    "totalBytes": 2199023255552,
    "healthyVolumes": 12,
    "totalVolumes": 12
  },
  "alerts": {
    "critical": 0,
    "warning": 1,
    "total": 1
  },
  "events": [
    {
      "severity": "info",
      "resource": "sen2",
      "message": "Node joined the cluster",
      "timestamp": "2026-09-03T00:00:00Z"
    }
  ]
}
```

Accepted aggregate health values are `healthy`, `degraded`, `critical` and `unknown`. Accepted node states are `ready`, `warning`, `not-ready` and `unknown`. Event severities are `info`, `warning` and `critical`.

The frontend deliberately limits the response to 64 nodes, eight recent events and one megabyte. Invalid or excessive values are rejected or normalised to safe defaults.

## Integration with the existing dashboard

The production shell is additive. It can be exposed as `/` while the existing authenticated management console remains under `/dashboard`, or its visual tokens and assets can be imported into the dashboard fork during the final UI integration phase.

A production deployment must provide both routes on one origin:

```text
/                                  LayerSentry production shell
/assets/*                          immutable LayerSentry assets
/v1/layersentry/ui/overview       authenticated read-only overview adapter
/dashboard/*                       existing management console
```

Do not use a cross-origin API, place tokens in JavaScript, or bypass the management console's authentication flow. The overview adapter must provide only the minimum read-only fields required by this contract and must not return Kubernetes secrets, plan secrets, kubeconfigs or raw credentials.

## Static serving

`nginx.conf` is a hardened reference configuration for the compiled `dist/` directory. It listens on unprivileged port `8080`, disables version disclosure, enforces security headers, serves immutable assets with long-lived caching and serves HTML/metadata with `no-store`.

TLS termination, HSTS, request authentication, RBAC, rate limiting and routing of the overview endpoint belong at the trusted cluster ingress/API gateway. Do not expose this reference server directly to an untrusted network.

## Acceptance gates

Code-level qualification requires all of the following:

1. `npm run validate` passes.
2. Node test suite passes.
3. Reproducible build completes and generates checksums.
4. No external browser dependency is present.
5. No upstream vendor name appears in the LayerSentry shell's user-visible HTML.
6. Security headers are confirmed on the deployed endpoint.
7. Keyboard-only and 320/768/1280/1920-pixel viewport checks pass.
8. Authentication-required, API unavailable, degraded, critical and offline states are exercised.
9. The overview endpoint is verified as read-only and RBAC-constrained.
10. Browser testing through the cluster VIP passes after `sen2` has rejoined and the cluster is stable.

Repository build success is not production release approval. Live deployment, cluster validation, browser acceptance, air-gap validation and release approval remain separate gates.
