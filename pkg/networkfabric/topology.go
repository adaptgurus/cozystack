// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"fmt"
	"strings"
)

// ValidateNetworkTopology proves that the live Talos link graph implements one
// NetworkFabric network exactly. A same-named bridge is insufficient: tagged
// networks must have the requested VLAN ID on the requested uplink, and the
// bridge must contain that VLAN link. Native networks must bridge the requested
// uplink directly.
func ValidateNetworkTopology(state NodeState, network Network) error {
	uplink, ok := state.Interfaces[network.Uplink]
	if !ok {
		return fmt.Errorf("node %s is missing uplink %s for network %s", state.Name, network.Uplink, network.Name)
	}
	if !uplink.Up {
		return fmt.Errorf("node %s uplink %s is down for network %s", state.Name, network.Uplink, network.Name)
	}

	member := network.Uplink
	if network.VLAN > 0 {
		vlan, ok := state.Interfaces[network.VLANInterface]
		if !ok {
			return fmt.Errorf("node %s is missing VLAN interface %s for network %s", state.Name, network.VLANInterface, network.Name)
		}
		if !strings.EqualFold(vlan.Kind, "vlan") {
			return fmt.Errorf("node %s interface %s has kind %q, expected vlan", state.Name, network.VLANInterface, vlan.Kind)
		}
		if vlan.VLAN != network.VLAN {
			return fmt.Errorf("node %s VLAN interface %s has VLAN ID %d, expected %d", state.Name, network.VLANInterface, vlan.VLAN, network.VLAN)
		}
		if vlan.Parent != network.Uplink {
			return fmt.Errorf("node %s VLAN interface %s parent is %q, expected %q", state.Name, network.VLANInterface, vlan.Parent, network.Uplink)
		}
		if !vlan.Up {
			return fmt.Errorf("node %s VLAN interface %s is down", state.Name, network.VLANInterface)
		}
		if network.MTU > 0 && vlan.MTU > 0 && vlan.MTU != network.MTU {
			return fmt.Errorf("node %s VLAN interface %s MTU %d does not match required MTU %d", state.Name, network.VLANInterface, vlan.MTU, network.MTU)
		}
		member = network.VLANInterface
	}

	bridge, ok := state.Interfaces[network.Bridge]
	if !ok {
		return fmt.Errorf("node %s is missing bridge %s for network %s", state.Name, network.Bridge, network.Name)
	}
	if !strings.EqualFold(bridge.Kind, "bridge") {
		return fmt.Errorf("node %s interface %s has kind %q, expected bridge", state.Name, network.Bridge, bridge.Kind)
	}
	if !bridge.Up {
		return fmt.Errorf("node %s bridge %s is down", state.Name, network.Bridge)
	}
	if network.MTU > 0 && bridge.MTU > 0 && bridge.MTU != network.MTU {
		return fmt.Errorf("node %s bridge %s MTU %d does not match required MTU %d", state.Name, network.Bridge, bridge.MTU, network.MTU)
	}
	if !containsString(bridge.Members, member) {
		return fmt.Errorf("node %s bridge %s does not contain required member %s", state.Name, network.Bridge, member)
	}

	return nil
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
