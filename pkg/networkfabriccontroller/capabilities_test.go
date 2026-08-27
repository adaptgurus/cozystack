// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"strings"
	"testing"

	"github.com/cozystack/cozystack/pkg/networkfabric"
)

func TestCapabilityLabelKeyIsStableAndDataplaneSpecific(t *testing.T) {
	network := networkfabric.Network{Name: "prod", Bridge: "br-vlan120", VLAN: 120, MTU: 1500}
	first := CapabilityLabelKey("fabric-a", network)
	second := CapabilityLabelKey("fabric-a", network)
	if first != second {
		t.Fatalf("capability label is not stable: %q != %q", first, second)
	}
	if !strings.HasPrefix(first, capabilityLabelPrefix+"cap-") {
		t.Fatalf("unexpected label prefix: %q", first)
	}

	variants := []networkfabric.Network{
		{Name: "prod-2", Bridge: network.Bridge, VLAN: network.VLAN, MTU: network.MTU},
		{Name: network.Name, Bridge: "br-vlan121", VLAN: network.VLAN, MTU: network.MTU},
		{Name: network.Name, Bridge: network.Bridge, VLAN: 121, MTU: network.MTU},
		{Name: network.Name, Bridge: network.Bridge, VLAN: network.VLAN, MTU: 9000},
	}
	for _, variant := range variants {
		if got := CapabilityLabelKey("fabric-a", variant); got == first {
			t.Fatalf("dataplane change did not change capability label: %+v", variant)
		}
	}
	if got := CapabilityLabelKey("fabric-b", network); got == first {
		t.Fatal("different NetworkFabric names produced the same capability label")
	}
}
