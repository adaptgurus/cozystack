// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestParseTalosLinksResolvesVLANParentAndBridgeMembers(t *testing.T) {
	raw := []byte(`{"metadata":{"id":"eth1"},"spec":{"index":2,"mtu":1500,"operationalState":"up","linkState":true}}
{"metadata":{"id":"eth1.120"},"spec":{"index":3,"kind":"vlan","linkIndex":2,"masterIndex":4,"mtu":1500,"operationalState":"up","vlan":{"vlanID":120}}}
{"metadata":{"id":"br-vlan120"},"spec":{"index":4,"kind":"bridge","mtu":1500,"operationalState":"up"}}
`)

	links, err := parseTalosLinks(raw)
	if err != nil {
		t.Fatalf("parseTalosLinks: %v", err)
	}
	vlan := links["eth1.120"]
	if vlan.Kind != "vlan" || vlan.Parent != "eth1" || vlan.VLAN != 120 || !vlan.Up {
		t.Fatalf("resolved VLAN = %+v", vlan)
	}
	bridge := links["br-vlan120"]
	if bridge.Kind != "bridge" || len(bridge.Members) != 1 || bridge.Members[0] != "eth1.120" {
		t.Fatalf("resolved bridge = %+v", bridge)
	}
}

func TestValidateNetworkTopologyRejectsWrongVLANAndBridgeMembership(t *testing.T) {
	network := Network{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-vlan120", MTU: 1500}
	state := NodeState{Name: "node-1", ManagementReachable: true, Interfaces: map[string]InterfaceState{
		"eth1":       {Name: "eth1", Index: 2, Up: true, MTU: 1500},
		"eth1.120":   {Name: "eth1.120", Kind: "vlan", Index: 3, Parent: "eth1", VLAN: 121, Up: true, MTU: 1500},
		"br-vlan120": {Name: "br-vlan120", Kind: "bridge", Index: 4, Members: []string{"eth1.120"}, Up: true, MTU: 1500},
	}}
	if err := ValidateNetworkTopology(state, network); err == nil || !strings.Contains(err.Error(), "VLAN ID 121") {
		t.Fatalf("expected VLAN mismatch, got %v", err)
	}

	vlan := state.Interfaces["eth1.120"]
	vlan.VLAN = 120
	state.Interfaces["eth1.120"] = vlan
	bridge := state.Interfaces["br-vlan120"]
	bridge.Members = []string{"other.120"}
	state.Interfaces["br-vlan120"] = bridge
	if err := ValidateNetworkTopology(state, network); err == nil || !strings.Contains(err.Error(), "does not contain required member") {
		t.Fatalf("expected bridge membership mismatch, got %v", err)
	}
}

func TestValidateNetworkTopologyFailsClosedOnUnknownOrTooSmallMTU(t *testing.T) {
	network := Network{Name: "prod", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-vlan120", MTU: 9000}
	state := NodeState{Name: "node-1", ManagementReachable: true, Interfaces: map[string]InterfaceState{
		"eth1":       {Name: "eth1", Up: true, MTU: 1500},
		"eth1.120":   {Name: "eth1.120", Kind: "vlan", Parent: "eth1", VLAN: 120, Up: true, MTU: 9000},
		"br-vlan120": {Name: "br-vlan120", Kind: "bridge", Members: []string{"eth1.120"}, Up: true, MTU: 9000},
	}}
	if err := ValidateNetworkTopology(state, network); err == nil || !strings.Contains(err.Error(), "smaller than required network MTU") {
		t.Fatalf("expected uplink MTU rejection, got %v", err)
	}
	uplink := state.Interfaces["eth1"]
	uplink.MTU = 0
	state.Interfaces["eth1"] = uplink
	if err := ValidateNetworkTopology(state, network); err == nil || !strings.Contains(err.Error(), "MTU is unavailable") {
		t.Fatalf("expected unknown uplink MTU rejection, got %v", err)
	}
}

func TestPlanForTransitionDeletesOnlyStaleOwnedDocuments(t *testing.T) {
	previous := []Network{
		{Name: "old", Uplink: "eth1", VLAN: 120, VLANInterface: "eth1.120", Bridge: "br-old", MTU: 1500},
		{Name: "keep", Uplink: "eth2", VLAN: 130, VLANInterface: "eth2.130", Bridge: "br-keep", MTU: 1500},
	}
	spec := Spec{
		Provider:                      ProviderTalos,
		ProtectedManagementInterfaces: []string{"eth0"},
		Rollout:                       Rollout{MaxUnavailable: 1},
		Networks: []Network{
			{Name: "keep", Uplink: "eth2", VLAN: 130, VLANInterface: "eth2.130", Bridge: "br-keep", MTU: 1500},
		},
	}
	state := NodeState{Name: "node-1", ManagementReachable: true, Interfaces: map[string]InterfaceState{
		"eth0":     {Name: "eth0", Up: true},
		"eth1":     {Name: "eth1", Up: true},
		"eth2":     {Name: "eth2", Up: true},
		"eth1.120": {Name: "eth1.120", Kind: "vlan", Up: true},
		"br-old":   {Name: "br-old", Kind: "bridge", Up: true},
		"eth2.130": {Name: "eth2.130", Kind: "vlan", Up: true},
		"br-keep":  {Name: "br-keep", Kind: "bridge", Up: true},
	}}
	plan, err := PlanForTransition(spec, previous, state)
	if err != nil {
		t.Fatalf("PlanForTransition: %v", err)
	}
	if len(plan.Operations) != 4 {
		t.Fatalf("operations = %#v", plan.Operations)
	}
	if plan.Operations[0].Kind != DeleteBridge || plan.Operations[0].Name != "br-old" {
		t.Fatalf("first operation = %+v, want stale bridge delete", plan.Operations[0])
	}
	if plan.Operations[1].Kind != DeleteVLAN || plan.Operations[1].Name != "eth1.120" {
		t.Fatalf("second operation = %+v, want stale VLAN delete", plan.Operations[1])
	}
	for _, op := range plan.Operations {
		if (op.Kind == DeleteBridge && op.Name == "br-keep") || (op.Kind == DeleteVLAN && op.Name == "eth2.130") {
			t.Fatalf("desired document was scheduled for deletion: %+v", op)
		}
	}
	patch, err := RenderTalosPatch(plan.Operations[:2])
	if err != nil {
		t.Fatal(err)
	}
	text := string(patch)
	if strings.Count(text, "$patch: delete") != 2 || strings.Index(text, "kind: BridgeConfig") > strings.Index(text, "kind: VLANConfig") {
		t.Fatalf("unexpected cleanup patch:\n%s", text)
	}
	rollback, err := RenderTalosPatch(plan.RollbackOperations)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rollback), "kind: VLANConfig\nname: eth1.120") || !strings.Contains(string(rollback), "kind: BridgeConfig\nname: br-old") {
		t.Fatalf("cleanup inverse does not restore stale-owned documents:\n%s", rollback)
	}
}

type scriptedRunner struct {
	calls     [][]string
	responses [][]byte
	errors    []error
}

func (r *scriptedRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	call := append([]string{name}, args...)
	r.calls = append(r.calls, call)
	i := len(r.calls) - 1
	var response []byte
	var err error
	if i < len(r.responses) {
		response = r.responses[i]
	}
	if i < len(r.errors) {
		err = r.errors[i]
	}
	return response, err
}

func TestTalosctlApplyUsesTryModeAndRollbackUsesOwnedInversePatch(t *testing.T) {
	runner := &scriptedRunner{}
	adapter := &TalosctlAdapter{
		Binary:      "talosctl",
		Talosconfig: "/talosconfig",
		Endpoint:    "10.0.0.10",
		TryTimeout:  90 * time.Second,
		Runner:      runner,
	}
	forward := []Operation{{Kind: EnsureBridge, Name: "br-test", Parent: "eth1"}}
	inverse := []Operation{{Kind: DeleteBridge, Name: "br-test"}}
	receipt, err := adapter.Apply(context.Background(), "node-1", forward, inverse)
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if receipt.Revision == "" || len(receipt.RollbackPatch) == 0 || strings.Contains(string(receipt.RollbackPatch), "machine:") {
		t.Fatalf("receipt = %+v", receipt)
	}
	if len(runner.calls) != 1 {
		t.Fatalf("apply calls = %#v", runner.calls)
	}
	applyArgs := strings.Join(runner.calls[0], " ")
	for _, want := range []string{"patch machineconfig", "--mode=try", "--timeout=1m30s"} {
		if !strings.Contains(applyArgs, want) {
			t.Fatalf("try-mode call %q missing %q", applyArgs, want)
		}
	}

	if err := adapter.Rollback(context.Background(), "node-1", receipt); err != nil {
		t.Fatalf("Rollback: %v", err)
	}
	if len(runner.calls) != 2 {
		t.Fatalf("rollback calls = %#v", runner.calls)
	}
	rollbackArgs := strings.Join(runner.calls[1], " ")
	for _, want := range []string{"patch machineconfig", "--mode=no-reboot", "--patch"} {
		if !strings.Contains(rollbackArgs, want) {
			t.Fatalf("rollback call %q missing %q", rollbackArgs, want)
		}
	}
	if strings.Contains(rollbackArgs, "apply-config") {
		t.Fatalf("rollback must never reapply a full machine configuration: %q", rollbackArgs)
	}
}

func TestTalosctlApplyRefusesTryModeWithoutInversePatch(t *testing.T) {
	adapter := &TalosctlAdapter{Endpoint: "10.0.0.10", Runner: &scriptedRunner{}}
	_, err := adapter.Apply(context.Background(), "node-1", []Operation{{Kind: EnsureBridge, Name: "br-test", Parent: "eth1"}}, nil)
	if err == nil || !strings.Contains(err.Error(), "without a controller-owned inverse rollback patch") {
		t.Fatalf("expected fail-closed missing inverse patch error, got %v", err)
	}
}

func TestOrchestratorRollsBackWhenConfirmFails(t *testing.T) {
	adapter := &fakeTalosAdapter{state: validState(), confirmErr: errors.New("confirm failed")}
	_, err := (Orchestrator{Adapter: adapter}).ReconcileNodeTransition(context.Background(), validSpec(), nil, "node-1")
	if err == nil || !strings.Contains(err.Error(), "rolled back") {
		t.Fatalf("expected confirmed rollback error, got %v", err)
	}
	if !adapter.applied || !adapter.verified || !adapter.confirmed || !adapter.rolledBack {
		t.Fatalf("transaction calls: applied=%v verified=%v confirmed=%v rolledBack=%v", adapter.applied, adapter.verified, adapter.confirmed, adapter.rolledBack)
	}
}

func TestOrchestratorSurfacesRollbackFailure(t *testing.T) {
	adapter := &fakeTalosAdapter{
		state:       validState(),
		verifyErr:   errors.New("management unavailable"),
		rollbackErr: errors.New("restore rejected"),
	}
	_, err := (Orchestrator{Adapter: adapter}).ReconcileNodeTransition(context.Background(), validSpec(), nil, "node-1")
	if err == nil || !strings.Contains(err.Error(), "rollback") || !strings.Contains(err.Error(), "restore rejected") {
		t.Fatalf("expected rollback failure detail, got %v", err)
	}
}

func TestNumberAcceptsTalosJSONRepresentations(t *testing.T) {
	for _, tc := range []struct {
		value interface{}
		want  int
	}{
		{float64(120), 120},
		{"130", 130},
		{nil, 0},
	} {
		if got := number(tc.value); got != tc.want {
			t.Fatalf("number(%v) = %d, want %d", tc.value, got, tc.want)
		}
	}
}

func ExampleRenderTalosPatch_delete() {
	patch, _ := RenderTalosPatch([]Operation{{Kind: DeleteBridge, Name: "br-vlan120"}, {Kind: DeleteVLAN, Name: "eth1.120"}})
	fmt.Println(strings.Contains(string(patch), "$patch: delete"))
	// Output: true
}
