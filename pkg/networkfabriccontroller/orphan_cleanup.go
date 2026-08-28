// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"fmt"
	"strings"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
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

// OrphanRecoveryReconciler is an operator-only deletion escape hatch for the
// single case where Kubernetes has conclusively removed a previously managed
// Node, making Talos cleanup impossible. All ordinary reconciliation is
// delegated unchanged to Inner, including live-node Talos failures, ownership
// guards, transaction recovery, selector cleanup, and reference protection.
type OrphanRecoveryReconciler struct {
	Base      *Reconciler
	Inner     reconcile.Reconciler
	Allowlist OrphanedNodeCleanupAllowlist
}

func (r *OrphanRecoveryReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if r.Base == nil || r.Inner == nil {
		return ctrl.Result{}, fmt.Errorf("NetworkFabric orphan recovery reconciler is not fully configured")
	}

	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(NetworkFabricGVK)
	if err := r.Base.Get(ctx, req.NamespacedName, fabric); err != nil {
		return r.Inner.Reconcile(ctx, req)
	}
	if fabric.GetDeletionTimestamp().IsZero() || !controllerutil.ContainsFinalizer(fabric, NetworkFabricFinalizer) {
		return r.Inner.Reconcile(ctx, req)
	}

	spec, err := ParseSpec(fabric)
	if err != nil {
		return r.Inner.Reconcile(ctx, req)
	}
	if err := networkfabric.Validate(spec); err != nil {
		return r.Inner.Reconcile(ctx, req)
	}

	statuses := readNodeStatuses(fabric)
	for _, st := range statuses {
		// Never bypass transaction recovery. The base reconciler must first
		// resolve or classify every persisted Talos TRY checkpoint.
		if st.TransactionPhase != "" {
			return r.Inner.Reconcile(ctx, req)
		}
	}

	// VMNetwork references are authoritative hard blockers, including during
	// operator-authorized orphan recovery.
	references, err := r.Base.referencingVMNetworks(ctx, fabric.GetName())
	if err != nil || len(references) > 0 {
		return r.Inner.Reconcile(ctx, req)
	}

	for _, nodeName := range sortedStatusNames(statuses) {
		st := statuses[nodeName]
		if st.Phase == OrphanCleanupAuditPhase {
			continue
		}
		previous := ownedNetworks(st, spec, fabric.GetGeneration())
		if len(previous) == 0 {
			// Let the base controller discard non-owned historical status.
			return r.Inner.Reconcile(ctx, req)
		}

		node := &corev1.Node{}
		getErr := r.Base.Get(ctx, client.ObjectKey{Name: nodeName}, node)
		if !canSkipOrphanCleanup("Deleting", getErr, r.Allowlist, fabric.GetName(), nodeName) {
			// This includes a live node, forbidden/unexpected API failures, and
			// NotFound nodes that have not been explicitly allowlisted. The base
			// reconciler remains fail-closed in every such case.
			return r.Inner.Reconcile(ctx, req)
		}

		message := fmt.Sprintf("operator-authorized orphan cleanup skip for node %s: Kubernetes Node is NotFound, so controller-owned Talos VLAN/bridge cleanup cannot be executed", nodeName)
		rollbackState := st.RollbackState
		if rollbackState == "" {
			rollbackState = "Unknown"
		}
		statuses[nodeName] = NodeStatus{
			Name:                nodeName,
			Phase:               OrphanCleanupAuditPhase,
			ObservedGeneration:  fabric.GetGeneration(),
			LastAppliedRevision: st.LastAppliedRevision,
			ManagementReachable: false,
			Message:             message,
			AppliedNetworks:     nil,
			LastVerifiedAt:      st.LastVerifiedAt,
			RollbackState:       rollbackState,
		}
		ctrl.LoggerFrom(ctx).Info("operator-authorized NetworkFabric orphan cleanup skip", "fabric", fabric.GetName(), "node", nodeName)
		if err := r.Base.writeStatus(ctx, fabric, "Degraded", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "OrphanedNodeCleanupSkipped", message), nil); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil
	}

	if len(statuses) == 0 {
		return r.Inner.Reconcile(ctx, req)
	}

	// Every remaining status is now an audit record for an explicitly
	// authorized, definitively deleted Kubernetes Node. Re-check VMNetwork
	// references immediately before finalizer removal to close the create/delete
	// race and preserve reference protection as a hard gate.
	references, err = r.Base.referencingVMNetworks(ctx, fabric.GetName())
	if err != nil {
		message := fmt.Sprintf("cannot remove NetworkFabric finalizer after orphan recovery: %v", err)
		if statusErr := r.Base.writeStatus(ctx, fabric, "Degraded", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "ReferenceLookupFailed", message), nil); statusErr != nil {
			return ctrl.Result{}, statusErr
		}
		return ctrl.Result{RequeueAfter: r.Base.requeue()}, nil
	}
	if len(references) > 0 {
		message := formatReferences("cannot remove NetworkFabric finalizer after orphan recovery while VMNetwork references exist", references)
		if statusErr := r.Base.writeStatus(ctx, fabric, "Degraded", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "FabricInUse", message), nil); statusErr != nil {
			return ctrl.Result{}, statusErr
		}
		return ctrl.Result{RequeueAfter: r.Base.requeue()}, nil
	}

	base := fabric.DeepCopy()
	controllerutil.RemoveFinalizer(fabric, NetworkFabricFinalizer)
	if err := r.Base.Patch(ctx, fabric, client.MergeFrom(base)); err != nil {
		return ctrl.Result{}, err
	}
	ctrl.LoggerFrom(ctx).Info("removed NetworkFabric finalizer after audited orphan recovery", "fabric", fabric.GetName())
	return ctrl.Result{}, nil
}
