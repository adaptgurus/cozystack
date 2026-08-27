// SPDX-License-Identifier: Apache-2.0

package networkfabric

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
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
// bridge the physical uplink. MTU=0 intentionally omits the mtu field.
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
		default:
			return nil, fmt.Errorf("unsupported Talos network operation %q", op.Kind)
		}
	}
	return []byte(strings.Join(docs, "---\n")), nil
}

func parseTalosLinks(raw []byte) (map[string]InterfaceState, error) {
	interfaces := map[string]InterfaceState{}
	dec := json.NewDecoder(bytes.NewReader(raw))
	for dec.More() {
		var obj map[string]interface{}
		if err := dec.Decode(&obj); err != nil {
			return nil, err
		}
		metadata, _ := obj["metadata"].(map[string]interface{})
		spec, _ := obj["spec"].(map[string]interface{})
		name, _ := metadata["id"].(string)
		if name == "" {
			continue
		}
		state := InterfaceState{Name: name}
		for _, key := range []string{"operState", "operstate"} {
			if v, ok := spec[key].(string); ok && strings.EqualFold(v, "up") {
				state.Up = true
			}
		}
		if v, ok := spec["linkState"].(bool); ok && v {
			state.Up = true
		}
		switch v := spec["mtu"].(type) {
		case float64:
			state.MTU = int(v)
		case json.Number:
			n, _ := strconv.Atoi(v.String())
			state.MTU = n
		}
		interfaces[name] = state
	}
	if len(interfaces) == 0 {
		// Some talosctl versions return a single JSON array instead of a stream.
		var arr []map[string]interface{}
		if err := json.Unmarshal(raw, &arr); err == nil {
			for _, obj := range arr {
				one, _ := json.Marshal(obj)
				parsed, err := parseTalosLinks(one)
				if err == nil {
					for k, v := range parsed {
						interfaces[k] = v
					}
				}
			}
		}
	}
	if len(interfaces) == 0 {
		return nil, fmt.Errorf("talosctl returned no link resources")
	}
	return interfaces, nil
}
