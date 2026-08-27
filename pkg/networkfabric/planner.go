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
// desired spec. Existing same-named links that were not previously owned are
// rejected rather than adopted, because adopting them would make later cleanup
// capable of deleting an operator-managed Talos resource.
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

	previousBridges := networkByBridge(previous)
	previousVLANs := networkByVLANInterface(previous)
	for _, network := range spec.Networks {
		if _, exists := state.Interfaces[network.Bridge]; exists {
			if _, owned := previousBridges[network.Bridge]; !owned {
				return Plan{}, fmt.Errorf("node %q already has bridge %q required by network %q, but it is not recorded as NetworkFabric-owned; refusing to adopt unmanaged Talos configuration", state.Name, network.Bridge, network.Name)
			}
		}
		if network.VLAN > 0 {
			if _, exists := state.Interfaces[network.VLANInterface]; exists {
				if _, owned := previousVLANs[network.VLANInterface]; !owned {
					return Plan{}, fmt.Errorf("node %q already has VLAN interface %q required by network %q, but it is not recorded as NetworkFabric-owned; refusing to adopt unmanaged Talos configuration", state.Name, network.VLANInterface, network.Name)
				}
			}
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

	previousSorted := sortedNetworks(previous)
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

	networks := sortedNetworks(spec.Networks)
	for _, network := range networks {
		uplink, ok := state.Interfaces[network.Uplink]
		if !ok {
			return Plan{}, fmt.Errorf("node %q is missing uplink %q required by network %q", state.Name, network.Uplink, network.Name)
		}
		if !uplink.Up {
			return Plan{}, fmt.Errorf("node %q uplink %q required by network %q is down", state.Name, network.Uplink, network.Name)
		}
		if network.MTU > 0 {
			if uplink.MTU <= 0 {
				return Plan{}, fmt.Errorf("node %q uplink %q MTU is unknown; cannot prove requested MTU %d for network %q", state.Name, network.Uplink, network.MTU, network.Name)
			}
			if uplink.MTU < network.MTU {
				return Plan{}, fmt.Errorf("node %q uplink %q MTU %d cannot carry requested MTU %d for network %q", state.Name, network.Uplink, uplink.MTU, network.MTU, network.Name)
			}
		}
		if master := unrelatedMaster(state, network.Uplink, previousBridges); master != "" {
			return Plan{}, fmt.Errorf("node %q uplink %q required by network %q is already a member of unmanaged interface %q; refusing destructive takeover", state.Name, network.Uplink, network.Name, master)
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
	plan.RollbackOperations = buildRollbackOperations(previous, spec.Networks)
	return plan, nil
}

func unrelatedMaster(state NodeState, uplink string, previousBridges map[string]Network) string {
	for name, link := range state.Interfaces {
		for _, member := range link.Members {
			if member != uplink {
				continue
			}
			if _, owned := previousBridges[name]; owned {
				return ""
			}
			return name
		}
	}
	return ""
}

// buildRollbackOperations creates an exact inverse for only the Talos
// VLANConfig/BridgeConfig documents owned by NetworkFabric. It intentionally
// never snapshots or reapplies the complete machine configuration.
func buildRollbackOperations(previous, desired []Network) []Operation {
	previousBridges := networkByBridge(previous)
	previousVLANs := networkByVLANInterface(previous)

	var operations []Operation

	// Reassert every previously owned VLAN definition first. Even when the desired
	// definition is unchanged, this gives an explicit owned inverse for a repair
	// transaction and avoids ever falling back to a whole-machine snapshot.
	for _, network := range sortedNetworks(previous) {
		if network.VLAN <= 0 || network.VLANInterface == "" {
			continue
		}
		operations = append(operations, ensureVLANOperation(network))
	}

	// Reassert every previously owned bridge definition next. This also detaches
	// any newly introduced VLAN from a same-named bridge before the VLAN is
	// deleted below.
	for _, network := range sortedNetworks(previous) {
		operations = append(operations, ensureBridgeOperation(network))
	}

	// Remove newly introduced bridges before their child VLANs.
	for _, network := range sortedNetworks(desired) {
		if _, existed := previousBridges[network.Bridge]; !existed {
			operations = append(operations, Operation{Kind: DeleteBridge, Name: network.Bridge, NetworkRef: network.Name})
		}
	}
	for _, network := range sortedNetworks(desired) {
		if network.VLAN <= 0 || network.VLANInterface == "" {
			continue
		}
		if _, existed := previousVLANs[network.VLANInterface]; !existed {
			operations = append(operations, Operation{Kind: DeleteVLAN, Name: network.VLANInterface, NetworkRef: network.Name})
		}
	}
	return operations
}

func ensureVLANOperation(network Network) Operation {
	return Operation{Kind: EnsureVLAN, Name: network.VLANInterface, Parent: network.Uplink, VLAN: network.VLAN, MTU: network.MTU, NetworkRef: network.Name}
}

func ensureBridgeOperation(network Network) Operation {
	return Operation{Kind: EnsureBridge, Name: network.Bridge, Parent: bridgeParent(network), MTU: network.MTU, NetworkRef: network.Name}
}

func bridgeParent(network Network) string {
	if network.VLAN > 0 {
		return network.VLANInterface
	}
	return network.Uplink
}

func networkByBridge(networks []Network) map[string]Network {
	out := make(map[string]Network, len(networks))
	for _, network := range networks {
		if network.Bridge != "" {
			out[network.Bridge] = network
		}
	}
	return out
}

func networkByVLANInterface(networks []Network) map[string]Network {
	out := make(map[string]Network, len(networks))
	for _, network := range networks {
		if network.VLAN > 0 && network.VLANInterface != "" {
			out[network.VLANInterface] = network
		}
	}
	return out
}

func sortedNetworks(networks []Network) []Network {
	out := append([]Network(nil), networks...)
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// Orchestrator owns the safety transaction around one Talos node. The adapter
// first applies the change in Talos try mode. Only after management and optional
// physical-topology verification succeed is the change confirmed; otherwise an
// inverse patch affecting only controller-owned network documents is attempted
// immediately and Talos' try timeout remains a second safety net.
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
	receipt, err := o.Adapter.Apply(ctx, node, plan.Operations, plan.RollbackOperations)
	if err != nil {
		return ApplyReceipt{}, fmt.Errorf("apply Talos network plan to node %q: %w", node, err)
	}
	if receipt.Revision == "" {
		return ApplyReceipt{}, fmt.Errorf("Talos adapter returned an empty transaction revision for node %q", node)
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
