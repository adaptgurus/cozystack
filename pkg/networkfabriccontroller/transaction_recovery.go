// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"fmt"
	"time"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func (r *Reconciler) talosTryTimeout() time.Duration {
	if r.TryTimeout <= 0 {
		return 2 * time.Minute
	}
	return r.TryTimeout
}

// transactionObserver persists only non-secret recovery checkpoints. Talos
// credentials, forward patch bytes, inverse patch bytes and the full
// MachineConfig remain process-local and never enter Kubernetes status.
func (r *Reconciler) transactionObserver(
	ctx context.Context,
	fabric *unstructured.Unstructured,
	statuses map[string]NodeStatus,
	node string,
	desired []networkfabric.Network,
) networkfabric.TransactionObserver {
	return func(stage networkfabric.TransactionStage, receipt networkfabric.ApplyReceipt) error {
		st := statuses[node]
		st.Name = node
		st.Phase = "Reconciling"
		st.TransactionPhase = string(stage)
		st.TransactionRevision = receipt.Revision
		st.TransactionNetworks = cloneNetworks(desired)
		if stage == networkfabric.TransactionTryApplied || st.TransactionDeadline == "" {
			st.TransactionDeadline = time.Now().UTC().Add(r.talosTryTimeout()).Format(time.RFC3339Nano)
		}
		st.Message = fmt.Sprintf("Talos TRY transaction checkpoint persisted: %s", stage)
		statuses[node] = st
		return r.writeStatus(
			ctx,
			fabric,
			"Reconciling",
			node,
			statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TalosTransaction"+string(stage), fmt.Sprintf("node %s Talos transaction is at durable stage %s", node, stage)),
			nil,
		)
	}
}

// recoverPendingTransaction handles controller death after Talos accepted TRY
// but before the normal Ready status was committed. It deliberately waits until
// after the persisted TRY deadline before classifying live state; before that
// deadline desired topology may merely be the unconfirmed TRY configuration.
func (r *Reconciler) recoverPendingTransaction(
	ctx context.Context,
	fabric *unstructured.Unstructured,
	spec networkfabric.Spec,
	statuses map[string]NodeStatus,
) (ctrl.Result, bool, error) {
	pending := make([]string, 0, 1)
	for _, name := range sortedStatusNames(statuses) {
		if statuses[name].TransactionPhase != "" {
			pending = append(pending, name)
		}
	}
	if len(pending) == 0 {
		return ctrl.Result{}, false, nil
	}
	if len(pending) > 1 {
		err := r.writeStatus(ctx, fabric, "Degraded", "", statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "MultiplePendingTransactions", "more than one durable Talos TRY checkpoint exists; refusing further node mutation"), nil)
		return ctrl.Result{RequeueAfter: r.requeue()}, true, err
	}

	nodeName := pending[0]
	st := statuses[nodeName]
	if st.TransactionPhase != string(networkfabric.TransactionTryApplied) && st.TransactionPhase != string(networkfabric.TransactionVerified) {
		st.Phase = "Failed"
		st.Message = "unknown durable Talos transaction stage; refusing further node mutation"
		statuses[nodeName] = st
		err := r.writeStatus(ctx, fabric, "Degraded", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "UnknownTransactionStage", st.Message), nil)
		return ctrl.Result{RequeueAfter: r.requeue()}, true, err
	}

	deadline, err := time.Parse(time.RFC3339Nano, st.TransactionDeadline)
	if err != nil {
		// A missing/corrupt deadline must not trigger an immediate guess. Persist a
		// fresh conservative wait window and classify only after it expires.
		st.TransactionDeadline = time.Now().UTC().Add(r.talosTryTimeout()).Format(time.RFC3339Nano)
		st.Phase = "Reconciling"
		st.Message = "repaired missing Talos TRY recovery deadline; waiting before live-state classification"
		statuses[nodeName] = st
		if writeErr := r.writeStatus(ctx, fabric, "Reconciling", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionDeadlineRepaired", st.Message), nil); writeErr != nil {
			return ctrl.Result{}, true, writeErr
		}
		return ctrl.Result{RequeueAfter: r.talosTryTimeout()}, true, nil
	}
	if wait := time.Until(deadline); wait > 0 {
		return ctrl.Result{RequeueAfter: wait + time.Second}, true, nil
	}

	if r.AdapterFactory == nil {
		return ctrl.Result{}, true, fmt.Errorf("NetworkFabric adapter factory is not configured")
	}
	node := &corev1.Node{}
	if err := r.Get(ctx, client.ObjectKey{Name: nodeName}, node); err != nil {
		st.Phase = "Failed"
		st.Message = fmt.Sprintf("cannot recover pending Talos transaction because Kubernetes Node %s is unavailable", nodeName)
		statuses[nodeName] = st
		writeErr := r.writeStatus(ctx, fabric, "Degraded", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveryNodeUnavailable", st.Message), nil)
		return ctrl.Result{RequeueAfter: r.requeue()}, true, writeErr
	}
	adapter, err := r.AdapterFactory(node)
	if err != nil {
		st.Phase = "Failed"
		st.Message = "cannot construct Talos client while recovering pending transaction"
		statuses[nodeName] = st
		writeErr := r.writeStatus(ctx, fabric, "Degraded", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveryAdapterError", st.Message), nil)
		return ctrl.Result{RequeueAfter: r.requeue()}, true, writeErr
	}
	state, err := adapter.Inspect(ctx, nodeName)
	if err != nil {
		st.Phase = "Failed"
		st.Message = "Talos API is unreachable while recovering pending transaction"
		statuses[nodeName] = st
		writeErr := r.writeStatus(ctx, fabric, "Degraded", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveryInspectFailed", st.Message), nil)
		return ctrl.Result{RequeueAfter: r.requeue()}, true, writeErr
	}
	if err := adapter.VerifyManagement(ctx, nodeName, spec.ProtectedManagementInterfaces); err != nil {
		st.Phase = "Failed"
		st.ManagementReachable = false
		st.Message = "management verification failed while recovering pending Talos transaction"
		statuses[nodeName] = st
		writeErr := r.writeStatus(ctx, fabric, "Degraded", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveryManagementFailed", st.Message), nil)
		return ctrl.Result{RequeueAfter: r.requeue()}, true, writeErr
	}

	previous := cloneNetworks(st.AppliedNetworks)
	desired := cloneNetworks(st.TransactionNetworks)
	desiredErr := networkfabric.ValidateTransitionTopology(state, previous, desired)
	revertedErr := networkfabric.ValidateTransitionTopology(state, desired, previous)

	now := time.Now().UTC().Format(time.RFC3339Nano)
	switch {
	case desiredErr == nil:
		st.Phase = "Ready"
		if len(desired) == 0 {
			// Cleanup transactions are removed by the normal selector/finalizer path
			// on the next reconcile; avoid Ready fallback ownership inference.
			st.Phase = "Recovered"
		}
		st.ObservedGeneration = fabric.GetGeneration()
		st.LastAppliedRevision = st.TransactionRevision
		st.ManagementReachable = true
		st.Message = "recovered a Talos transaction that remained at desired topology after the TRY deadline"
		st.AppliedNetworks = desired
		st.LastVerifiedAt = now
		st.RollbackState = "NotRequired"
		clearTransactionCheckpoint(&st)
		statuses[nodeName] = st
		if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveredConfirmed", fmt.Sprintf("node %s confirmed topology recovered after controller restart", nodeName)), nil); err != nil {
			return ctrl.Result{}, true, err
		}
		return ctrl.Result{Requeue: true}, true, nil

	case revertedErr == nil:
		st.Phase = "Ready"
		st.ManagementReachable = true
		st.Message = "Talos TRY auto-reverted to the previously owned topology after controller restart"
		st.AppliedNetworks = previous
		st.LastVerifiedAt = now
		st.RollbackState = "AutoReverted"
		clearTransactionCheckpoint(&st)
		statuses[nodeName] = st
		if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveredReverted", fmt.Sprintf("node %s auto-reverted; reconciliation will safely retry", nodeName)), nil); err != nil {
			return ctrl.Result{}, true, err
		}
		return ctrl.Result{Requeue: true}, true, nil

	default:
		// Keep the checkpoint deliberately. This prevents the normal reconciler
		// from mutating an ambiguous node until live topology resolves to either
		// the exact previous or exact intended state.
		st.Phase = "Failed"
		st.ManagementReachable = true
		st.Message = "post-deadline Talos topology matches neither the intended nor previous owned state; manual investigation required before further mutation"
		statuses[nodeName] = st
		if err := r.writeStatus(ctx, fabric, "Degraded", nodeName, statuses,
			condition(fabric, "Ready", metav1.ConditionFalse, "TransactionRecoveryAmbiguous", st.Message), nil); err != nil {
			return ctrl.Result{}, true, err
		}
		return ctrl.Result{RequeueAfter: r.requeue()}, true, nil
	}
}

func clearTransactionCheckpoint(st *NodeStatus) {
	st.TransactionPhase = ""
	st.TransactionRevision = ""
	st.TransactionDeadline = ""
	st.TransactionNetworks = nil
}
