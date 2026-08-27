// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const capabilityLabelPrefix = "networkfabric.cozystack.io/"

func CapabilityLabelKey(fabricName string, network networkfabric.Network) string {
	canonical := fmt.Sprintf("%s|%s|%s|%d|%d", fabricName, network.Name, network.Bridge, network.VLAN, network.MTU)
	sum := sha256.Sum256([]byte(canonical))
	return capabilityLabelPrefix + "cap-" + hex.EncodeToString(sum[:8])
}

func capabilityOwner(fabricName string) string {
	sum := sha256.Sum256([]byte(fabricName))
	return "fabric-" + hex.EncodeToString(sum[:4])
}

type CapabilityReconciler struct {
	client.Client
	RequeueAfter time.Duration
}

func (r *CapabilityReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(NetworkFabricGVK)
	if err := r.Get(ctx, req.NamespacedName, fabric); err != nil {
		if client.IgnoreNotFound(err) == nil {
			return ctrl.Result{}, r.clearFabricLabels(ctx, req.Name)
		}
		return ctrl.Result{}, err
	}
	if !fabric.GetDeletionTimestamp().IsZero() {
		return ctrl.Result{}, r.clearFabricLabels(ctx, fabric.GetName())
	}

	spec, err := ParseSpec(fabric)
	if err != nil {
		return ctrl.Result{}, err
	}

	statusByNode := readCapabilityStatuses(fabric)
	selector := labels.SelectorFromSet(spec.NodeSelector)
	var nodes corev1.NodeList
	if err := r.List(ctx, &nodes); err != nil {
		return ctrl.Result{}, err
	}
	sort.Slice(nodes.Items, func(i, j int) bool { return nodes.Items[i].Name < nodes.Items[j].Name })
	for i := range nodes.Items {
		status := statusByNode[nodes.Items[i].Name]
		selected := selector.Matches(labels.Set(nodes.Items[i].Labels))
		ready := selected && status.Phase == "Ready" && status.ObservedGeneration == fabric.GetGeneration()
		if err := r.syncNode(ctx, &nodes.Items[i], fabric.GetName(), spec.Networks, ready); err != nil {
			return ctrl.Result{}, err
		}
	}

	return ctrl.Result{RequeueAfter: r.requeue()}, nil
}

func (r *CapabilityReconciler) requeue() time.Duration {
	if r.RequeueAfter <= 0 {
		return 2 * time.Minute
	}
	return r.RequeueAfter
}

type capabilityNodeStatus struct {
	Phase              string
	ObservedGeneration int64
}

func readCapabilityStatuses(fabric *unstructured.Unstructured) map[string]capabilityNodeStatus {
	out := map[string]capabilityNodeStatus{}
	items, _, _ := unstructured.NestedSlice(fabric.Object, "status", "nodes")
	for _, item := range items {
		m, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		name, _, _ := unstructured.NestedString(m, "name")
		phase, _, _ := unstructured.NestedString(m, "phase")
		generation, _, _ := unstructured.NestedInt64(m, "observedGeneration")
		if name != "" {
			out[name] = capabilityNodeStatus{Phase: phase, ObservedGeneration: generation}
		}
	}
	return out
}

func (r *CapabilityReconciler) syncNode(ctx context.Context, node *corev1.Node, fabricName string, networks []networkfabric.Network, ready bool) error {
	fresh := &corev1.Node{}
	if err := r.Get(ctx, client.ObjectKey{Name: node.Name}, fresh); err != nil {
		return err
	}
	base := fresh.DeepCopy()
	if fresh.Labels == nil {
		fresh.Labels = map[string]string{}
	}
	owner := capabilityOwner(fabricName)
	for key, value := range fresh.Labels {
		if strings.HasPrefix(key, capabilityLabelPrefix+"cap-") && value == owner {
			delete(fresh.Labels, key)
		}
	}
	if ready {
		for _, network := range networks {
			fresh.Labels[CapabilityLabelKey(fabricName, network)] = owner
		}
	}
	if stringMapEqual(base.Labels, fresh.Labels) {
		return nil
	}
	return r.Patch(ctx, fresh, client.MergeFrom(base))
}

func (r *CapabilityReconciler) clearFabricLabels(ctx context.Context, fabricName string) error {
	owner := capabilityOwner(fabricName)
	var nodes corev1.NodeList
	if err := r.List(ctx, &nodes); err != nil {
		return err
	}
	for i := range nodes.Items {
		base := nodes.Items[i].DeepCopy()
		changed := false
		for key, value := range nodes.Items[i].Labels {
			if strings.HasPrefix(key, capabilityLabelPrefix+"cap-") && value == owner {
				delete(nodes.Items[i].Labels, key)
				changed = true
			}
		}
		if changed {
			if err := r.Patch(ctx, &nodes.Items[i], client.MergeFrom(base)); err != nil {
				return err
			}
		}
	}
	return nil
}

func stringMapEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for key, value := range a {
		if b[key] != value {
			return false
		}
	}
	return true
}
