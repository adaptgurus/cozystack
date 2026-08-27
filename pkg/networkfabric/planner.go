// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"context"
	"fmt"
	"sort"
)

// PlanForNode converts cluster-level NetworkFabric intent into idempotent Talos
// adapter operations for one node. It performs live preflight against the node
// state but does not execute any change.
func PlanForNode(spec Spec, state NodeState) (Plan, error) {
	return PlanForTransition(spec, nil, state)
}

// PlanForTransition reconciles a previously controller-owned topology to the
// current desired topology. Stale documents are deleted only when their exact
// kind/name was recorded as controller-owned and is no longer present in the
// desired spec. This prevents cleanup from deleting unmanaged Talos links.
func PlanForTransition(spec Spec, previous []Network, state NodeState) (Plan, error) {
	if err := Validate(spec); err != nil {
		return Plan{}, err
	}
	if state.Name == "" {
		return Plan{}, fmt.Errorf("node state name is required")
	}
	if !state.ManagementReachable {
		return Plan{}, fmt.Errorf("node %q management connectivity is not healthy before network change", state.Name)
	}
	for _, protected := range spec.ProtectedManagementInterfaces {
		link, ok := state.Interfaces[protected]
		if !ok {
			return Plan{}, fmt.Errorf("node %q is missing protected management interface %q", state.Name, protected)
		}
		if !link.Up {
			return Plan{}, fmt.Errorf("node %q protected management interface %q is down", state.Name, protected)
		}
	}

	plan := Plan{Node: state.Name}
	desiredBridges := map[string]struct{}{}
	desiredVLANs := map[string]struct{}{}
	for _, network := range spec.Networks {
		desiredBridges[network.Bridge] = struct{}{}
		if network.VLAN > 0 {
			desiredVLANs[network.VLANInterface] = struct{}{}
		}
	}

	previousSorted := append([]Network(nil), previous...)
	sort.Slice(previousSorted, func(i, j int) bool { return previousSorted[i].Name < previousSorted[j].Name })
	seenDeleteBridge := map[string]struct{}{}
	seenDeleteVLAN := map[string]struct{}{}
	for _, network := range previousSorted {
		if _, keep := desiredBridges[network.Bridge]; !keep && network.Bridge != "" {
			if _, seen := seenDeleteBridge[network.Bridge]; !seen {
				plan.Operations = append(plan.Operations, Operation{Kind: DeleteBridge, Name: network.Bridge, NetworkRef: network.Name})
				seenDeleteBridge[network.Bridge] = struct{}{}
			}
		}
	}
	for _, network := range previousSorted {
		if network.VLAN <= 0 || network.VLANInterface == "" {
			continue
		}
		if _, keep := desiredVLANs[network.VLANInterface]; !keep {
			if _, seen := seenDeleteVLAN[network.VLANInterface]; !seen {
				plan.Operations = append(plan.Operations, Operation{Kind: DeleteVLAN, Name: network.VLANInterface, NetworkRef: network.Name})
				seenDeleteVLAN[network.VLANInterface] = struct{}{}
			}
		}
	}

	networks := append([]Network(nil), spec.Networks...)
	sort.Slice(networks, func(i, j int) bool { return networks[i].Name < networks[j].Name })
	for _, network := range networks {
		if _, ok := state.Interfaces[network.Uplink]; !ok {
			return Plan{}, fmt.Errorf("node %q is missing uplink %q required by network %q", state.Name, network.Uplink, network.Name)
		}
		parent := network.Uplink
		if network.VLAN > 0 {
			plan.Operations = append(plan.Operations, Operation{
				Kind:       EnsureVLAN,
				Name:       network.VLANInterface,
				Parent:     network.Uplink,
				VLAN:       network.VLAN,
				MTU:        network.MTU,
				NetworkRef: network.Name,
			})
			parent = network.VLANInterface
		}
		plan.Operations = append(plan.Operations, Operation{
			Kind:       EnsureBridge,
			Name:       network.Bridge,
			Parent:     parent,
			MTU:        network.MTU,
			NetworkRef: network.Name,
		})
	}
	return plan, nil
}

// Orchestrator owns the safety transaction around one Talos node. The adapter
// first applies the change in Talos try mode. Only after management and optional
// physical-topology verification succeed is the change confirmed; otherwise
// rollback is attempted immediately and Talos' try timeout remains a second net.
type Orchestrator struct {
	Adapter TalosAdapter
}

func (o Orchestrator) ReconcileNode(ctx context.Context, spec Spec, node string) error {
	_, err := o.ReconcileNodeTransition(ctx, spec, nil, node)
	return err
}

func (o Orchestrator) ReconcileNodeTransition(ctx context.Context, spec Spec, previous []Network, node string) (ApplyReceipt, error) {
	return o.ReconcileNodeTransitionValidated(ctx, spec, previous, node, nil)
}

// ReconcileNodeTransitionValidated keeps the post-apply topology check inside
// Talos try mode. A patch that leaves management reachable but wires the wrong
// VLAN/bridge topology is rolled back before Confirm is attempted.
func (o Orchestrator) ReconcileNodeTransitionValidated(ctx context.Context, spec Spec, previous []Network, node string, validate func(NodeState) error) (ApplyReceipt, error) {
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
	receipt, err := o.Adapter.Apply(ctx, node, plan.Operations)
	if err != nil {
		return ApplyReceipt{}, fmt.Errorf("apply Talos network plan to node %q: %w", node, err)
	}
	if receipt.Revision == "" {
		return ApplyReceipt{}, fmt.Errorf("Talos adapter returned an empty rollback revision for node %q", node)
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
	if err := o.Adapter.Confirm(ctx, node, receipt); err != nil {
		return receipt, rollbackFailure(ctx, o.Adapter, node, receipt, "failed to confirm network configuration", err)
	}
	return receipt, nil
}

func rollbackFailure(ctx context.Context, adapter TalosAdapter, node string, receipt ApplyReceipt, stage string, cause error) error {
	rollbackErr := adapter.Rollback(ctx, node, receipt)
	if rollbackErr != nil {
		return fmt.Errorf("%s on node %q: %v; rollback to revision %q also failed: %w", stage, node, cause, receipt.Revision, rollbackErr)
	}
	return fmt.Errorf("%s on node %q; rolled back to revision %q: %w", stage, node, receipt.Revision, cause)
}
