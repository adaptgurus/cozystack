// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"errors"
	"testing"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestParseOrphanedNodeCleanupAllowlist(t *testing.T) {
	allowlist, err := ParseOrphanedNodeCleanupAllowlist("fabric-a/node-1, fabric-b/node-2")
	if err != nil {
		t.Fatalf("parse allowlist: %v", err)
	}
	if !allowlist.Allows("fabric-a", "node-1") || !allowlist.Allows("fabric-b", "node-2") {
		t.Fatalf("expected exact allowlist entries to match: %#v", allowlist)
	}
	if allowlist.Allows("fabric-a", "node-2") || allowlist.Allows("fabric-c", "node-1") {
		t.Fatal("allowlist must require exact fabric/node pair")
	}
}

func TestParseOrphanedNodeCleanupAllowlistRejectsUnsafeTargets(t *testing.T) {
	for _, raw := range []string{
		"fabric-a/*",
		"*/node-1",
		"fabric-a/node-?",
		"fabric-a/node-1,",
		"fabric-a",
		"fabric-a/node-1/extra",
		"fabric a/node-1",
	} {
		t.Run(raw, func(t *testing.T) {
			if _, err := ParseOrphanedNodeCleanupAllowlist(raw); err == nil {
				t.Fatalf("expected %q to be rejected", raw)
			}
		})
	}
}

func TestCanSkipOrphanCleanupRequiresDeletingNotFoundAndExactAuthorization(t *testing.T) {
	allowlist := OrphanedNodeCleanupAllowlist{"fabric-a/node-1": {}}
	notFound := apierrors.NewNotFound(schema.GroupResource{Resource: "nodes"}, "node-1")

	if !canSkipOrphanCleanup("Deleting", notFound, allowlist, "fabric-a", "node-1") {
		t.Fatal("expected exact operator authorization plus Node NotFound during deletion to permit audited skip")
	}
	if canSkipOrphanCleanup("NodeSelectorChanged", notFound, allowlist, "fabric-a", "node-1") {
		t.Fatal("selector-change cleanup must never use orphan bypass")
	}
	if canSkipOrphanCleanup("Deleting", notFound, allowlist, "fabric-a", "node-2") {
		t.Fatal("different node must not inherit authorization")
	}
	if canSkipOrphanCleanup("Deleting", notFound, allowlist, "fabric-b", "node-1") {
		t.Fatal("different fabric must not inherit authorization")
	}
	if canSkipOrphanCleanup("Deleting", errors.New("Talos API unreachable"), allowlist, "fabric-a", "node-1") {
		t.Fatal("live/unreachable or ambiguous failures must remain fail-closed")
	}
	if canSkipOrphanCleanup("Deleting", nil, allowlist, "fabric-a", "node-1") {
		t.Fatal("an existing Kubernetes Node must never be bypassed")
	}
}
