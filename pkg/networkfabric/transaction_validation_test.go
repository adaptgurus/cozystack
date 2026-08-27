// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestOrchestratorRollsBackTopologyFailureBeforeConfirm(t *testing.T) {
	adapter := &fakeTalosAdapter{state: validState()}
	_, err := (Orchestrator{Adapter: adapter}).ReconcileNodeTransitionValidated(
		context.Background(),
		validSpec(),
		nil,
		"node-1",
		func(NodeState) error { return errors.New("bridge member is wrong") },
	)
	if err == nil || !strings.Contains(err.Error(), "topology validation failed") || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("expected topology rollback, got %v", err)
	}
	if !adapter.applied || !adapter.verified || adapter.confirmed || !adapter.rolledBack {
		t.Fatalf("transaction calls: applied=%v verified=%v confirmed=%v rolledBack=%v", adapter.applied, adapter.verified, adapter.confirmed, adapter.rolledBack)
	}
}
