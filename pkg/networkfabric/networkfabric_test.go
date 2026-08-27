// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func validSpec() Spec {
	return Spec{
		Provider:                      ProviderTalos,
		ProtectedManagementInterfaces: []string{"eth0"},
		Rollout:                       Rollout{MaxUnavailable: 1},
		Networks: []Network{
			{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-vlan120", MTU: 1500},
			{Name: "migration", Uplink: "eth2", VLAN: 130, VLANInterface: "eth2.130", Bridge: "br-migration", MTU: 9000, Migration: true},
		},
	}
}

func validState() NodeState {
	return NodeState{
		Name:                "node-1",
		ManagementReachable: true,
		Interfaces: map[string]InterfaceState{
			"eth0": {Name: "eth0", Up: true, MTU: 1500},
			"eth1": {Name: "eth1", Up: true, MTU: 1500},
			"eth2": {Name: "eth2", Up: true, MTU: 9000},
		},
	}
}

func TestValidateRejectsManagementReplacementAndUnsafeRollout(t *testing.T) {
	spec := validSpec()
	spec.Rollout.MaxUnavailable = 2
	spec.Networks[0].Bridge = "eth0"
	err := Validate(spec)
	if err == nil {
		t.Fatal("expected validation error")
	}
	for _, want := range []string{"cannot replace a protected management interface", "maxUnavailable must be 1"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("validation error %q does not contain %q", err, want)
		}
	}
}

func TestValidateRejectsNativeBridgeOverProtectedManagementUplink(t *testing.T) {
	spec := validSpec()
	spec.Networks = []Network{{Name: "native", Uplink: "eth0", Bridge: "br-native", VLAN: 0, MTU: 1500}}
	if err := Validate(spec); err == nil || !strings.Contains(err.Error(), "cannot be enslaved into a native bridge") {
		t.Fatalf("expected protected native-uplink rejection, got %v", err)
	}
}

func TestPlanForNodeBuildsVLANBeforeBridgeAndInverseDeletesBridgeBeforeVLAN(t *testing.T) {
	plan, err := PlanForNode(validSpec(), validState())
	if err != nil {
		t.Fatalf("PlanForNode: %v", err)
	}
	if len(plan.Operations) != 4 {
		t.Fatalf("operations = %d, want 4", len(plan.Operations))
	}
	for i := 0; i < len(plan.Operations); i += 2 {
		if plan.Operations[i].Kind != EnsureVLAN || plan.Operations[i+1].Kind != EnsureBridge {
			t.Fatalf("operation pair %d is not VLAN->bridge: %+v %+v", i/2, plan.Operations[i], plan.Operations[i+1])
		}
		if plan.Operations[i+1].Parent != plan.Operations[i].Name {
			t.Fatalf("bridge parent = %q, want %q", plan.Operations[i+1].Parent, plan.Operations[i].Name)
		}
	}
	if len(plan.RollbackOperations) != 4 {
		t.Fatalf("rollback operations = %#v", plan.RollbackOperations)
	}
	if plan.RollbackOperations[0].Kind != DeleteBridge || plan.RollbackOperations[1].Kind != DeleteBridge ||
		plan.RollbackOperations[2].Kind != DeleteVLAN || plan.RollbackOperations[3].Kind != DeleteVLAN {
		t.Fatalf("new-network inverse must delete bridges before VLANs: %#v", plan.RollbackOperations)
	}
}

func TestPlanForTransitionRefusesUnmanagedSameNamedLinks(t *testing.T) {
	spec := validSpec()
	spec.Networks = spec.Networks[:1]
	state := validState()
	state.Interfaces["br-vlan120"] = InterfaceState{Name: "br-vlan120", Kind: "bridge", Up: true, MTU: 1500}
	if _, err := PlanForTransition(spec, nil, state); err == nil || !strings.Contains(err.Error(), "refusing to adopt unmanaged Talos configuration") {
		t.Fatalf("expected unmanaged bridge adoption rejection, got %v", err)
	}

	delete(state.Interfaces, "br-vlan120")
	state.Interfaces["eth1.120"] = InterfaceState{Name: "eth1.120", Kind: "vlan", Up: true, MTU: 1500, VLAN: 120, Parent: "eth1"}
	if _, err := PlanForTransition(spec, nil, state); err == nil || !strings.Contains(err.Error(), "refusing to adopt unmanaged Talos configuration") {
		t.Fatalf("expected unmanaged VLAN adoption rejection, got %v", err)
	}
}

func TestPlanForTransitionInverseRestoresChangedOwnedTopology(t *testing.T) {
	previous := []Network{{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-prod", MTU: 1500}}
	spec := Spec{
		Provider:                      ProviderTalos,
		ProtectedManagementInterfaces: []string{"eth0"},
		Rollout:                       Rollout{MaxUnavailable: 1},
		Networks:                      []Network{{Name: "prod", Uplink: "eth2", VLAN: 220, VLANInterface: "eth2.220", Bridge: "br-prod", MTU: 9000}},
	}
	state := NodeState{Name: "node-1", ManagementReachable: true, Interfaces: map[string]InterfaceState{
		"eth0":     {Name: "eth0", Up: true, MTU: 1500},
		"eth1":     {Name: "eth1", Up: true, MTU: 1500},
		"eth2":     {Name: "eth2", Up: true, MTU: 9000},
		"eth1.120": {Name: "eth1.120", Kind: "vlan", Up: true, MTU: 1500, VLAN: 120, Parent: "eth1"},
		"br-prod":  {Name: "br-prod", Kind: "bridge", Up: true, MTU: 1500, Members: []string{"eth1.120"}},
	}}
	plan, err := PlanForTransition(spec, previous, state)
	if err != nil {
		t.Fatalf("PlanForTransition: %v", err)
	}
	rollback, err := RenderTalosPatch(plan.RollbackOperations)
	if err != nil {
		t.Fatalf("render rollback: %v", err)
	}
	text := string(rollback)
	for _, want := range []string{"kind: VLANConfig\nname: eth1.120", "vlanID: 120", "parent: eth1", "kind: BridgeConfig\nname: br-prod", "  - eth1.120", "kind: VLANConfig\nname: eth2.220\n$patch: delete"} {
		if !strings.Contains(text, want) {
			t.Fatalf("inverse patch missing %q:\n%s", want, text)
		}
	}
}

func TestPlanForNodeFailsClosedWhenManagementIsAlreadyUnhealthy(t *testing.T) {
	state := validState()
	state.ManagementReachable = false
	if _, err := PlanForNode(validSpec(), state); err == nil || !strings.Contains(err.Error(), "management connectivity is not healthy") {
		t.Fatalf("expected unhealthy-management preflight failure, got %v", err)
	}
}

type fakeTalosAdapter struct {
	state       NodeState
	applyErr    error
	verifyErr   error
	confirmErr  error
	rollbackErr error
	applied     bool
	verified    bool
	confirmed   bool
	rolledBack  bool
}

func (f *fakeTalosAdapter) Inspect(context.Context, string) (NodeState, error) { return f.state, nil }
func (f *fakeTalosAdapter) Apply(context.Context, string, []Operation, []Operation) (ApplyReceipt, error) {
	f.applied = true
	if f.applyErr != nil {
		return ApplyReceipt{}, f.applyErr
	}
	return ApplyReceipt{Revision: "txn-before-change", Patch: []byte("kind: BridgeConfig"), RollbackPatch: []byte("kind: BridgeConfig\n$patch: delete")}, nil
}
func (f *fakeTalosAdapter) VerifyManagement(context.Context, string, []string) error {
	f.verified = true
	return f.verifyErr
}
func (f *fakeTalosAdapter) Confirm(context.Context, string, ApplyReceipt) error {
	f.confirmed = true
	return f.confirmErr
}
func (f *fakeTalosAdapter) Rollback(context.Context, string, ApplyReceipt) error {
	f.rolledBack = true
	return f.rollbackErr
}

func TestOrchestratorConfirmsOnlyAfterManagementVerification(t *testing.T) {
	adapter := &fakeTalosAdapter{state: validState()}
	if err := (Orchestrator{Adapter: adapter}).ReconcileNode(context.Background(), validSpec(), "node-1"); err != nil {
		t.Fatalf("ReconcileNode: %v", err)
	}
	if !adapter.applied || !adapter.verified || !adapter.confirmed || adapter.rolledBack {
		t.Fatalf("transaction calls: applied=%v verified=%v confirmed=%v rolledBack=%v", adapter.applied, adapter.verified, adapter.confirmed, adapter.rolledBack)
	}
}

func TestOrchestratorRollsBackOnManagementVerificationFailure(t *testing.T) {
	adapter := &fakeTalosAdapter{state: validState(), verifyErr: errors.New("API endpoint unreachable")}
	err := (Orchestrator{Adapter: adapter}).ReconcileNode(context.Background(), validSpec(), "node-1")
	if err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("expected rollback error result, got %v", err)
	}
	if !adapter.applied || !adapter.verified || adapter.confirmed || !adapter.rolledBack {
		t.Fatalf("transaction calls: applied=%v verified=%v confirmed=%v rolledBack=%v", adapter.applied, adapter.verified, adapter.confirmed, adapter.rolledBack)
	}
}

func TestRenderTalosPatchUsesModernVLANAndBridgeDocuments(t *testing.T) {
	plan, err := PlanForNode(validSpec(), validState())
	if err != nil {
		t.Fatal(err)
	}
	patch, err := RenderTalosPatch(plan.Operations)
	if err != nil {
		t.Fatal(err)
	}
	text := string(patch)
	for _, want := range []string{"kind: VLANConfig", "vlanID: 120", "parent: eth1", "kind: BridgeConfig", "name: br-vlan120", "  - eth1.120"} {
		if !strings.Contains(text, want) {
			t.Fatalf("patch missing %q:\n%s", want, text)
		}
	}
}
