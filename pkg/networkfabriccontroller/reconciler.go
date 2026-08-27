// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

var NetworkFabricGVK = schema.GroupVersionKind{Group: "infrastructure.cozystack.io", Version: "v1alpha1", Kind: "NetworkFabric"}

const (
	NetworkFabricFinalizer = "networkfabric.infrastructure.cozystack.io/talos-cleanup"

	applicationKindLabel  = "apps.cozystack.io/application.kind"
	applicationGroupLabel = "apps.cozystack.io/application.group"
	applicationNameLabel  = "apps.cozystack.io/application.name"
	appsGroup             = "apps.cozystack.io"
	vmNetworkKind         = "VMNetwork"
)

var helmReleaseListGVK = schema.GroupVersionKind{Group: "helm.toolkit.fluxcd.io", Version: "v2", Kind: "HelmReleaseList"}

type AdapterFactory func(node *corev1.Node) (networkfabric.TalosAdapter, error)

type Reconciler struct {
	client.Client
	AdapterFactory AdapterFactory
	RequeueAfter   time.Duration
}

type FabricReference struct {
	Namespace     string
	Name          string
	FabricNetwork string
	Bridge        string
	VLAN          int
	MTU           int
}

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(NetworkFabricGVK)
	if err := r.Get(ctx, req.NamespacedName, fabric); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if !fabric.GetDeletionTimestamp().IsZero() {
		return r.reconcileDelete(ctx, fabric)
	}
	if !controllerutil.ContainsFinalizer(fabric, NetworkFabricFinalizer) {
		base := fabric.DeepCopy()
		controllerutil.AddFinalizer(fabric, NetworkFabricFinalizer)
		if err := r.Patch(ctx, fabric, client.MergeFrom(base)); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{Requeue: true}, nil
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

	statuses := readNodeStatuses(fabric)
	references, err := r.referencingVMNetworks(ctx, fabric.GetName())
	if err != nil {
		_ = r.setFailureStatus(ctx, fabric, "ReferenceLookupFailed", err.Error())
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}
	if err := validateReferenceSafety(spec, statuses, references); err != nil {
		_ = r.setFailureStatus(ctx, fabric, "FabricInUse", err.Error())
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}

	var nodes corev1.NodeList
	if err := r.List(ctx, &nodes, client.MatchingLabels(spec.NodeSelector)); err != nil {
		return ctrl.Result{}, err
	}
	sort.Slice(nodes.Items, func(i, j int) bool { return nodes.Items[i].Name < nodes.Items[j].Name })
	selected := make(map[string]struct{}, len(nodes.Items))
	for i := range nodes.Items {
		selected[nodes.Items[i].Name] = struct{}{}
	}

	// A node leaving the selector must be cleaned before normal rollout continues.
	// This is intentionally one node per reconcile to preserve the maxUnavailable=1
	// safety model and to avoid leaving stale Talos VLAN/bridge documents behind.
	statusNames := sortedStatusNames(statuses)
	for _, name := range statusNames {
		if _, ok := selected[name]; ok {
			continue
		}
		previous := ownedNetworks(statuses[name], spec, fabric.GetGeneration())
		if len(previous) == 0 {
			delete(statuses, name)
			if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "NodeSelectorChanged", fmt.Sprintf("removed obsolete status for node %s", name)), nil); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{Requeue: true}, nil
		}
		return r.cleanupNode(ctx, fabric, spec, statuses, name, previous, "NodeSelectorChanged")
	}

	if len(nodes.Items) == 0 {
		_ = r.setFailureStatus(ctx, fabric, "NoMatchingNodes", "NetworkFabric nodeSelector matches no Kubernetes nodes")
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}

	var target *corev1.Node
	for i := range nodes.Items {
		st := statuses[nodes.Items[i].Name]
		if st.ObservedGeneration != fabric.GetGeneration() || st.Phase != "Ready" || !networkSetsEqual(st.AppliedNetworks, spec.Networks) {
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
			return r.nodeFailed(ctx, fabric, statuses, target.Name, "AdapterError", networkfabric.ApplyReceipt{}, err)
		}
		previous := ownedNetworks(statuses[target.Name], spec, fabric.GetGeneration())
		statuses[target.Name] = NodeStatus{
			Name:                target.Name,
			Phase:               "Reconciling",
			ObservedGeneration:  fabric.GetGeneration(),
			ManagementReachable: true,
			Message:             "applying Talos VLAN/bridge configuration in try mode",
			AppliedNetworks:     previous,
			RollbackState:       "NotRequired",
		}
		if err := r.writeStatus(ctx, fabric, "Reconciling", target.Name, statuses, condition(fabric, "Ready", metav1.ConditionFalse, "RollingUpdate", fmt.Sprintf("reconciling node %s", target.Name)), nil); err != nil {
			return ctrl.Result{}, err
		}

		orchestrator := networkfabric.Orchestrator{Adapter: adapter}
		receipt, err := orchestrator.ReconcileNodeTransitionValidated(ctx, spec, previous, target.Name, func(state networkfabric.NodeState) error {
			return ValidateNodeCapabilities(spec, state)
		})
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, target.Name, "NodeReconcileFailed", receipt, err)
		}
		statuses[target.Name] = NodeStatus{
			Name:                target.Name,
			Phase:               "Ready",
			ObservedGeneration:  fabric.GetGeneration(),
			LastAppliedRevision: receipt.Revision,
			ManagementReachable: true,
			Message:             "Talos network configuration verified before confirmation",
			AppliedNetworks:     cloneNetworks(spec.Networks),
			LastVerifiedAt:      time.Now().UTC().Format(time.RFC3339),
			RollbackState:       "NotRequired",
		}
		if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "RollingUpdate", fmt.Sprintf("node %s completed; continuing rollout", target.Name)), nil); err != nil {
			return ctrl.Result{}, err
		}
		return ctrl.Result{RequeueAfter: time.Second}, nil
	}

	if r.AdapterFactory == nil {
		return ctrl.Result{}, fmt.Errorf("NetworkFabric adapter factory is not configured")
	}
	states := make([]networkfabric.NodeState, 0, len(nodes.Items))
	for i := range nodes.Items {
		adapter, err := r.AdapterFactory(&nodes.Items[i])
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, nodes.Items[i].Name, "AdapterError", networkfabric.ApplyReceipt{}, err)
		}
		state, err := adapter.Inspect(ctx, nodes.Items[i].Name)
		if err != nil {
			return r.nodeFailed(ctx, fabric, statuses, nodes.Items[i].Name, "HealthCheckFailed", networkfabric.ApplyReceipt{}, err)
		}
		if err := ValidateNodeCapabilities(spec, state); err != nil {
			return r.nodeFailed(ctx, fabric, statuses, nodes.Items[i].Name, "CapabilityVerificationFailed", networkfabric.ApplyReceipt{}, err)
		}
		st := statuses[nodes.Items[i].Name]
		st.ManagementReachable = true
		st.LastVerifiedAt = time.Now().UTC().Format(time.RFC3339)
		st.Message = "Talos network configuration healthy"
		statuses[nodes.Items[i].Name] = st
		states = append(states, state)
	}

	migration := networkfabric.ValidateMigrationCompatibility(spec, states)
	conditions := []map[string]interface{}{condition(fabric, "Ready", metav1.ConditionTrue, "Reconciled", "all selected nodes have the exact required Talos VLAN/bridge topology")}
	if migration.Configured {
		if migration.Ready() {
			conditions = append(conditions, condition(fabric, "MigrationReady", metav1.ConditionTrue, "AllTargetsCapable", "migration VLAN and bridge topology is available with compatible MTU on every selected node"))
		} else {
			conditions = append(conditions, condition(fabric, "MigrationReady", metav1.ConditionFalse, "TargetCapabilityMissing", "one or more migration destinations lack the exact required network topology"))
		}
	} else {
		conditions = append(conditions, condition(fabric, "MigrationReady", metav1.ConditionTrue, "NotConfigured", "no dedicated migration network is configured"))
	}
	if err := r.writeStatus(ctx, fabric, "Ready", "", statuses, conditions[0], migrationStatus(migration, conditions[1])); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *Reconciler) reconcileDelete(ctx context.Context, fabric *unstructured.Unstructured) (ctrl.Result, error) {
	if !controllerutil.ContainsFinalizer(fabric, NetworkFabricFinalizer) {
		return ctrl.Result{}, nil
	}

	spec, err := ParseSpec(fabric)
	if err != nil {
		return ctrl.Result{RequeueAfter: r.requeue()}, fmt.Errorf("parse deleting NetworkFabric %s: %w", fabric.GetName(), err)
	}
	if err := networkfabric.Validate(spec); err != nil {
		return ctrl.Result{RequeueAfter: r.requeue()}, err
	}

	references, err := r.referencingVMNetworks(ctx, fabric.GetName())
	if err != nil {
		_ = r.setFailureStatus(ctx, fabric, "ReferenceLookupFailed", err.Error())
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}
	if len(references) > 0 {
		_ = r.setFailureStatus(ctx, fabric, "FabricInUse", formatReferences("cannot delete NetworkFabric while VMNetwork references exist", references))
		return ctrl.Result{RequeueAfter: r.requeue()}, nil
	}

	statuses := readNodeStatuses(fabric)
	for _, name := range sortedStatusNames(statuses) {
		previous := ownedNetworks(statuses[name], spec, fabric.GetGeneration())
		if len(previous) == 0 {
			delete(statuses, name)
			if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, "Deleting", fmt.Sprintf("discarded non-owned status for node %s", name)), nil); err != nil {
				return ctrl.Result{}, err
			}
			return ctrl.Result{Requeue: true}, nil
		}
		return r.cleanupNode(ctx, fabric, spec, statuses, name, previous, "Deleting")
	}

	base := fabric.DeepCopy()
	controllerutil.RemoveFinalizer(fabric, NetworkFabricFinalizer)
	if err := r.Patch(ctx, fabric, client.MergeFrom(base)); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *Reconciler) cleanupNode(ctx context.Context, fabric *unstructured.Unstructured, spec networkfabric.Spec, statuses map[string]NodeStatus, nodeName string, previous []networkfabric.Network, reason string) (ctrl.Result, error) {
	if r.AdapterFactory == nil {
		return ctrl.Result{}, fmt.Errorf("NetworkFabric adapter factory is not configured")
	}
	node := &corev1.Node{}
	if err := r.Get(ctx, client.ObjectKey{Name: nodeName}, node); err != nil {
		message := fmt.Sprintf("cannot clean previously managed node %s: %v", nodeName, err)
		return r.nodeFailed(ctx, fabric, statuses, nodeName, reason+"CleanupFailed", networkfabric.ApplyReceipt{}, fmt.Errorf("%s", message))
	}
	adapter, err := r.AdapterFactory(node)
	if err != nil {
		return r.nodeFailed(ctx, fabric, statuses, nodeName, reason+"AdapterError", networkfabric.ApplyReceipt{}, err)
	}

	st := statuses[nodeName]
	st.Name = nodeName
	st.Phase = "Reconciling"
	st.Message = "removing controller-owned Talos bridge/VLAN documents"
	st.AppliedNetworks = cloneNetworks(previous)
	st.RollbackState = "NotRequired"
	statuses[nodeName] = st
	if err := r.writeStatus(ctx, fabric, "Reconciling", nodeName, statuses, condition(fabric, "Ready", metav1.ConditionFalse, reason, fmt.Sprintf("cleaning Talos network configuration from node %s", nodeName)), nil); err != nil {
		return ctrl.Result{}, err
	}

	cleanupSpec := spec
	cleanupSpec.Networks = nil
	orchestrator := networkfabric.Orchestrator{Adapter: adapter}
	receipt, err := orchestrator.ReconcileNodeTransitionValidated(ctx, cleanupSpec, previous, nodeName, func(state networkfabric.NodeState) error {
		return networkfabric.ValidateNetworksAbsent(state, previous)
	})
	if err != nil {
		return r.nodeFailed(ctx, fabric, statuses, nodeName, reason+"CleanupFailed", receipt, err)
	}
	delete(statuses, nodeName)
	if err := r.writeStatus(ctx, fabric, "Reconciling", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, reason, fmt.Sprintf("cleaned Talos network configuration from node %s", nodeName)), nil); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{Requeue: true}, nil
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
	for _, network := range spec.Networks {
		if err := networkfabric.ValidateNetworkTopology(state, network); err != nil {
			return err
		}
	}
	return nil
}

type NodeStatus struct {
	Name                string
	Phase               string
	ObservedGeneration  int64
	LastAppliedRevision string
	ManagementReachable bool
	Message             string
	AppliedNetworks     []networkfabric.Network
	LastVerifiedAt      string
	RollbackState       string
}

func readNodeStatuses(obj *unstructured.Unstructured) map[string]NodeStatus {
	out := map[string]NodeStatus{}
	items, _, _ := unstructured.NestedSlice(obj.Object, "status", "nodes")
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		name, _, _ := unstructured.NestedString(m, "name")
		phase, _, _ := unstructured.NestedString(m, "phase")
		gen, _, _ := unstructured.NestedInt64(m, "observedGeneration")
		revision, _, _ := unstructured.NestedString(m, "lastAppliedRevision")
		reachable, _, _ := unstructured.NestedBool(m, "managementReachable")
		message, _, _ := unstructured.NestedString(m, "message")
		verified, _, _ := unstructured.NestedString(m, "lastVerifiedAt")
		rollback, _, _ := unstructured.NestedString(m, "rollbackState")
		applied := parseStatusNetworks(m)
		if name != "" {
			out[name] = NodeStatus{Name: name, Phase: phase, ObservedGeneration: gen, LastAppliedRevision: revision, ManagementReachable: reachable, Message: message, AppliedNetworks: applied, LastVerifiedAt: verified, RollbackState: rollback}
		}
	}
	return out
}

func parseStatusNetworks(node map[string]interface{}) []networkfabric.Network {
	items, _, _ := unstructured.NestedSlice(node, "appliedNetworks")
	out := make([]networkfabric.Network, 0, len(items))
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
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
		out = append(out, n)
	}
	return out
}

func (r *Reconciler) nodeFailed(ctx context.Context, fabric *unstructured.Unstructured, statuses map[string]NodeStatus, node, reason string, receipt networkfabric.ApplyReceipt, err error) (ctrl.Result, error) {
	previous := statuses[node]
	rollbackState := previous.RollbackState
	if rollbackState == "" {
		rollbackState = "Unknown"
	}
	if strings.Contains(err.Error(), "rollback to revision") && strings.Contains(err.Error(), "also failed") {
		rollbackState = "RollbackFailed"
	} else if strings.Contains(err.Error(), "rolled back to revision") {
		rollbackState = "RolledBack"
	}
	revision := previous.LastAppliedRevision
	if receipt.Revision != "" {
		revision = receipt.Revision
	}
	statuses[node] = NodeStatus{
		Name:                node,
		Phase:               "Failed",
		ObservedGeneration:  fabric.GetGeneration(),
		LastAppliedRevision: revision,
		ManagementReachable: false,
		Message:             err.Error(),
		AppliedNetworks:     cloneNetworks(previous.AppliedNetworks),
		LastVerifiedAt:      previous.LastVerifiedAt,
		RollbackState:       rollbackState,
	}
	statusErr := r.writeStatus(ctx, fabric, "Degraded", "", statuses, condition(fabric, "Ready", metav1.ConditionFalse, reason, err.Error()), nil)
	if statusErr != nil {
		return ctrl.Result{}, statusErr
	}
	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *Reconciler) setFailureStatus(ctx context.Context, fabric *unstructured.Unstructured, reason, message string) error {
	return r.writeStatus(ctx, fabric, "Failed", "", readNodeStatuses(fabric), condition(fabric, "Ready", metav1.ConditionFalse, reason, message), nil)
}

func (r *Reconciler) writeStatus(ctx context.Context, fabric *unstructured.Unstructured, phase, activeNode string, statuses map[string]NodeStatus, ready map[string]interface{}, migration map[string]interface{}) error {
	base := fabric.DeepCopy()
	nodes := make([]interface{}, 0, len(statuses))
	for _, name := range sortedStatusNames(statuses) {
		st := statuses[name]
		item := map[string]interface{}{
			"name":                st.Name,
			"phase":               st.Phase,
			"observedGeneration":  st.ObservedGeneration,
			"lastAppliedRevision": st.LastAppliedRevision,
			"managementReachable": st.ManagementReachable,
			"message":             st.Message,
			"appliedNetworks":     statusNetworks(st.AppliedNetworks),
			"lastVerifiedAt":      st.LastVerifiedAt,
			"rollbackState":       st.RollbackState,
		}
		nodes = append(nodes, item)
	}
	conditions := []interface{}{ready}
	if migration != nil {
		if c, ok := migration["condition"].(map[string]interface{}); ok {
			conditions = append(conditions, c)
		}
	}
	status := map[string]interface{}{"observedGeneration": fabric.GetGeneration(), "phase": phase, "activeNode": activeNode, "nodes": nodes, "conditions": conditions}
	if migration != nil {
		migrationCopy := make(map[string]interface{}, len(migration))
		for key, value := range migration {
			if key != "condition" {
				migrationCopy[key] = value
			}
		}
		status["migration"] = migrationCopy
	}
	if err := unstructured.SetNestedMap(fabric.Object, status, "status"); err != nil {
		return err
	}
	return r.Status().Patch(ctx, fabric, client.MergeFrom(base))
}

func statusNetworks(networks []networkfabric.Network) []interface{} {
	out := make([]interface{}, 0, len(networks))
	for _, network := range networks {
		out = append(out, map[string]interface{}{
			"name":          network.Name,
			"uplink":        network.Uplink,
			"vlan":          int64(network.VLAN),
			"vlanInterface": network.VLANInterface,
			"bridge":        network.Bridge,
			"mtu":           int64(network.MTU),
			"migration":     network.Migration,
		})
	}
	return out
}

func condition(fabric *unstructured.Unstructured, typ string, status metav1.ConditionStatus, reason, message string) map[string]interface{} {
	return map[string]interface{}{"type": typ, "status": string(status), "observedGeneration": fabric.GetGeneration(), "lastTransitionTime": time.Now().UTC().Format(time.RFC3339), "reason": reason, "message": message}
}

func migrationStatus(report networkfabric.MigrationReport, cond map[string]interface{}) map[string]interface{} {
	unavailable := make([]interface{}, 0, len(report.UnavailableNodes))
	names := make([]string, 0, len(report.UnavailableNodes))
	for name := range report.UnavailableNodes {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		unavailable = append(unavailable, map[string]interface{}{"name": name, "reason": report.UnavailableNodes[name]})
	}
	ready := make([]interface{}, len(report.ReadyNodes))
	for i, name := range report.ReadyNodes {
		ready[i] = name
	}
	return map[string]interface{}{"configured": report.Configured, "network": report.Network, "bridge": report.Bridge, "readyNodes": ready, "unavailableNodes": unavailable, "condition": cond}
}

func (r *Reconciler) referencingVMNetworks(ctx context.Context, fabricName string) ([]FabricReference, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(helmReleaseListGVK)
	if err := r.List(ctx, list, client.MatchingLabels{applicationKindLabel: vmNetworkKind, applicationGroupLabel: appsGroup}); err != nil {
		return nil, fmt.Errorf("list VMNetwork HelmReleases for NetworkFabric %q: %w", fabricName, err)
	}
	var refs []FabricReference
	for i := range list.Items {
		item := &list.Items[i]
		ref, _, _ := unstructured.NestedString(item.Object, "spec", "values", "fabricRef")
		if ref != fabricName {
			continue
		}
		fabricNetwork, _, _ := unstructured.NestedString(item.Object, "spec", "values", "fabricNetwork")
		bridge, _, _ := unstructured.NestedString(item.Object, "spec", "values", "bridge")
		vlan, _, _ := unstructured.NestedInt64(item.Object, "spec", "values", "vlan")
		mtu, _, _ := unstructured.NestedInt64(item.Object, "spec", "values", "mtu")
		name := item.GetLabels()[applicationNameLabel]
		if name == "" {
			name = item.GetName()
		}
		refs = append(refs, FabricReference{Namespace: item.GetNamespace(), Name: name, FabricNetwork: fabricNetwork, Bridge: bridge, VLAN: int(vlan), MTU: int(mtu)})
	}
	sort.Slice(refs, func(i, j int) bool {
		if refs[i].Namespace == refs[j].Namespace {
			return refs[i].Name < refs[j].Name
		}
		return refs[i].Namespace < refs[j].Namespace
	})
	return refs, nil
}

func validateReferenceSafety(spec networkfabric.Spec, statuses map[string]NodeStatus, refs []FabricReference) error {
	if len(refs) == 0 {
		return nil
	}
	desired := make(map[string]networkfabric.Network, len(spec.Networks))
	for _, network := range spec.Networks {
		desired[network.Name] = network
	}
	for _, ref := range refs {
		network, ok := desired[ref.FabricNetwork]
		if !ok {
			return fmt.Errorf("NetworkFabric network %q is referenced by VMNetwork %s/%s and cannot be removed", ref.FabricNetwork, ref.Namespace, ref.Name)
		}
		if network.Bridge != ref.Bridge || network.VLAN != ref.VLAN || network.MTU != ref.MTU {
			return fmt.Errorf("NetworkFabric network %q is referenced by VMNetwork %s/%s with bridge=%s vlan=%d mtu=%d; detach or migrate the VMNetwork before changing its dataplane", ref.FabricNetwork, ref.Namespace, ref.Name, ref.Bridge, ref.VLAN, ref.MTU)
		}
		for _, status := range statuses {
			for _, previous := range status.AppliedNetworks {
				if previous.Name == ref.FabricNetwork && physicalTopologyChanged(previous, network) {
					return fmt.Errorf("NetworkFabric network %q is referenced by VMNetwork %s/%s and its physical uplink/VLAN/bridge topology cannot change while in use", ref.FabricNetwork, ref.Namespace, ref.Name)
				}
			}
		}
	}
	return nil
}

func physicalTopologyChanged(a, b networkfabric.Network) bool {
	return a.Uplink != b.Uplink || a.VLAN != b.VLAN || a.VLANInterface != b.VLANInterface || a.Bridge != b.Bridge || a.MTU != b.MTU
}

func formatReferences(prefix string, refs []FabricReference) string {
	parts := make([]string, 0, len(refs))
	for _, ref := range refs {
		parts = append(parts, fmt.Sprintf("%s/%s(%s)", ref.Namespace, ref.Name, ref.FabricNetwork))
	}
	return fmt.Sprintf("%s: %s", prefix, strings.Join(parts, ", "))
}

func ownedNetworks(status NodeStatus, spec networkfabric.Spec, generation int64) []networkfabric.Network {
	if len(status.AppliedNetworks) > 0 {
		return cloneNetworks(status.AppliedNetworks)
	}
	// Upgrade compatibility: the previous controller already treated a Ready
	// status at the current generation as authoritative for the current spec.
	// Claim only that exact topology; never infer arbitrary discovered links.
	if status.Phase == "Ready" && status.ObservedGeneration == generation {
		return cloneNetworks(spec.Networks)
	}
	return nil
}

func networkSetsEqual(a, b []networkfabric.Network) bool {
	if len(a) != len(b) {
		return false
	}
	left := cloneNetworks(a)
	right := cloneNetworks(b)
	sort.Slice(left, func(i, j int) bool { return left[i].Name < left[j].Name })
	sort.Slice(right, func(i, j int) bool { return right[i].Name < right[j].Name })
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func cloneNetworks(in []networkfabric.Network) []networkfabric.Network {
	return append([]networkfabric.Network(nil), in...)
}

func sortedStatusNames(statuses map[string]NodeStatus) []string {
	names := make([]string, 0, len(statuses))
	for name := range statuses {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func TalosEndpoint(node *corev1.Node) (string, error) {
	for _, a := range node.Status.Addresses {
		if a.Type == corev1.NodeInternalIP && a.Address != "" {
			return a.Address, nil
		}
	}
	return "", fmt.Errorf("node %s has no InternalIP for Talos API access", node.Name)
}

// Ensure the reconciler continues to treat deletion races as normal controller behavior.
func IsGone(err error) bool { return apierrors.IsNotFound(err) }
