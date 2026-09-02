# LayerSentry operator UX specification

## Information architecture

The primary navigation is organized by operator intent:

1. **Overview** — aggregate health, capacity, alerts and recent events.
2. **Virtual machines** — VM inventory, creation, lifecycle and console access.
3. **Storage** — pools, volumes, images, snapshots, backups and capacity.
4. **Networks** — management and workload networks, VLANs, address pools and load balancers.
5. **Clusters** — LayerSentry node membership, Kubernetes clusters and platform services.
6. **Security** — users, roles, authentication, certificates, policies and audit events.
7. **Operations** — alerts, upgrades, support bundles, tasks and activity history.
8. **Settings** — platform, branding, integrations and license/open-source notices.

The initial release candidate implements the Overview shell and deep-links common tasks to the existing authenticated console. Native implementations of the remaining sections must reuse the same tokens, status language and error model.

## Global chrome

The application header contains:

- LayerSentry mark, wordmark and descriptor;
- current environment/tenant context;
- connection state;
- refresh action;
- theme control;
- authenticated user menu when the native management integration is added.

Do not place destructive actions, raw credentials, cluster tokens or kubeconfigs in global chrome.

## Overview

The overview page answers five questions in order:

1. Is the platform reachable?
2. Is the platform healthy enough for new work?
3. Which resource domain requires attention?
4. Which node or service is affected?
5. What is the next safe operator action?

Summary metrics display both the number and its denominator/context. Examples:

- `3 nodes — 3 of 3 Ready`;
- `12 virtual machines — 10 powered on`;
- `68% storage — 1.4 TiB of 2 TiB used`;
- `2 active alerts — 0 critical, 2 warning`.

A value without a verified response is an em dash, not zero. Zero means the backend positively reported zero.

## Health model

The aggregate UI states are:

- **Loading** — a request is active and no verified result is available.
- **Healthy** — all required domains report normal operation.
- **Degraded** — the platform is usable but one or more domains require attention.
- **Critical** — an essential service or capacity threshold requires immediate action.
- **Unknown** — the backend responded but could not determine aggregate health.
- **Unavailable** — the request failed and no verified result is cached.
- **Stale data** — a prior verified result is displayed after a later refresh failed.
- **Offline** — the browser reports no network connection.
- **Authentication required** — the backend rejects the session with 401 or 403.

Never silently convert unknown, unavailable or stale data to healthy.

## Forms and changes

All future change forms must use a review-before-commit model:

1. select or enter configuration;
2. validate syntax and dependencies without mutation;
3. show an impact summary;
4. require explicit confirmation for the actual write;
5. create a visible task with status and correlation ID;
6. preserve an audit trail and provide a safe retry path.

Destructive actions require:

- the exact resource name and scope;
- consequences and dependencies;
- whether the action is reversible;
- a typed confirmation for high-impact deletion;
- permission and policy checks before presenting the final action;
- no preselected destructive checkbox.

## Long-running operations

Installation, upgrade, migration, backup and recovery tasks use a persistent task model rather than a transient spinner. The task view must include:

- queued, running, waiting, succeeded, failed or cancelled state;
- start time, elapsed time and last update;
- current stage and completed stages;
- safe operator guidance;
- error code and correlation ID;
- logs or evidence with credential redaction;
- retry/rollback only when the backend declares the operation safe.

The UI must survive refresh, navigation and browser restart without losing the server-side task state.

## Tables and inventories

Inventory tables provide:

- server-side pagination for large datasets;
- stable sorting and filtering;
- column visibility preferences without hiding required health context;
- row selection that does not trigger an action by itself;
- explicit bulk-action impact summaries;
- empty, loading, error and permission-denied states;
- horizontal scrolling only inside the table container on narrow viewports.

Resource names are links. Status is text plus a semantic indicator. Machine identifiers and hashes use monospace and provide copy controls that do not expose secret fields.

## Authentication and authorization

The shell relies on the existing same-origin authenticated session. It does not implement its own credential form or token storage.

A forbidden operation is handled differently from an unavailable feature:

- permission denied: explain that the current identity lacks permission without disclosing hidden resource details;
- feature unavailable: explain the platform capability or prerequisite that is missing;
- session expired: route through the established sign-in flow and preserve only a safe return path.

UI visibility is not an authorization boundary. Every backend request must enforce authorization independently.

## Sensitive information

The following values are never rendered by the overview shell:

- `nodePassword`;
- `clusterToken`;
- Kubernetes Secret data;
- Rancher plan Secret data;
- kubeconfigs;
- private keys;
- bearer tokens;
- authentication cookies;
- raw cloud credentials.

Where a later administrative workflow must accept a secret, use a masked non-persistent input, never return the value after submission, and provide only a replacement workflow—not a reveal workflow.

## Notifications and errors

Notifications state:

- what happened;
- which resource was affected;
- whether the operation completed;
- what the operator should do next;
- a correlation ID when backend investigation may be required.

Do not use `Something went wrong` as the complete error. Do not expose stack traces, raw API responses or secret-bearing command lines to normal operators.

## Responsive behavior

At 1280 CSS pixels and above, use a persistent sidebar and multi-column status layout.

Between 768 and 1279 pixels, reduce card columns and stack detailed panels while preserving the navigation hierarchy.

Below 768 pixels, navigation becomes a horizontally scrollable labelled bar. Metrics, actions and panels stack. Tables remain within their own scroll container. The page itself must not horizontally overflow at 320 CSS pixels.

## Accessibility acceptance

Every release must verify:

- one logical page heading;
- landmarks and accessible names;
- keyboard focus order matching visual order;
- no keyboard trap;
- visible focus at all times;
- status changes announced politely unless urgent;
- labels not conveyed by colour alone;
- interactive targets approximately 42 CSS pixels or larger;
- no essential motion;
- usable reflow at 200 percent zoom;
- meaningful alt text or intentionally empty alt text for decorative assets.

## Performance budgets

The initial shell budgets are:

- HTML: 40 KiB;
- CSS: 50 KiB after canonical responsive correction;
- JavaScript: 52 KiB;
- product mark: 8 KiB;
- favicon: 4 KiB;
- no third-party JavaScript;
- no public web fonts;
- no source maps in the release artifact;
- overview response no larger than 1 MiB, 64 nodes and eight events.

Performance claims must be measured at the cluster VIP under the intended air-gap network conditions.
