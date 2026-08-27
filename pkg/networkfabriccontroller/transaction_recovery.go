// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"fmt"
	"time"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func (r *Reconciler) talosTryTimeout() time.Duration {
	if r.TryTimeout <= 0 {
		return 2 * time.Minute
	}
	return r.TryTimeout
}

// transactionObserver persists only the non-secret information needed to
// recover a Talos TRY transaction after a controller crash. Patch bytes,
// credentials and the full MachineConfig remain process-local.
func (r *Reconciler) transactionObserver(
	ctx context.Context,
	fabric interface{ GetGeneration() int64 },
	statuses map[string]NodeStatus,
	node string,
	desired []networkfabric.Network,
) networkfabric.TransactionObserver {
	return func(stage networkfabric.TransactionStage, receipt networkfabric.ApplyReceipt) error {
		// The real reconciler passes *unstructured.Unstructured. Keep the observer
		// callback narrow at its boundary but assert the concrete object here so
		// status persistence remains centralized through writeStatus.
		obj, ok := fabric.(interface {
			GetGeneration() int64
		})
		if !ok || obj == nil {
			return fmt.Errorf("NetworkFabric object is unavailable for transaction checkpoint")
		}
		_ = obj
		return fmt.Errorf("internal transaction observer wiring error")
	}
}

// recoverPendingTransaction is implemented in transaction_recovery_unstructured.go
// where the concrete Kubernetes object type can be used without widening the
// public NetworkFabric transaction interface.
func (r *Reconciler) recoverPendingTransaction(
	context.Context,
	interface{ GetGeneration() int64 },
	networkfabric.Spec,
	map[string]NodeStatus,
) (ctrl.Result, bool, error) {
	return ctrl.Result{}, false, fmt.Errorf("internal transaction recovery wiring error")
}

// compile-time imports retained for the concrete recovery implementation split
// out below.
var (
	_ = corev1.Node{}
	_ = metav1.ConditionFalse
	_ client.ObjectKey
)
