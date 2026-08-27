// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var NetworkFabricGVK = schema.GroupVersionKind{Group: "infrastructure.cozystack.io", Version: "v1alpha1", Kind: "NetworkFabric"}

type AdapterFactory func(node *corev1.Node) (networkfabric.TalosAdapter, error)

type Reconciler struct {
	client.Client
	AdapterFactory AdapterFactory
	RequeueAfter   time.Duration
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(NetworkFabricGVK)
	if err := r.Get(ctx, req.NamespacedName, fabric); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if !fabric.GetDeletionTimestamp().IsZero() {
		return ctrl.Result{}, nil
	}

	spec, err := ParseSpec(fabric)
	if err != nil {
		_ = r.setFailureStatus(ctx, fabric, "InvalidSpec", err.Error())
		return ctrl.Result{}, nil
	}
	if err := networkfabric.Validate(spec); err != nil {
		_ = r.setFailureStatus(ctx, fabric, "InvalidSpec", err.Error())
		return ctrl.Result{}, nil
	}

	var nodes corev1.NodeList
	if err := r.List(ctx, &nodes, client.MatchingLabels(spec.NodeSelector)); err != nil {
		return ctrl.Result{}, err
	}
	sort.Slice(nodes.Items, func(i, j int) bool { return nodes.Items[i].Name < nodes.Items[j].Name })
	if len(nodes.Items) == 0 {
		_ = r.setFailureStatus(ctx, fabric, "NoMatchingNodes", "NetworkFabric nodeSelector matches no Kubernetes nodes")
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}

	statuses := readNodeStatuses(fabric)
	var target *corev1.Node
	for i := range nodes.Items {
		st := statuses[nodes.Items[i].Name]
		if st.ObservedGeneration != fabric.GetGeneration() || st.Phase != "Ready" {
			target = &nodes.Items[i]
			break
		}
	}

	if target != nil {
		if r.AdapterFactory == nil {
			return ctrl.Result{}, fmt.Errorf("NetworkFabric adapter factory is not configured")
		}
		adapter, err := r.AdapterFactory(target)
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, target.Name, "AdapterError", err)
		}
		statuses[target.Name] = NodeStatus{Name: target.Name, Phase: "Reconciling", ObservedGeneration: fabric.GetGeneration(), ManagementReachable: true, Message: "applying Talos VLAN/bridge configuration"}
		if err := r.writeStatus(ctx, fabric, "Reconciling", target.Name, statuses, condition(fabric, "Ready", metav1.ConditionFalse, "RollingUpdate", fmt.Sprintf("reconciling node %s", target.Name)), nil); err != nil {
			return ctrl.Result{}, err
		}

		orchestrator := networkfabric.Orchestrator{Adapter: adapter}
		if err := orchestrator.ReconcileNode(ctx, spec, target.Name); err != nil {
			return r.nodeFailed(ctx, fabric, statuses, target.Name, "NodeReconcileFailed", err)
		}
		state, err := adapter.Inspect(ctx, target.Name)
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, target.Name, "PostApplyInspectFailed", err)
		}
		if err := ValidateNodeCapabilities(spec, state); err != nil {
			return r.nodeFailed(ctx, fabric, statuses, target.Name, "CapabilityVerificationFailed", err)
		}
		statuses[target.Name] = NodeStatus{Name: target.Name, Phase: "Ready", ObservedGeneration: fabric.GetGeneration(), ManagementReachable: true, Message: "Talos network configuration verified"}
		if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "RollingUpdate", fmt.Sprintf("node %s completed; continuing rollout", target.Name)), nil); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: time.Second}, nil
	}

	states := make([]networkfabric.NodeState, 0, len(nodes.Items))
	for i := range nodes.Items {
		adapter, err := r.AdapterFactory(&nodes.Items[i])
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, nodes.Items[i].Name, "AdapterError", err)
		}
		state, err := adapter.Inspect(ctx, nodes.Items[i].Name)
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, nodes.Items[i].Name, "HealthCheckFailed", err)
		}
		if err := ValidateNodeCapabilities(spec, state); err != nil {
			return r.nodeFailed(ctx, fabric, statuses, nodes.Items[i].Name, "CapabilityVerificationFailed", err)
		}
		states = append(states, state)
	}

	migration := networkfabric.ValidateMigrationCompatibility(spec, states)
	conditions := []map[string]interface{}{condition(fabric, "Ready", metav1.ConditionTrue, "Reconciled", "all selected nodes have the required Talos VLANs and bridges")}
	if migration.Configured {
		if migration.Ready() {
			conditions = append(conditions, condition(fabric, "MigrationReady", metav1.ConditionTrue, "AllTargetsCapable", "migration bridge is available with compatible MTU on every selected node"))
		} else {
			conditions = append(conditions, condition(fabric, "MigrationReady", metav1.ConditionFalse, "TargetCapabilityMissing", "one or more migration destinations lack the required network capability"))
		}
	} else {
		conditions = append(conditions, condition(fabric, "MigrationReady", metav1.ConditionTrue, "NotConfigured", "no dedicated migration network is configured"))
	}
	if err := r.writeStatus(ctx, fabric, "Ready", "", statuses, conditions[0], migrationStatus(migration, conditions[1])); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *Reconciler) requeue() time.Duration {
	if r.RequeueAfter <= 0 {
		return 2 * time.Minute
	}
	return r.RequeueAfter
}

func ParseSpec(obj *unstructured.Unstructured) (networkfabric.Spec, error) {
	provider, _, _ := unstructured.NestedString(obj.Object, "spec", "provider")
	selector, _, _ := unstructured.NestedStringMap(obj.Object, "spec", "nodeSelector")
	protected, _, _ := unstructured.NestedStringSlice(obj.Object, "spec", "protectedManagementInterfaces")
	maxUnavailable, found, _ := unstructured.NestedInt64(obj.Object, "spec", "rollout", "maxUnavailable")
	if !found {
		maxUnavailable = 1
	}
	rawNetworks, _, err := unstructured.NestedSlice(obj.Object, "spec", "networks")
	if err != nil {
		return networkfabric.Spec{}, err
	}
	spec := networkfabric.Spec{Provider: provider, NodeSelector: selector, ProtectedManagementInterfaces: protected, Rollout: networkfabric.Rollout{MaxUnavailable: int(maxUnavailable)}}
	for _, raw := range rawNetworks {
		m, ok := raw.(map[string]interface{})
		if !ok {
			return networkfabric.Spec{}, fmt.Errorf("spec.networks contains a non-object item")
		}
		n := networkfabric.Network{}
		n.Name, _, _ = unstructured.NestedString(m, "name")
		n.Uplink, _, _ = unstructured.NestedString(m, "uplink")
		vlan, _, _ := unstructured.NestedInt64(m, "vlan")
		n.VLAN = int(vlan)
		n.VLANInterface, _, _ = unstructured.NestedString(m, "vlanInterface")
		n.Bridge, _, _ = unstructured.NestedString(m, "bridge")
		mtu, _, _ := unstructured.NestedInt64(m, "mtu")
		n.MTU = int(mtu)
		n.Migration, _, _ = unstructured.NestedBool(m, "migration")
		spec.Networks = append(spec.Networks, n)
	}
	return spec, nil
}

func ValidateNodeCapabilities(spec networkfabric.Spec, state networkfabric.NodeState) error {
	for _, n := range spec.Networks {
		bridge, ok := state.Interfaces[n.Bridge]
		if !ok {
			return fmt.Errorf("node %s is missing bridge %s for network %s", state.Name, n.Bridge, n.Name)
		}
		if !bridge.Up {
			return fmt.Errorf("node %s bridge %s is down", state.Name, n.Bridge)
		}
		if n.MTU > 0 && bridge.MTU > 0 && bridge.MTU != n.MTU {
			return fmt.Errorf("node %s bridge %s MTU %d does not match required MTU %d", state.Name, n.Bridge, bridge.MTU, n.MTU)
		}
	}
	return nil
}

type NodeStatus struct {
	Name                string
	Phase               string
	ObservedGeneration  int64
	ManagementReachable bool
	Message             string
}

func readNodeStatuses(obj *unstructured.Unstructured) map[string]NodeStatus {
	out := map[string]NodeStatus{}
	items, _, _ := unstructured.NestedSlice(obj.Object, "status", "nodes")
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok { continue }
		name, _, _ := unstructured.NestedString(m, "name")
		phase, _, _ := unstructured.NestedString(m, "phase")
		gen, _, _ := unstructured.NestedInt64(m, "observedGeneration")
		reachable, _, _ := unstructured.NestedBool(m, "managementReachable")
		message, _, _ := unstructured.NestedString(m, "message")
		if name != "" { out[name] = NodeStatus{Name: name, Phase: phase, ObservedGeneration: gen, ManagementReachable: reachable, Message: message} }
	}
	return out
}

func (r *Reconciler) nodeFailed(ctx context.Context, fabric *unstructured.Unstructured, statuses map[string]NodeStatus, node, reason string, err error) (ctrl.Result, error) {
	statuses[node] = NodeStatus{Name: node, Phase: "Failed", ObservedGeneration: fabric.GetGeneration(), ManagementReachable: false, Message: err.Error()}
	statusErr := r.writeStatus(ctx, fabric, "Degraded", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, reason, err.Error()), nil)
	if statusErr != nil { return ctrl.Result{}, statusErr }
	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *Reconciler) setFailureStatus(ctx context.Context, fabric *unstructured.Unstructured, reason, message string) error {
	return r.writeStatus(ctx, fabric, "Failed", "", readNodeStatuses(fabric), condition(fabric, "Ready", metav1.ConditionFalse, reason, message), nil)
}

func (r *Reconciler) writeStatus(ctx context.Context, fabric *unstructured.Unstructured, phase, activeNode string, statuses map[string]NodeStatus, ready map[string]interface{}, migration map[string]interface{}) error {
	base := fabric.DeepCopy()
	nodes := make([]interface{}, 0, len(statuses))
	names := make([]string, 0, len(statuses))
	for name := range statuses { names = append(names, name) }
	sort.Strings(names)
	for _, name := range names {
		st := statuses[name]
		nodes = append(nodes, map[string]interface{}{"name": st.Name, "phase": st.Phase, "observedGeneration": st.ObservedGeneration, "managementReachable": st.ManagementReachable, "message": st.Message})
	}
	conditions := []interface{}{ready}
	if migration != nil {
		if c, ok := migration["condition"].(map[string]interface{}); ok { conditions = append(conditions, c) }
	}
	status := map[string]interface{}{"observedGeneration": fabric.GetGeneration(), "phase": phase, "activeNode": activeNode, "nodes": nodes, "conditions": conditions}
	if migration != nil {
		delete(migration, "condition")
		status["migration"] = migration
	}
	if err := unstructured.SetNestedMap(fabric.Object, status, "status"); err != nil { return err }
	return r.Status().Patch(ctx, fabric, client.MergeFrom(base))
}

func condition(fabric *unstructured.Unstructured, typ string, status metav1.ConditionStatus, reason, message string) map[string]interface{} {
	return map[string]interface{}{"type": typ, "status": string(status), "observedGeneration": fabric.GetGeneration(), "lastTransitionTime": time.Now().UTC().Format(time.RFC3339), "reason": reason, "message": message}
}

func migrationStatus(report networkfabric.MigrationReport, cond map[string]interface{}) map[string]interface{} {
	unavailable := make([]interface{}, 0, len(report.UnavailableNodes))
	names := make([]string, 0, len(report.UnavailableNodes))
	for name := range report.UnavailableNodes { names = append(names, name) }
	sort.Strings(names)
	for _, name := range names { unavailable = append(unavailable, map[string]interface{}{"name": name, "reason": report.UnavailableNodes[name]}) }
	ready := make([]interface{}, len(report.ReadyNodes))
	for i, name := range report.ReadyNodes { ready[i] = name }
	return map[string]interface{}{"configured": report.Configured, "network": report.Network, "bridge": report.Bridge, "readyNodes": ready, "unavailableNodes": unavailable, "condition": cond}
}

func TalosEndpoint(node *corev1.Node) (string, error) {
	for _, a := range node.Status.Addresses {
		if a.Type == corev1.NodeInternalIP && a.Address != "" { return a.Address, nil }
	}
	return "", fmt.Errorf("node %s has no InternalIP for Talos API access", node.Name)
}

// Ensure the reconciler continues to treat deletion races as normal controller behavior.
func IsGone(err error) bool { return apierrors.IsNotFound(err) }
