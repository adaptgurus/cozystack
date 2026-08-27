// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"sigs.k8s.io/yaml"
)

// CommandRunner makes the talosctl adapter unit-testable without requiring a
// Talos node or binary during normal Go tests.
type CommandRunner interface {
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}

// TalosctlAdapter applies NetworkFabric intent through Talos' supported
// machine-configuration API. Changes are first applied in try mode: Talos will
// automatically revert them when the timeout expires unless Confirm succeeds.
type TalosctlAdapter struct {
	Binary      string
	Talosconfig string
	Endpoint    string
	TryTimeout  time.Duration
	Runner      CommandRunner
}

func (a *TalosctlAdapter) defaults() {
	if a.Binary == "" {
		a.Binary = "talosctl"
	}
	if a.Talosconfig == "" {
		a.Talosconfig = "/var/run/secrets/talos.dev/config"
	}
	if a.TryTimeout == 0 {
		a.TryTimeout = 2 * time.Minute
	}
	if a.Runner == nil {
		a.Runner = ExecRunner{}
	}
}

func (a *TalosctlAdapter) baseArgs() []string {
	return []string{"--talosconfig", a.Talosconfig, "--nodes", a.Endpoint}
}

func (a *TalosctlAdapter) Inspect(ctx context.Context, node string) (NodeState, error) {
	a.defaults()
	if a.Endpoint == "" {
		return NodeState{}, fmt.Errorf("Talos endpoint is required for node %q", node)
	}
	args := append(a.baseArgs(), "get", "links", "-o", "json")
	out, err := a.Runner.Run(ctx, a.Binary, args...)
	if err != nil {
		return NodeState{Name: node, ManagementReachable: false}, err
	}
	interfaces, err := parseTalosLinks(out)
	if err != nil {
		return NodeState{}, fmt.Errorf("parse Talos links for node %q: %w", node, err)
	}
	return NodeState{Name: node, ManagementReachable: true, Interfaces: interfaces}, nil
}

func (a *TalosctlAdapter) Apply(ctx context.Context, node string, operations []Operation) (ApplyReceipt, error) {
	a.defaults()
	snapshot, err := a.machineConfigSnapshot(ctx)
	if err != nil {
		return ApplyReceipt{}, fmt.Errorf("snapshot Talos machine config for node %q: %w", node, err)
	}
	patch, err := RenderTalosPatch(operations)
	if err != nil {
		return ApplyReceipt{}, err
	}
	if len(bytes.TrimSpace(patch)) == 0 {
		return ApplyReceipt{Revision: digest(snapshot), RollbackConfig: snapshot, Patch: patch}, nil
	}
	if err := a.patchMachineConfig(ctx, patch, "try", a.TryTimeout); err != nil {
		return ApplyReceipt{}, fmt.Errorf("apply Talos network patch in try mode to node %q: %w", node, err)
	}
	return ApplyReceipt{Revision: digest(snapshot), RollbackConfig: snapshot, Patch: patch}, nil
}

func (a *TalosctlAdapter) Confirm(ctx context.Context, node string, receipt ApplyReceipt) error {
	a.defaults()
	if len(bytes.TrimSpace(receipt.Patch)) == 0 {
		return nil
	}
	if err := a.patchMachineConfig(ctx, receipt.Patch, "no-reboot", 0); err != nil {
		return fmt.Errorf("confirm Talos network patch on node %q: %w", node, err)
	}
	return nil
}

func (a *TalosctlAdapter) VerifyManagement(ctx context.Context, node string, protectedInterfaces []string) error {
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

func (a *TalosctlAdapter) Rollback(ctx context.Context, node string, receipt ApplyReceipt) error {
	a.defaults()
	if len(bytes.TrimSpace(receipt.RollbackConfig)) == 0 {
		return fmt.Errorf("rollback configuration for revision %q is empty", receipt.Revision)
	}
	path, cleanup, err := writeTemp("network-fabric-rollback-*.yaml", receipt.RollbackConfig)
	if err != nil {
		return err
	}
	defer cleanup()
	args := append(a.baseArgs(), "apply-config", "--mode=no-reboot", "--file", path)
	if _, err := a.Runner.Run(ctx, a.Binary, args...); err != nil {
		return fmt.Errorf("restore Talos machine config on node %q: %w", node, err)
	}
	return nil
}

func (a *TalosctlAdapter) machineConfigSnapshot(ctx context.Context) ([]byte, error) {
	args := append(a.baseArgs(), "get", "machineconfig", "v1alpha1", "-o", "json")
	out, err := a.Runner.Run(ctx, a.Binary, args...)
	if err != nil {
		return nil, err
	}
	var resource map[string]interface{}
	if err := json.Unmarshal(bytes.TrimSpace(out), &resource); err != nil {
		return nil, fmt.Errorf("decode machineconfig JSON: %w", err)
	}
	spec, ok := resource["spec"]
	if !ok {
		return nil, fmt.Errorf("machineconfig resource has no spec")
	}
	raw, err := json.Marshal(spec)
	if err != nil {
		return nil, err
	}
	return yaml.JSONToYAML(raw)
}

func (a *TalosctlAdapter) patchMachineConfig(ctx context.Context, patch []byte, mode string, timeout time.Duration) error {
	path, cleanup, err := writeTemp("network-fabric-patch-*.yaml", patch)
	if err != nil {
		return err
	}
	defer cleanup()
	args := append(a.baseArgs(), "patch", "machineconfig", "--mode="+mode, "--patch", "@"+path)
	if timeout > 0 {
		args = append(args, "--timeout="+timeout.String())
	}
	_, err = a.Runner.Run(ctx, a.Binary, args...)
	return err
}

func writeTemp(pattern string, content []byte) (string, func(), error) {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", nil, err
	}
	path := f.Name()
	cleanup := func() { _ = os.Remove(path) }
	if err := f.Chmod(0o600); err != nil {
		_ = f.Close()
		cleanup()
		return "", nil, err
	}
	if _, err := f.Write(content); err != nil {
		_ = f.Close()
		cleanup()
		return "", nil, err
	}
	if err := f.Close(); err != nil {
		cleanup()
		return "", nil, err
	}
	return path, cleanup, nil
}

func digest(content []byte) string {
	h := sha256.Sum256(content)
	return hex.EncodeToString(h[:8])
}

// RenderTalosPatch emits modern multi-document Talos networking resources.
// Tagged networks use VLANConfig -> BridgeConfig; native networks directly
// bridge the physical uplink. Deletion operations use Talos document-level
// $patch: delete and are emitted bridge-first so a child VLAN is not removed
// while the bridge still references it. MTU=0 intentionally omits mtu.
func RenderTalosPatch(operations []Operation) ([]byte, error) {
	var docs []string
	for _, op := range operations {
		switch op.Kind {
		case EnsureVLAN:
			if op.VLAN < 1 || op.VLAN > 4094 {
				return nil, fmt.Errorf("VLAN operation %q has invalid VLAN %d", op.Name, op.VLAN)
			}
			var b strings.Builder
			fmt.Fprintf(&b, "apiVersion: v1alpha1\nkind: VLANConfig\nname: %s\nvlanID: %d\nparent: %s\nup: true\n", op.Name, op.VLAN, op.Parent)
			if op.MTU > 0 {
				fmt.Fprintf(&b, "mtu: %d\n", op.MTU)
			}
			docs = append(docs, b.String())
		case EnsureBridge:
			var b strings.Builder
			fmt.Fprintf(&b, "apiVersion: v1alpha1\nkind: BridgeConfig\nname: %s\nlinks:\n  - %s\nup: true\n", op.Name, op.Parent)
			if op.MTU > 0 {
				fmt.Fprintf(&b, "mtu: %d\n", op.MTU)
			}
			docs = append(docs, b.String())
		case DeleteBridge:
			if op.Name == "" {
				return nil, fmt.Errorf("bridge delete operation requires a name")
			}
			docs = append(docs, fmt.Sprintf("apiVersion: v1alpha1\nkind: BridgeConfig\nname: %s\n$patch: delete\n", op.Name))
		case DeleteVLAN:
			if op.Name == "" {
				return nil, fmt.Errorf("VLAN delete operation requires a name")
			}
			docs = append(docs, fmt.Sprintf("apiVersion: v1alpha1\nkind: VLANConfig\nname: %s\n$patch: delete\n", op.Name))
		default:
			return nil, fmt.Errorf("unsupported Talos network operation %q", op.Kind)
		}
	}
	return []byte(strings.Join(docs, "---\n")), nil
}

type rawTalosLink struct {
	state       InterfaceState
	linkIndex   uint32
	masterIndex uint32
}

func parseTalosLinks(raw []byte) (map[string]InterfaceState, error) {
	objects, err := decodeTalosLinkObjects(raw)
	if err != nil {
		return nil, err
	}

	rawLinks := map[string]rawTalosLink{}
	indexToName := map[uint32]string{}
	for _, obj := range objects {
		metadata, _ := obj["metadata"].(map[string]interface{})
		spec, _ := obj["spec"].(map[string]interface{})
		name, _ := metadata["id"].(string)
		if name == "" {
			continue
		}

		state := InterfaceState{Name: name}
		state.Kind, _ = spec["kind"].(string)
		state.Index = uint32(number(spec["index"]))
		state.MTU = number(spec["mtu"])
		for _, key := range []string{"operationalState", "operState", "operstate"} {
			if v, ok := spec[key].(string); ok && strings.EqualFold(v, "up") {
				state.Up = true
			}
		}
		if v, ok := spec["linkState"].(bool); ok && v {
			state.Up = true
		}
		if vlan, ok := spec["vlan"].(map[string]interface{}); ok {
			state.VLAN = number(vlan["vlanID"])
		}

		link := rawTalosLink{
			state:       state,
			linkIndex:   uint32(number(spec["linkIndex"])),
			masterIndex: uint32(number(spec["masterIndex"])),
		}
		rawLinks[name] = link
		if state.Index != 0 {
			indexToName[state.Index] = name
		}
	}
	if len(rawLinks) == 0 {
		return nil, fmt.Errorf("talosctl returned no link resources")
	}

	interfaces := make(map[string]InterfaceState, len(rawLinks))
	for name, rawLink := range rawLinks {
		state := rawLink.state
		if rawLink.linkIndex != 0 {
			state.Parent = indexToName[rawLink.linkIndex]
		}
		interfaces[name] = state
	}
	for name, rawLink := range rawLinks {
		if rawLink.masterIndex == 0 {
			continue
		}
		masterName := indexToName[rawLink.masterIndex]
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

func decodeTalosLinkObjects(raw []byte) ([]map[string]interface{}, error) {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return nil, fmt.Errorf("talosctl returned empty link output")
	}

	var array []map[string]interface{}
	if trimmed[0] == '[' {
		if err := json.Unmarshal(trimmed, &array); err != nil {
			return nil, err
		}
		return array, nil
	}

	dec := json.NewDecoder(bytes.NewReader(trimmed))
	dec.UseNumber()
	var objects []map[string]interface{}
	for {
		var obj map[string]interface{}
		if err := dec.Decode(&obj); err != nil {
			if err == io.EOF {
				break
			}
			return nil, err
		}
		objects = append(objects, obj)
	}
	return objects, nil
}

func number(v interface{}) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case float32:
		return int(n)
	case int:
		return n
	case int64:
		return int(n)
	case uint64:
		return int(n)
	case json.Number:
		value, _ := strconv.Atoi(n.String())
		return value
	case string:
		value, _ := strconv.Atoi(n)
		return value
	default:
		return 0
	}
}
