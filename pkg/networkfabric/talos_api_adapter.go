// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"bytes"
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/cosi-project/runtime/pkg/resource"
	"github.com/siderolabs/talos/pkg/machinery/api/machine"
	talosclient "github.com/siderolabs/talos/pkg/machinery/client"
	"github.com/siderolabs/talos/pkg/machinery/config/configpatcher"
	"github.com/siderolabs/talos/pkg/machinery/nethelpers"
	configres "github.com/siderolabs/talos/pkg/machinery/resources/config"
	networkres "github.com/siderolabs/talos/pkg/machinery/resources/network"
	"google.golang.org/protobuf/types/known/durationpb"
)

type talosApplyMode string

const (
	talosApplyTry      talosApplyMode = "try"
	talosApplyNoReboot talosApplyMode = "no-reboot"
)

// talosNodeClient is the narrow test seam around Talos machinery. The
// production implementation below uses only the official v1.13.6 machinery
// client/COSI resource API; no process execution or temporary patch files are
// involved in the production NetworkFabric transaction path.
type talosNodeClient interface {
	Links(ctx context.Context, target string) (map[string]InterfaceState, error)
	ActiveMachineConfig(ctx context.Context, target string) ([]byte, error)
	ApplyConfiguration(ctx context.Context, target string, data []byte, mode talosApplyMode, tryTimeout time.Duration) error
	Close() error
}

type talosNodeClientFactory func(ctx context.Context, talosconfig, endpoint string) (talosNodeClient, error)

// TalosAPIAdapter applies NetworkFabric intent through the official Talos
// machinery client. TRY mode provides Talos' automatic timeout rollback; the
// orchestrator additionally retains a controller-owned inverse patch and calls
// Rollback explicitly on verification/confirmation failure.
type TalosAPIAdapter struct {
	Talosconfig string
	Endpoint    string
	TryTimeout  time.Duration

	newClient talosNodeClientFactory
}

func (a *TalosAPIAdapter) defaults() {
	if a.Talosconfig == "" {
		a.Talosconfig = "/var/run/secrets/talos.dev/config"
	}
	if a.TryTimeout == 0 {
		a.TryTimeout = 2 * time.Minute
	}
	if a.newClient == nil {
		a.newClient = newMachineryTalosNodeClient
	}
}

func (a *TalosAPIAdapter) open(ctx context.Context, node string) (talosNodeClient, string, error) {
	a.defaults()
	if a.Endpoint == "" {
		return nil, "", fmt.Errorf("Talos endpoint is required for node %q", node)
	}
	client, err := a.newClient(ctx, a.Talosconfig, a.Endpoint)
	if err != nil {
		return nil, "", fmt.Errorf("create Talos machinery client for node %q endpoint %q: %w", node, a.Endpoint, err)
	}
	return client, a.Endpoint, nil
}

func (a *TalosAPIAdapter) Inspect(ctx context.Context, node string) (NodeState, error) {
	client, target, err := a.open(ctx, node)
	if err != nil {
		return NodeState{Name: node, ManagementReachable: false}, err
	}
	defer client.Close() //nolint:errcheck

	interfaces, err := client.Links(ctx, target)
	if err != nil {
		return NodeState{Name: node, ManagementReachable: false}, fmt.Errorf("inspect Talos links for node %q: %w", node, err)
	}
	return NodeState{Name: node, ManagementReachable: true, Interfaces: interfaces}, nil
}

func (a *TalosAPIAdapter) Apply(ctx context.Context, node string, operations, rollbackOperations []Operation) (ApplyReceipt, error) {
	a.defaults()
	patch, err := RenderTalosPatch(operations)
	if err != nil {
		return ApplyReceipt{}, err
	}
	rollbackPatch, err := RenderTalosPatch(rollbackOperations)
	if err != nil {
		return ApplyReceipt{}, fmt.Errorf("render Talos inverse network patch for node %q: %w", node, err)
	}
	revisionMaterial := append(append(append([]byte(nil), patch...), []byte("\n--inverse--\n")...), rollbackPatch...)
	receipt := ApplyReceipt{Revision: digest(revisionMaterial), Patch: patch, RollbackPatch: rollbackPatch}
	if len(bytes.TrimSpace(patch)) == 0 {
		return receipt, nil
	}
	if len(bytes.TrimSpace(rollbackPatch)) == 0 {
		return ApplyReceipt{}, fmt.Errorf("refusing Talos try-mode update on node %q without a controller-owned inverse rollback patch", node)
	}
	if err := a.applyPatch(ctx, node, patch, talosApplyTry, a.TryTimeout); err != nil {
		return ApplyReceipt{}, fmt.Errorf("apply Talos network patch in try mode to node %q: %w", node, err)
	}
	return receipt, nil
}

func (a *TalosAPIAdapter) Confirm(ctx context.Context, node string, receipt ApplyReceipt) error {
	if len(bytes.TrimSpace(receipt.Patch)) == 0 {
		return nil
	}
	// Reapply the same idempotent forward patch in NO_REBOOT mode. This mirrors
	// talosctl patch machineconfig semantics: it reads the active TRY config and
	// calls ApplyConfiguration even when the resulting config is unchanged,
	// thereby persisting/confirming the active configuration.
	if err := a.applyPatch(ctx, node, receipt.Patch, talosApplyNoReboot, 0); err != nil {
		return fmt.Errorf("confirm Talos network patch on node %q: %w", node, err)
	}
	return nil
}

func (a *TalosAPIAdapter) VerifyManagement(ctx context.Context, node string, protectedInterfaces []string) error {
	state, err := a.Inspect(ctx, node)
	if err != nil {
		return err
	}
	if !state.ManagementReachable {
		return fmt.Errorf("Talos management API is not reachable")
	}
	for _, name := range protectedInterfaces {
		link, ok := state.Interfaces[name]
		if !ok {
			return fmt.Errorf("protected management interface %q disappeared", name)
		}
		if !link.Up {
			return fmt.Errorf("protected management interface %q is not up", name)
		}
	}
	return nil
}

func (a *TalosAPIAdapter) Rollback(ctx context.Context, node string, receipt ApplyReceipt) error {
	if len(bytes.TrimSpace(receipt.Patch)) == 0 {
		return nil
	}
	if len(bytes.TrimSpace(receipt.RollbackPatch)) == 0 {
		return fmt.Errorf("inverse rollback patch for revision %q is empty; Talos try timeout remains the safety net", receipt.Revision)
	}
	if err := a.applyPatch(ctx, node, receipt.RollbackPatch, talosApplyNoReboot, 0); err != nil {
		return fmt.Errorf("apply inverse Talos network patch on node %q: %w", node, err)
	}
	return nil
}

func (a *TalosAPIAdapter) applyPatch(ctx context.Context, node string, patch []byte, mode talosApplyMode, tryTimeout time.Duration) error {
	client, target, err := a.open(ctx, node)
	if err != nil {
		return err
	}
	defer client.Close() //nolint:errcheck

	body, err := client.ActiveMachineConfig(ctx, target)
	if err != nil {
		return fmt.Errorf("read active Talos MachineConfig: %w", err)
	}
	patches, err := configpatcher.LoadPatches([]string{string(patch)})
	if err != nil {
		return fmt.Errorf("load NetworkFabric Talos patch: %w", err)
	}
	cfg, err := configpatcher.Apply(configpatcher.WithBytes(body), patches)
	if err != nil {
		return fmt.Errorf("apply NetworkFabric patch to active Talos MachineConfig: %w", err)
	}
	patched, err := cfg.Bytes()
	if err != nil {
		return fmt.Errorf("serialize patched Talos MachineConfig: %w", err)
	}
	if err := client.ApplyConfiguration(ctx, target, patched, mode, tryTimeout); err != nil {
		return err
	}
	return nil
}

type machineryTalosNodeClient struct {
	client *talosclient.Client
}

func newMachineryTalosNodeClient(ctx context.Context, talosconfig, endpoint string) (talosNodeClient, error) {
	client, err := talosclient.New(ctx, talosclient.WithConfigFromFile(talosconfig), talosclient.WithEndpoints(endpoint))
	if err != nil {
		return nil, err
	}
	return &machineryTalosNodeClient{client: client}, nil
}

func (c *machineryTalosNodeClient) Close() error {
	return c.client.Close()
}

func (c *machineryTalosNodeClient) ActiveMachineConfig(ctx context.Context, target string) ([]byte, error) {
	res, err := c.client.COSI.Get(
		talosclient.WithNode(ctx, target),
		resource.NewMetadata(configres.NamespaceName, configres.MachineConfigType, configres.ActiveID, resource.VersionUndefined),
	)
	if err != nil {
		return nil, err
	}
	machineConfig, ok := res.(*configres.MachineConfig)
	if !ok {
		return nil, fmt.Errorf("Talos returned %T for active MachineConfig", res)
	}
	return machineConfig.Provider().Bytes()
}

func (c *machineryTalosNodeClient) ApplyConfiguration(ctx context.Context, target string, data []byte, mode talosApplyMode, tryTimeout time.Duration) error {
	request := &machine.ApplyConfigurationRequest{Data: data}
	switch mode {
	case talosApplyTry:
		request.Mode = machine.ApplyConfigurationRequest_TRY
		request.TryModeTimeout = durationpb.New(tryTimeout)
	case talosApplyNoReboot:
		request.Mode = machine.ApplyConfigurationRequest_NO_REBOOT
	default:
		return fmt.Errorf("unsupported Talos apply mode %q", mode)
	}
	_, err := c.client.ApplyConfiguration(talosclient.WithNode(ctx, target), request)
	return err
}

func (c *machineryTalosNodeClient) Links(ctx context.Context, target string) (map[string]InterfaceState, error) {
	list, err := c.client.COSI.List(
		talosclient.WithNode(ctx, target),
		resource.NewMetadata(networkres.NamespaceName, networkres.LinkStatusType, "", resource.VersionUndefined),
	)
	if err != nil {
		return nil, err
	}
	if len(list.Items) == 0 {
		return nil, fmt.Errorf("Talos returned no LinkStatus resources")
	}

	type rawLink struct {
		state       InterfaceState
		linkIndex   uint32
		masterIndex uint32
	}
	rawLinks := make(map[string]rawLink, len(list.Items))
	indexToName := make(map[uint32]string, len(list.Items))
	for _, item := range list.Items {
		link, ok := item.(*networkres.LinkStatus)
		if !ok {
			return nil, fmt.Errorf("Talos returned unexpected link resource type %T", item)
		}
		name := string(link.Metadata().ID())
		spec := link.TypedSpec()
		state := InterfaceState{
			Name:  name,
			Kind:  spec.Kind,
			Index: spec.Index,
			MTU:   int(spec.MTU),
			Up:    spec.LinkState || spec.OperationalState == nethelpers.OperStateUp,
			VLAN:  int(spec.VLAN.VID),
		}
		rawLinks[name] = rawLink{state: state, linkIndex: spec.LinkIndex, masterIndex: spec.MasterIndex}
		if spec.Index != 0 {
			indexToName[spec.Index] = name
		}
	}

	interfaces := make(map[string]InterfaceState, len(rawLinks))
	for name, raw := range rawLinks {
		state := raw.state
		if raw.linkIndex != 0 {
			state.Parent = indexToName[raw.linkIndex]
		}
		interfaces[name] = state
	}
	for name, raw := range rawLinks {
		if raw.masterIndex == 0 {
			continue
		}
		masterName := indexToName[raw.masterIndex]
		if masterName == "" {
			continue
		}
		master := interfaces[masterName]
		master.Members = append(master.Members, name)
		interfaces[masterName] = master
	}
	for name, state := range interfaces {
		sort.Strings(state.Members)
		interfaces[name] = state
	}
	return interfaces, nil
}
