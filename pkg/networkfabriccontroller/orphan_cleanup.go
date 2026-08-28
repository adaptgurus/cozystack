// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"fmt"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
)

const OrphanCleanupAuditPhase = "OrphanCleanupSkipped"

// OrphanedNodeCleanupAllowlist contains exact <fabric>/<node> operator-authorized
// targets. It is intentionally controller configuration, not part of the tenant
// NetworkFabric API.
type OrphanedNodeCleanupAllowlist map[string]struct{}

// ParseOrphanedNodeCleanupAllowlist parses a comma-separated exact target list.
// Wildcards are forbidden so an operator must acknowledge each orphaned node.
func ParseOrphanedNodeCleanupAllowlist(raw string) (OrphanedNodeCleanupAllowlist, error) {
	out := OrphanedNodeCleanupAllowlist{}
	if strings.TrimSpace(raw) == "" {
		return out, nil
	}
	for _, token := range strings.Split(raw, ",") {
		target := strings.TrimSpace(token)
		if target == "" {
			return nil, fmt.Errorf("orphaned-node cleanup allowlist contains an empty target")
		}
		if strings.ContainsAny(target, "*?[]") {
			return nil, fmt.Errorf("orphaned-node cleanup allowlist target %q must be exact; wildcards are forbidden", target)
		}
		if len(strings.Fields(target)) != 1 {
			return nil, fmt.Errorf("orphaned-node cleanup allowlist target %q contains whitespace", target)
		}
		parts := strings.Split(target, "/")
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			return nil, fmt.Errorf("orphaned-node cleanup allowlist target %q must use exact <fabric>/<node> form", target)
		}
		out[target] = struct{}{}
	}
	return out, nil
}

func (a OrphanedNodeCleanupAllowlist) Allows(fabricName, nodeName string) bool {
	if len(a) == 0 || fabricName == "" || nodeName == "" {
		return false
	}
	_, ok := a[fabricName+"/"+nodeName]
	return ok
}

func canSkipOrphanCleanup(reason string, getErr error, allowlist OrphanedNodeCleanupAllowlist, fabricName, nodeName string) bool {
	return reason == "Deleting" && apierrors.IsNotFound(getErr) && allowlist.Allows(fabricName, nodeName)
}
