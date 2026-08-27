// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	networkFabricReconcileTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "cozystack_networkfabric_reconcile_total",
		Help: "Total NetworkFabric reconciliation attempts by result.",
	}, []string{"fabric", "result"})
	networkFabricReconcileDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "cozystack_networkfabric_reconcile_duration_seconds",
		Help:    "NetworkFabric reconciliation duration in seconds.",
		Buckets: prometheus.DefBuckets,
	}, []string{"fabric"})
	networkFabricFailureTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "cozystack_networkfabric_failure_total",
		Help: "Total reconciliations that leave a NetworkFabric Failed or Degraded, by status reason.",
	}, []string{"fabric", "reason"})
	networkFabricStatus = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_status",
		Help: "Current NetworkFabric phase as a one-hot gauge.",
	}, []string{"fabric", "phase"})
	networkFabricNodes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_nodes",
		Help: "Number of NetworkFabric nodes by reconciliation phase.",
	}, []string{"fabric", "phase"})
	networkFabricUnreachableNodes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_management_unreachable_nodes",
		Help: "Number of NetworkFabric nodes whose Talos management path is not reachable.",
	}, []string{"fabric"})
	networkFabricStaleNodes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_stale_nodes",
		Help: "Number of NetworkFabric nodes whose observedGeneration differs from the current object generation.",
	}, []string{"fabric"})
	networkFabricRollbackNodes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_rollback_nodes",
		Help: "Number of NetworkFabric nodes by latest rollback state.",
	}, []string{"fabric", "state"})
	networkFabricMigrationReady = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_migration_ready",
		Help: "Whether the configured NetworkFabric migration topology is ready on all selected nodes (1 ready, 0 not ready/not configured).",
	}, []string{"fabric"})
	networkFabricMigrationUnavailableNodes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_migration_unavailable_nodes",
		Help: "Number of nodes unavailable for the configured NetworkFabric migration topology.",
	}, []string{"fabric"})
	networkFabricObservedGeneration = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cozystack_networkfabric_observed_generation",
		Help: "Latest NetworkFabric generation represented by persisted controller status.",
	}, []string{"fabric"})
)

var fabricPhases = []string{"Ready", "Reconciling", "Degraded", "Failed"}
var nodePhases = []string{"Ready", "Reconciling", "Failed"}
var rollbackStates = []string{"NotRequired", "Unknown", "RolledBack", "RollbackFailed"}

func init() {
	metrics.Registry.MustRegister(
		networkFabricReconcileTotal,
		networkFabricReconcileDuration,
		networkFabricFailureTotal,
		networkFabricStatus,
		networkFabricNodes,
		networkFabricUnreachableNodes,
		networkFabricStaleNodes,
		networkFabricRollbackNodes,
		networkFabricMigrationReady,
		networkFabricMigrationUnavailableNodes,
		networkFabricObservedGeneration,
	)
}

// InstrumentedReconciler adds NetworkFabric-specific telemetry without changing
// the transactional Talos reconciliation semantics implemented by Reconciler.
type InstrumentedReconciler struct {
	Inner *Reconciler
}

func NewInstrumentedReconciler(inner *Reconciler) *InstrumentedReconciler {
	return &InstrumentedReconciler{Inner: inner}
}

func (r *InstrumentedReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	started := time.Now()
	result, reconcileErr := r.Inner.Reconcile(ctx, req)
	fabricName := req.Name
	outcome := "success"
	if reconcileErr != nil {
		outcome = "error"
	}
	networkFabricReconcileTotal.WithLabelValues(fabricName, outcome).Inc()
	networkFabricReconcileDuration.WithLabelValues(fabricName).Observe(time.Since(started).Seconds())

	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(NetworkFabricGVK)
	if err := r.Inner.Get(ctx, req.NamespacedName, fabric); err != nil {
		if apierrors.IsNotFound(err) {
			deleteNetworkFabricMetrics(fabricName)
		}
		return result, reconcileErr
	}
	recordNetworkFabricMetrics(fabric)
	if phase, _, _ := unstructured.NestedString(fabric.Object, "status", "phase"); phase == "Failed" || phase == "Degraded" {
		networkFabricFailureTotal.WithLabelValues(fabricName, readyConditionReason(fabric)).Inc()
	}
	return result, reconcileErr
}

func recordNetworkFabricMetrics(fabric *unstructured.Unstructured) {
	name := fabric.GetName()
	phase, _, _ := unstructured.NestedString(fabric.Object, "status", "phase")
	for _, candidate := range fabricPhases {
		value := 0.0
		if phase == candidate {
			value = 1
		}
		networkFabricStatus.WithLabelValues(name, candidate).Set(value)
	}

	counts := map[string]float64{}
	rollbacks := map[string]float64{}
	unreachable := 0.0
	stale := 0.0
	nodes, _, _ := unstructured.NestedSlice(fabric.Object, "status", "nodes")
	for _, raw := range nodes {
		node, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		nodePhase, _, _ := unstructured.NestedString(node, "phase")
		counts[nodePhase]++
		reachable, found, _ := unstructured.NestedBool(node, "managementReachable")
		if found && !reachable {
			unreachable++
		}
		observed, found, _ := unstructured.NestedInt64(node, "observedGeneration")
		if !found || observed != fabric.GetGeneration() {
			stale++
		}
		rollback, _, _ := unstructured.NestedString(node, "rollbackState")
		if rollback == "" {
			rollback = "Unknown"
		}
		rollbacks[rollback]++
	}
	for _, candidate := range nodePhases {
		networkFabricNodes.WithLabelValues(name, candidate).Set(counts[candidate])
	}
	for _, candidate := range rollbackStates {
		networkFabricRollbackNodes.WithLabelValues(name, candidate).Set(rollbacks[candidate])
	}
	networkFabricUnreachableNodes.WithLabelValues(name).Set(unreachable)
	networkFabricStaleNodes.WithLabelValues(name).Set(stale)

	observed, found, _ := unstructured.NestedInt64(fabric.Object, "status", "observedGeneration")
	if found {
		networkFabricObservedGeneration.WithLabelValues(name).Set(float64(observed))
	}

	migrationReady := 0.0
	conditions, _, _ := unstructured.NestedSlice(fabric.Object, "status", "conditions")
	for _, raw := range conditions {
		condition, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		typ, _, _ := unstructured.NestedString(condition, "type")
		status, _, _ := unstructured.NestedString(condition, "status")
		if typ == "MigrationReady" && status == "True" {
			migrationReady = 1
		}
	}
	networkFabricMigrationReady.WithLabelValues(name).Set(migrationReady)
	unavailable, _, _ := unstructured.NestedSlice(fabric.Object, "status", "migration", "unavailableNodes")
	networkFabricMigrationUnavailableNodes.WithLabelValues(name).Set(float64(len(unavailable)))
}

func readyConditionReason(fabric *unstructured.Unstructured) string {
	conditions, _, _ := unstructured.NestedSlice(fabric.Object, "status", "conditions")
	for _, raw := range conditions {
		condition, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		typ, _, _ := unstructured.NestedString(condition, "type")
		if typ != "Ready" {
			continue
		}
		reason, _, _ := unstructured.NestedString(condition, "reason")
		if reason != "" {
			return reason
		}
	}
	return "Unknown"
}

func deleteNetworkFabricMetrics(name string) {
	for _, phase := range fabricPhases {
		networkFabricStatus.DeleteLabelValues(name, phase)
	}
	for _, phase := range nodePhases {
		networkFabricNodes.DeleteLabelValues(name, phase)
	}
	for _, state := range rollbackStates {
		networkFabricRollbackNodes.DeleteLabelValues(name, state)
	}
	networkFabricUnreachableNodes.DeleteLabelValues(name)
	networkFabricStaleNodes.DeleteLabelValues(name)
	networkFabricMigrationReady.DeleteLabelValues(name)
	networkFabricMigrationUnavailableNodes.DeleteLabelValues(name)
	networkFabricObservedGeneration.DeleteLabelValues(name)
}
