# LayerSentry product identity

## Positioning

**LayerSentry** is the operator-facing identity. The descriptor is **Private Cloud Platform**. The interface should communicate control, resilience and infrastructure clarity rather than consumer-cloud styling.

User-visible product chrome must use LayerSentry terminology. Upstream project names may appear only where they identify a technical object, compatibility boundary, legal attribution or troubleshooting source that cannot be renamed without reducing accuracy.

## Mark

The primary mark is a layered shield:

- the outer shield communicates platform protection and operational trust;
- the stacked core communicates compute, storage and network layers;
- cyan-to-blue progression provides differentiation on both dark and light surfaces.

Use the supplied SVG. Do not redraw it with a third-party shield icon, distort its aspect ratio, rotate it, apply unapproved colours, place text inside it or combine it with an upstream vendor mark.

Minimum digital size is 24 by 24 CSS pixels. Preferred application-header size is 40 by 40 CSS pixels. Clear space around the mark should be at least one quarter of the rendered mark width.

## Wordmark and descriptor

Write the product as `LayerSentry`, preserving the capital `L` and `S`. Do not use `Layer Sentry`, `Layersentry`, `LAYERSENTRY` in running text, or abbreviate it to `LS` in user-facing navigation.

The descriptor `Private Cloud Platform` may appear beneath the wordmark in product chrome. It should not compete with the product name.

## Colour

The primary accent is cyan-blue. It is reserved for:

- primary actions;
- active navigation;
- links and focus indicators;
- selected controls;
- informational highlights.

Operational status colours are semantic and must never be the sole means of communication:

- success: healthy, ready, completed;
- warning: degraded, attention required, capacity watch;
- danger: critical, failed, unavailable;
- information: neutral operational notice.

Every status must include text, an icon, shape or position in addition to colour.

## Typography

Use the system font stack defined in `tokens.json`. The UI must not download public web fonts. This avoids an air-gap dependency and prevents layout shifts when external services are unavailable.

Headings are concise, sentence case and task-oriented. Body copy uses plain operational language. Monospace is reserved for addresses, identifiers, commands, hashes and machine-readable values.

## Voice and terminology

Use direct operator language:

- `Virtual machines`, not `instances` unless the underlying API specifically uses that term;
- `Nodes`, not `hosts`, when referring to Kubernetes/LayerSentry membership;
- `Networks`, with the exact network type disclosed in detail views;
- `Storage`, with pool, volume and capacity terms distinguished;
- `Ready`, `Degraded`, `Critical`, `Unavailable` and `Unknown` as standard health labels.

Avoid claims such as `secure`, `protected`, `healthy` or `production-ready` unless the corresponding gate has been measured. Prefer `No critical alerts reported` over `Everything is secure`.

## Accessibility

The visual identity must remain usable with:

- keyboard-only navigation;
- 200 percent zoom;
- reduced-motion preference;
- increased-contrast preference;
- common colour-vision deficiencies;
- screen-reader landmarks and accessible names.

Focus indication uses a minimum three-pixel outline and must not be removed. Text and essential graphical controls should meet WCAG AA contrast. Small muted text must not carry critical information.

## Theming

Dark theme is the default for infrastructure operations; light theme is fully supported. Both themes use the same semantic hierarchy and status meanings. Only the theme preference may be persisted in browser local storage. Theme state must never be coupled to credentials, tenant identity or authorization state.

## Co-branding and attribution

LayerSentry product chrome must not present an upstream logo as the primary identity. Required open-source notices and technical attribution belong in an About, Licenses or Support view. They must remain accurate and must not imply ownership of upstream trademarks.
