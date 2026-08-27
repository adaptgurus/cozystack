// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
)

var networkFabricListGVK = schema.GroupVersionKind{Group: NetworkFabricGVK.Group, Version: NetworkFabricGVK.Version, Kind: "NetworkFabricList"}

// ConflictGuardedReconciler reserves controller-owned Talos link identities
// across NetworkFabric objects before the transactional reconciler is allowed
// to inspect or mutate a node. This closes the create/update race where two
// otherwise valid fabrics could target the same bridge/VLAN documents.
type ConflictGuardedReconciler struct {
	Inner *Reconciler
}

func (r *ConflictGuardedReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if r == nil || r.Inner == nil {
		return ctrl.Result{}, fmt.Errorf("NetworkFabric conflict guard has no inner reconciler")
	}

	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(NetworkFabricGVK)
	if err := r.Inner.Get(ctx, req.NamespacedName, fabric); err != nil {
		if apierrors.IsNotFound(err) {
			return r.Inner.Reconcile(ctx, req)
		}
		return ctrl.Result{}, err
	}
	if !fabric.GetDeletionTimestamp().IsZero() {
		return r.Inner.Reconcile(ctx, req)
	}

	spec, err := ParseSpec(fabric)
	if err != nil || networkfabric.Validate(spec) != nil {
		// The inner reconciler owns canonical invalid-spec reporting.
		return r.Inner.Reconcile(ctx, req)
	}

	peers := &unstructured.UnstructuredList{}
	peers.SetGroupVersionKind(networkFabricListGVK)
	if err := r.Inner.List(ctx, peers); err != nil {
		_ = r.Inner.setFailureStatus(ctx, fabric, "OwnershipLookupFailed", fmt.Sprintf("list NetworkFabric ownership reservations: %v", err))
		return ctrl.Result{RequeueAfter: r.Inner.requeue()}, nil
	}
	var nodes corev1.NodeList
	if err := r.Inner.List(ctx, &nodes); err != nil {
		_ = r.Inner.setFailureStatus(ctx, fabric, "OwnershipLookupFailed", fmt.Sprintf("list Kubernetes nodes for NetworkFabric ownership validation: %v", err))
		return ctrl.Result{RequeueAfter: r.Inner.requeue()}, nil
	}

	peerSpecs := make([]namedFabricSpec, 0, len(peers.Items))
	for i := range peers.Items {
		peer := &peers.Items[i]
		if peer.GetName() == fabric.GetName() || !peer.GetDeletionTimestamp().IsZero() {
			continue
		}
		peerSpec, parseErr := ParseSpec(peer)
		if parseErr != nil || networkfabric.Validate(peerSpec) != nil {
			continue
		}
		peerSpecs = append(peerSpecs, namedFabricSpec{Name: peer.GetName(), Spec: peerSpec})
	}

	if err := validateCrossFabricOwnership(fabric.GetName(), spec, peerSpecs, nodes.Items); err != nil {
		_ = r.Inner.setFailureStatus(ctx, fabric, "OwnershipConflict", err.Error())
		return ctrl.Result{RequeueAfter: r.Inner.requeue()}, nil
	}
	return r.Inner.Reconcile(ctx, req)
}

type namedFabricSpec struct {
	Name string
	Spec networkfabric.Spec
}

func validateCrossFabricOwnership(currentName string, current networkfabric.Spec, peers []namedFabricSpec, nodes []corev1.Node) error {
	currentSelector := labels.SelectorFromSet(current.NodeSelector)
	for _, peer := range peers {
		peerSelector := labels.SelectorFromSet(peer.Spec.NodeSelector)
		overlap := overlappingNodes(currentSelector, peerSelector, nodes)

		// KubeVirt has one cluster-wide migration transport selection. More than
		// one fabric advertising itself as the dedicated migration fabric is
		// ambiguous even when the current node selectors are disjoint.
		if hasMigrationNetwork(current) && hasMigrationNetwork(peer.Spec) {
			return fmt.Errorf("NetworkFabric %q conflicts with NetworkFabric %q: more than one fabric declares a dedicated migration network", currentName, peer.Name)
		}
		if len(overlap) == 0 {
			continue
		}

		for _, desired := range current.Networks {
			for _, reserved := range peer.Spec.Networks {
				if reason := physicalOwnershipConflict(desired, reserved); reason != "" {
					return fmt.Errorf("NetworkFabric %q conflicts with NetworkFabric %q on node(s) %s: %s", currentName, peer.Name, strings.Join(overlap, ","), reason)
				}
			}
		}
	}
	return nil
}

func overlappingNodes(a, b labels.Selector, nodes []corev1.Node) []string {
	var out []string
	for i := range nodes {
		set := labels.Set(nodes[i].Labels)
		if a.Matches(set) && b.Matches(set) {
			out = append(out, nodes[i].Name)
		}
	}
	sort.Strings(out)
	return out
}

func hasMigrationNetwork(spec networkfabric.Spec) bool {
	for _, network := range spec.Networks {
		if network.Migration {
			return true
		}
	}
	return false
}

func physicalOwnershipConflict(a, b networkfabric.Network) string {
	for _, left := range []string{a.VLANInterface, a.Bridge} {
		if left == "" {
			continue
		}
		for _, right := range []string{b.VLANInterface, b.Bridge} {
			if left == right && right != "" {
				return fmt.Sprintf("managed Talos link %q is reserved by both fabrics", left)
			}
		}
	}

	// Never allow one fabric to build on a link that another NetworkFabric
	// controller owns. Physical/bond uplinks that neither controller owns may
	// legitimately be shared as a VLAN trunk.
	for _, owned := range []string{b.VLANInterface, b.Bridge} {
		if owned != "" && a.Uplink == owned {
			return fmt.Sprintf("uplink %q is a Talos link managed by the other fabric", a.Uplink)
		}
	}
	for _, owned := range []string{a.VLANInterface, a.Bridge} {
		if owned != "" && b.Uplink == owned {
			return fmt.Sprintf("Talos managed link %q is used as the other fabric's uplink", b.Uplink)
		}
	}

	if a.Uplink == b.Uplink {
		if a.VLAN == 0 || b.VLAN == 0 {
			return fmt.Sprintf("physical uplink %q cannot be consumed by multiple native/untagged fabric networks", a.Uplink)
		}
		if a.VLAN == b.VLAN {
			return fmt.Sprintf("physical uplink %q VLAN %d is reserved by both fabrics", a.Uplink, a.VLAN)
		}
	}
	return ""
}
