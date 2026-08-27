// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"strings"
	"testing"

	"github.com/cozystack/cozystack/pkg/networkfabric"
)

func TestValidateReferenceSafetyBlocksReferencedNetworkRemoval(t *testing.T) {
	spec := networkfabric.Spec{Networks: []networkfabric.Network{{Name: "other", Bridge: "br-other"}}}
	refs := []FabricReference{{Namespace: "tenant-a", Name: "prod", FabricNetwork: "prod"}}
	if err := validateReferenceSafety(spec, nil, refs); err == nil || !strings.Contains(err.Error(), "cannot be removed") {
		t.Fatalf("expected referenced-network removal to be blocked, got %v", err)
	}
}

func TestValidateReferenceSafetyBlocksDataplaneAndPhysicalTopologyChange(t *testing.T) {
	desired := networkfabric.Network{Name: "prod", Uplink: "eth2", VLAN: 120, VLANInterface: "eth2.120", Bridge: "br-prod", MTU: 1500}
	spec := networkfabric.Spec{Networks: []networkfabric.Network{desired}}
	refs := []FabricReference{{Namespace: "tenant-a", Name: "prod", FabricNetwork: "prod", Bridge: "br-prod", VLAN: 120, MTU: 1500}}
	statuses := map[string]NodeStatus{
		"node-1": {AppliedNetworks: []networkfabric.Network{{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-prod", MTU: 1500}}},
	}
	if err := validateReferenceSafety(spec, statuses, refs); err == nil || !strings.Contains(err.Error(), "physical uplink/VLAN/bridge topology") {
		t.Fatalf("expected physical topology mutation to be blocked, got %v", err)
	}

	refs[0].VLAN = 121
	if err := validateReferenceSafety(spec, nil, refs); err == nil || !strings.Contains(err.Error(), "detach or migrate") {
		t.Fatalf("expected VMNetwork dataplane mismatch to be blocked, got %v", err)
	}
}

func TestOwnedNetworksUpgradeCompatibilityClaimsOnlyCurrentReadyGeneration(t *testing.T) {
	spec := networkfabric.Spec{Networks: []networkfabric.Network{{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-prod"}}}
	status := NodeStatus{Phase: "Ready", ObservedGeneration: 7}
	if got := ownedNetworks(status, spec, 7); len(got) != 1 || got[0].Name != "prod" {
		t.Fatalf("ownedNetworks current generation = %#v", got)
	}
	if got := ownedNetworks(status, spec, 8); len(got) != 0 {
		t.Fatalf("ownedNetworks stale generation = %#v, want none", got)
	}
}

func TestNetworkSetsEqualIsOrderIndependentAndTopologySensitive(t *testing.T) {
	a := []networkfabric.Network{{Name: "a", Bridge: "br-a"}, {Name: "b", Bridge: "br-b"}}
	b := []networkfabric.Network{{Name: "b", Bridge: "br-b"}, {Name: "a", Bridge: "br-a"}}
	if !networkSetsEqual(a, b) {
		t.Fatal("same networks in different order should compare equal")
	}
	b[1].Bridge = "br-a2"
	if networkSetsEqual(a, b) {
		t.Fatal("topology change should compare unequal")
	}
}
