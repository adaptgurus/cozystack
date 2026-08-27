// SPDX-License-Identifier: Apache-2.0

package networkfabriccontroller

import (
	"strings"
	"testing"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func TestCrossFabricOwnershipRejectsManagedLinkCollisionOnOverlappingNodes(t *testing.T) {
	current := networkfabric.Spec{
		Provider:     networkfabric.ProviderTalos,
		NodeSelector: map[string]string{"hci": "true"},
		Rollout:      networkfabric.Rollout{MaxUnavailable: 1},
		Networks: []networkfabric.Network{{
			Name: "prod", Uplink: "bond1", VLAN: 120, VLANInterface: "bond1.120", Bridge: "br-vm-120", MTU: 1500,
		}},
	}
	peer := current
	peer.Networks = []networkfabric.Network{{Name: "other", Uplink: "bond2", VLAN: 220, VLANInterface: "bond2.220", Bridge: "br-vm-120", MTU: 1500}}
	nodes := []corev1.Node{{ObjectMeta: metav1.ObjectMeta{Name: "node-a", Labels: map[string]string{"hci": "true"}}}}

	err := validateCrossFabricOwnership("fabric-a", current, []namedFabricSpec{{Name: "fabric-b", Spec: peer}}, nodes)
	if err == nil || !strings.Contains(err.Error(), `managed Talos link "br-vm-120"`) {
		t.Fatalf("expected managed-link collision, got %v", err)
	}
}

func TestCrossFabricOwnershipAllowsDifferentVLANsOnSharedTrunk(t *testing.T) {
	base := networkfabric.Spec{Provider: networkfabric.ProviderTalos, NodeSelector: map[string]string{"hci": "true"}, Rollout: networkfabric.Rollout{MaxUnavailable: 1}}
	current := base
	current.Networks = []networkfabric.Network{{Name: "prod", Uplink: "bond1", VLAN: 120, VLANInterface: "bond1.120", Bridge: "br-vm-120", MTU: 1500}}
	peer := base
	peer.Networks = []networkfabric.Network{{Name: "backup", Uplink: "bond1", VLAN: 300, VLANInterface: "bond1.300", Bridge: "br-vm-300", MTU: 1500}}
	nodes := []corev1.Node{{ObjectMeta: metav1.ObjectMeta{Name: "node-a", Labels: map[string]string{"hci": "true"}}}}

	if err := validateCrossFabricOwnership("fabric-a", current, []namedFabricSpec{{Name: "fabric-b", Spec: peer}}, nodes); err != nil {
		t.Fatalf("different VLANs on the same physical trunk must be allowed, got %v", err)
	}
}

func TestCrossFabricOwnershipIgnoresPhysicalCollisionOnDisjointNodes(t *testing.T) {
	base := networkfabric.Spec{Provider: networkfabric.ProviderTalos, Rollout: networkfabric.Rollout{MaxUnavailable: 1}}
	current := base
	current.NodeSelector = map[string]string{"pool": "a"}
	current.Networks = []networkfabric.Network{{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-vm-120", MTU: 1500}}
	peer := base
	peer.NodeSelector = map[string]string{"pool": "b"}
	peer.Networks = []networkfabric.Network{{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-vm-120", MTU: 1500}}
	nodes := []corev1.Node{
		{ObjectMeta: metav1.ObjectMeta{Name: "node-a", Labels: map[string]string{"pool": "a"}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "node-b", Labels: map[string]string{"pool": "b"}}},
	}

	if err := validateCrossFabricOwnership("fabric-a", current, []namedFabricSpec{{Name: "fabric-b", Spec: peer}}, nodes); err != nil {
		t.Fatalf("disjoint node selectors should not conflict physically, got %v", err)
	}
}

func TestCrossFabricOwnershipRejectsDuplicateMigrationFabric(t *testing.T) {
	base := networkfabric.Spec{Provider: networkfabric.ProviderTalos, Rollout: networkfabric.Rollout{MaxUnavailable: 1}}
	current := base
	current.NodeSelector = map[string]string{"pool": "a"}
	current.Networks = []networkfabric.Network{{Name: "migration-a", Uplink: "eth1", VLAN: 400, VLANInterface: "eth1.400", Bridge: "br-mig-a", MTU: 9000, Migration: true}}
	peer := base
	peer.NodeSelector = map[string]string{"pool": "b"}
	peer.Networks = []networkfabric.Network{{Name: "migration-b", Uplink: "eth2", VLAN: 401, VLANInterface: "eth2.401", Bridge: "br-mig-b", MTU: 9000, Migration: true}}
	nodes := []corev1.Node{
		{ObjectMeta: metav1.ObjectMeta{Name: "node-a", Labels: map[string]string{"pool": "a"}}},
		{ObjectMeta: metav1.ObjectMeta{Name: "node-b", Labels: map[string]string{"pool": "b"}}},
	}

	err := validateCrossFabricOwnership("fabric-a", current, []namedFabricSpec{{Name: "fabric-b", Spec: peer}}, nodes)
	if err == nil || !strings.Contains(err.Error(), "more than one fabric declares a dedicated migration network") {
		t.Fatalf("expected migration identity collision, got %v", err)
	}
}

func TestPhysicalOwnershipConflictRejectsSameUplinkAndVLANDespiteDifferentNames(t *testing.T) {
	a := networkfabric.Network{Name: "a", Uplink: "bond1", VLAN: 120, VLANInterface: "vlan-a", Bridge: "br-a"}
	b := networkfabric.Network{Name: "b", Uplink: "bond1", VLAN: 120, VLANInterface: "vlan-b", Bridge: "br-b"}
	if got := physicalOwnershipConflict(a, b); !strings.Contains(got, "VLAN 120") {
		t.Fatalf("same physical VLAN must conflict even with different generated names, got %q", got)
	}
}
