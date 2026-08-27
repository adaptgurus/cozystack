// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"context"
	"fmt"
)

// TransactionStage is a non-secret durability checkpoint for a Talos TRY
// transaction. It deliberately does not contain Talos credentials or a full
// machine configuration.
type TransactionStage string

const (
	TransactionTryApplied TransactionStage = "TryApplied"
	TransactionVerified   TransactionStage = "Verified"
)

// TransactionObserver persists controller transaction checkpoints. If a
// checkpoint cannot be persisted, the orchestrator rolls back rather than
// continuing with a transaction whose restart state would be ambiguous.
type TransactionObserver func(stage TransactionStage, receipt ApplyReceipt) error

// ReconcileNodeTransitionObserved is the restart-safe variant used by the
// NetworkFabric controller. The observer is called immediately after Talos
// accepts the TRY configuration and again after management/topology
// verification, but before Confirm. A controller restart can therefore wait
// for the TRY deadline and determine whether Talos reverted or Confirm had
// completed, without assuming the in-memory receipt survived.
func (o Orchestrator) ReconcileNodeTransitionObserved(
	ctx context.Context,
	spec Spec,
	previous []Network,
	node string,
	validate func(NodeState) error,
	observe TransactionObserver,
) (ApplyReceipt, error) {
	if o.Adapter == nil {
		return ApplyReceipt{}, fmt.Errorf("Talos adapter is required")
	}
	state, err := o.Adapter.Inspect(ctx, node)
	if err != nil {
		return ApplyReceipt{}, fmt.Errorf("inspect Talos node %q: %w", node, err)
	}
	plan, err := PlanForTransition(spec, previous, state)
	if err != nil {
		return ApplyReceipt{}, err
	}
	receipt, err := o.Adapter.Apply(ctx, node, plan.Operations, plan.RollbackOperations)
	if err != nil {
		return ApplyReceipt{}, fmt.Errorf("apply Talos network plan to node %q: %w", node, err)
	}
	if receipt.Revision == "" {
		return ApplyReceipt{}, fmt.Errorf("Talos adapter returned an empty transaction revision for node %q", node)
	}
	if observe != nil {
		if err := observe(TransactionTryApplied, receipt); err != nil {
			return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "persist TRY transaction checkpoint failed", err)
		}
	}
	if err := o.Adapter.VerifyManagement(ctx, node, spec.ProtectedManagementInterfaces); err != nil {
		return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "management verification failed", err)
	}
	if validate != nil {
		postState, inspectErr := o.Adapter.Inspect(ctx, node)
		if inspectErr != nil {
			return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "post-apply inspection failed", inspectErr)
		}
		if err := validate(postState); err != nil {
			return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "post-apply topology validation failed", err)
		}
	}
	if observe != nil {
		if err := observe(TransactionVerified, receipt); err != nil {
			return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "persist verified transaction checkpoint failed", err)
		}
	}
	if err := o.Adapter.Confirm(ctx, node, receipt); err != nil {
		return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "failed to confirm network configuration", err)
	}
	return receipt, nil
}
