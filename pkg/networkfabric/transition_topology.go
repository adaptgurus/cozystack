// SPDX-License-Identifier: Apache-2.0

package networkfabric

import "fmt"

// ValidateTransitionTopology proves both sides of a NetworkFabric transition:
// every desired network has the exact requested live topology, and every
// previously owned bridge/VLAN document which is no longer desired is absent.
// It is safe for create, update, selector cleanup and finalizer cleanup.
func ValidateTransitionTopology(state NodeState, previous, desired []Network) error {
	for _, network := range desired {
		if err := ValidateNetworkTopology(state, network); err != nil {
			return err
		}
	}

	desiredBridges := make(map[string]struct{}, len(desired))
	desiredVLANs := make(map[string]struct{}, len(desired))
	for _, network := range desired {
		if network.Bridge != "" {
			desiredBridges[network.Bridge] = struct{}{}
		}
		if network.VLAN > 0 && network.VLANInterface != "" {
			desiredVLANs[network.VLANInterface] = struct{}{}
		}
	}

	for _, network := range previous {
		if network.Bridge != "" {
			if _, keep := desiredBridges[network.Bridge]; !keep {
				if _, exists := state.Interfaces[network.Bridge]; exists {
					return fmt.Errorf("node %s still exposes stale bridge %s for network %s", state.Name, network.Bridge, network.Name)
				}
			}
		}
		if network.VLAN > 0 && network.VLANInterface != "" {
			if _, keep := desiredVLANs[network.VLANInterface]; !keep {
				if _, exists := state.Interfaces[network.VLANInterface]; exists {
					return fmt.Errorf("node %s still exposes stale VLAN interface %s for network %s", state.Name, network.VLANInterface, network.Name)
				}
			}
		}
	}

	return nil
}
