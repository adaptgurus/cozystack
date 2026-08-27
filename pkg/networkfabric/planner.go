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
		if _, ok := state.Interfaces[protected]; !ok {
			return Plan{}, fmt.Errorf("node %q is missing protected management interface %q", state.Name, protected)
		}
	}

	networks := append([]Network(nil), spec.Networks...)
	sort.Slice(networks, func(i, j int) bool { return networks[i].Name < networks[j].Name })
	plan := Plan{Node: state.Name}
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

// Orchestrator owns the safety transaction around one Talos node. Any failure
// of post-apply management verification triggers rollback before the node can
// be considered reconciled. Cluster rollout sequencing remains a controller
// concern above this type.
type Orchestrator struct {
	Adapter TalosAdapter
}

func (o Orchestrator) ReconcileNode(ctx context.Context, spec Spec, node string) error {
	if o.Adapter == nil {
		return fmt.Errorf("Talos adapter is required")
	}
	state, err := o.Adapter.Inspect(ctx, node)
	if err != nil {
		return fmt.Errorf("inspect Talos node %q: %w", node, err)
	}
	plan, err := PlanForNode(spec, state)
	if err != nil {
		return err
	}
	receipt, err := o.Adapter.Apply(ctx, node, plan.Operations)
	if err != nil {
		return fmt.Errorf("apply Talos network plan to node %q: %w", node, err)
	}
	if receipt.Revision == "" {
		return fmt.Errorf("Talos adapter returned an empty rollback revision for node %q", node)
	}
	if err := o.Adapter.VerifyManagement(ctx, node, spec.ProtectedManagementInterfaces); err != nil {
		rollbackErr := o.Adapter.Rollback(ctx, node, receipt)
		if rollbackErr != nil {
			return fmt.Errorf("management verification failed on node %q: %v; rollback to revision %q also failed: %w", node, err, receipt.Revision, rollbackErr)
		}
		return fmt.Errorf("management verification failed on node %q after network apply; rolled back to revision %q: %w", node, receipt.Revision, err)
	}
	return nil
}
