// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestRecordNetworkFabricMetrics(t *testing.T) {
	name := "fabric-prod"
	defer deleteNetworkFabricMetrics(name)
	fabric := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "infrastructure.cozystack.io/v1alpha1",
		"kind":       "NetworkFabric",
		"metadata": map[string]interface{}{
			"name":       name,
			"generation": int64(7),
		},
		"status": map[string]interface{}{
			"observedGeneration": int64(7),
			"phase":              "Degraded",
			"nodes": []interface{}{
				map[string]interface{}{"name": "node-a", "phase": "Ready", "observedGeneration": int64(7), "managementReachable": true, "rollbackState": "NotRequired"},
				map[string]interface{}{"name": "node-b", "phase": "Failed", "observedGeneration": int64(6), "managementReachable": false, "rollbackState": "RolledBack"},
			},
			"conditions": []interface{}{
				map[string]interface{}{"type": "Ready", "status": "False", "reason": "HealthCheckFailed"},
				map[string]interface{}{"type": "MigrationReady", "status": "False", "reason": "TargetCapabilityMissing"},
			},
			"migration": map[string]interface{}{
				"configured": true,
				"unavailableNodes": []interface{}{map[string]interface{}{"name": "node-b", "reason": "bridge missing"}},
			},
		},
	}}
	fabric.SetGeneration(7)

	recordNetworkFabricMetrics(fabric)

	assertMetric(t, "fabric degraded", networkFabricStatus.WithLabelValues(name, "Degraded"), 1)
	assertMetric(t, "fabric ready", networkFabricStatus.WithLabelValues(name, "Ready"), 0)
	assertMetric(t, "ready nodes", networkFabricNodes.WithLabelValues(name, "Ready"), 1)
	assertMetric(t, "failed nodes", networkFabricNodes.WithLabelValues(name, "Failed"), 1)
	assertMetric(t, "unreachable nodes", networkFabricUnreachableNodes.WithLabelValues(name), 1)
	assertMetric(t, "stale nodes", networkFabricStaleNodes.WithLabelValues(name), 1)
	assertMetric(t, "rolled back nodes", networkFabricRollbackNodes.WithLabelValues(name, "RolledBack"), 1)
	assertMetric(t, "migration ready", networkFabricMigrationReady.WithLabelValues(name), 0)
	assertMetric(t, "migration unavailable", networkFabricMigrationUnavailableNodes.WithLabelValues(name), 1)
	assertMetric(t, "observed generation", networkFabricObservedGeneration.WithLabelValues(name), 7)
	if got := readyConditionReason(fabric); got != "HealthCheckFailed" {
		t.Fatalf("ready condition reason = %q, want HealthCheckFailed", got)
	}
}

func assertMetric(t *testing.T, name string, collector prometheus.Collector, want float64) {
	t.Helper()
	if got := testutil.ToFloat64(collector); got != want {
		t.Fatalf("%s = %v, want %v", name, got, want)
	}
}
