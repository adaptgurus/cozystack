# LayerSentry production UI v3

This directory is the canonical production UI package. It supersedes the exploratory `ui-production-v2` package and consolidates the responsive layout, asset integrity, security, accessibility and deployment contracts into one qualified build path.

The package does not perform live cluster deployment. Live rollout remains blocked until the reimaged `sen2` node has rejoined and the three-node runtime gate is healthy.
