# LayerSentry UI production-readiness plan

## Current release-candidate scope

The release candidate provides a LayerSentry-branded operator shell for compute, storage, network and cluster status. It is an additive management experience and does not replace the authenticated management console until browser, RBAC and operational acceptance gates pass.

The current build performs no cluster mutation. It is safe to qualify while `sen2` is being reimaged because all work is confined to repository source, tests and static release artifacts.

## User experience baseline

The shell includes:

- LayerSentry product mark, favicon, typography, colour tokens and terminology;
- dark and light themes, with only the non-sensitive theme choice persisted locally;
- desktop, tablet and mobile layouts down to 320 CSS pixels;
- keyboard skip navigation, semantic landmarks, visible focus, live regions, reduced-motion and increased-contrast support;
- explicit loading, healthy, degraded, critical, offline, authentication-required, timeout, invalid-response and API-unavailable states;
- summary cards for nodes, virtual machines, storage and alerts;
- cluster-node health, quick actions and recent events;
- safe stale-data behaviour when a later refresh fails.

## Security model

The browser uses the existing same-origin authenticated session. The UI does not create bearer tokens, store credentials, read kubeconfigs, or access the protected bootstrap-credential file.

The overview API is read-only and must return only the aggregate fields defined in `api/overview.schema.json`. It must never return:

- Kubernetes Secret objects or Secret data;
- Rancher plan Secret payloads;
- bootstrap passwords or cluster tokens;
- kubeconfigs, service-account tokens or client certificates;
- SSH private keys or host credentials;
- raw manifests containing credentials;
- write-capable URLs or impersonation headers.

The static server enforces CSP, clickjacking protection, no-referrer, MIME sniffing protection, a restrictive permissions policy, same-origin resource isolation, immutable caching for versioned assets and no-store for HTML and metadata.

## Build and provenance

The canonical assembler is `ui-production-v3`. It selects only reviewed and referenced source assets from `ui-production-v2`, merges the mobile navigation correction into the canonical stylesheet, and generates:

- an exact release file set;
- SHA-256 checksums;
- SHA-384 Subresource Integrity values;
- release metadata bound to the Git commit;
- an SPDX 2.3 file-level software bill of materials;
- a deterministic tar archive in CI.

No npm package installation or public network access is required to validate, test or assemble the UI.

## Container and Kubernetes controls

`Containerfile` intentionally has no default base image. A release pipeline must provide a security-approved base image by immutable digest. Mutable tags are not accepted for production qualification.

The Kubernetes template provides:

- two replicas with zero-unavailable rolling updates;
- a PodDisruptionBudget;
- anti-affinity and topology spreading;
- non-root execution on port 8080;
- read-only root filesystem;
- RuntimeDefault seccomp;
- all Linux capabilities dropped;
- privilege escalation disabled;
- bounded CPU, memory and temporary storage;
- startup, readiness and liveness probes;
- disabled service-account-token mounting;
- restricted Pod Security labels;
- default-deny egress and ingress limited to an explicitly labelled ingress namespace.

The deployment contains a deliberately invalid image digest. CI or a release operator must substitute the verified image digest after image build and vulnerability policy gates pass. This prevents accidental deployment from source control.

## Required same-origin routes

The trusted ingress/API gateway must expose these routes on one origin:

```text
/                                  LayerSentry production shell
/assets/*                          immutable LayerSentry assets
/v1/layersentry/ui/overview       authenticated read-only overview adapter
/dashboard/*                       existing authenticated management console
```

The static UI pod does not proxy credentials or call the Kubernetes API. The trusted gateway or existing management backend must authenticate the request and enforce RBAC before serving the overview response.

## Promotion gates

### Gate 1 — repository qualification

- source validation passes;
- Node contract tests pass;
- canonical release verification passes;
- every release checksum validates;
- SBOM and release metadata validate;
- no external browser dependency, secret indicator, source map, private key or kubeconfig is present.

### Gate 2 — image qualification

- approved digest-pinned base image;
- reproducible container build;
- image signature and provenance recorded;
- critical/high vulnerability policy passed or formally excepted;
- runs as UID/GID 101 with a read-only root filesystem;
- `/healthz` works under the Kubernetes security context.

### Gate 3 — cluster prerequisite

- `sen1`, `sen2` and `sen3` Ready;
- `sen2` worker-only identity and plan checks pass;
- RKE2/system-agent health passes;
- cluster VIP `10.10.10.10` is stable;
- storage, KubeVirt and network health pass;
- no pending destructive recovery operation.

### Gate 4 — controlled lab rollout

- deploy to `layersentry-system` using the verified image digest;
- configure same-origin ingress routing without bypassing authentication;
- enforce read-only RBAC for the overview adapter;
- verify CSP and all security headers at the VIP;
- verify no secrets appear in responses, browser storage, logs or artifacts;
- exercise healthy, degraded, critical, offline, timeout and authentication-required states.

### Gate 5 — browser and accessibility acceptance

- Chromium, Edge and Firefox current enterprise channels;
- 320, 768, 1280 and 1920 CSS-pixel viewports;
- keyboard-only task completion;
- 200% zoom and text reflow;
- reduced-motion and increased-contrast preferences;
- screen-reader landmarks, names, states and status announcements;
- no horizontal page overflow outside intentionally scrollable tables;
- no upstream vendor identity visible in the LayerSentry shell.

### Gate 6 — operational acceptance

- rolling update with one replica unavailable;
- node drain/PDB behaviour;
- ingress and API failure handling;
- stale-data indication after refresh failure;
- structured access logs without credential material;
- resource usage and restart behaviour under sustained refresh traffic;
- air-gap deployment from the qualified release bundle only.

### Gate 7 — release approval

Repository qualification, image qualification and a successful lab rollout do not independently constitute production approval. Final release requires recorded browser evidence, security review, operational sign-off and an explicit release decision.
