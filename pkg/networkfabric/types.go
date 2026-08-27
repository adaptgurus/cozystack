// SPDX-License-Identifier: Apache-2.0

// Package networkfabric defines the platform/Talos orchestration boundary for
// physical VM networking. Tenant VMNetwork objects never mutate node network
// configuration directly; a platform controller translates NetworkFabric
// intent through this adapter boundary instead.
package networkfabric

import "context"

const ProviderTalos = "talos"

type Spec struct {
	Provider                      string
	NodeSelector                  map[string]string
	ProtectedManagementInterfaces []string
	Networks                      []Network
	Rollout                       Rollout
}

type Network struct {
	Name          string
	Uplink        string
	VLAN          int
	VLANInterface string
	Bridge        string
	MTU           int
	Migration     bool
}

type Rollout struct {
	// MaxUnavailable is intentionally constrained to one by validation until
	// management-plane safety is proven for wider parallel rollouts.
	MaxUnavailable int
}

type NodeState struct {
	Name                string
	ManagementReachable bool
	Interfaces          map[string]InterfaceState
}

type InterfaceState struct {
	Name string
	MTU  int
	Up   bool
}

type OperationKind string

const (
	EnsureVLAN   OperationKind = "EnsureVLAN"
	EnsureBridge OperationKind = "EnsureBridge"
)

type Operation struct {
	Kind       OperationKind
	Name       string
	Parent     string
	VLAN       int
	MTU        int
	NetworkRef string
}

type Plan struct {
	Node       string
	Operations []Operation
}

type ApplyReceipt struct {
	// Revision identifies the machine configuration captured immediately before
	// the try-mode update. RollbackConfig and Patch remain controller memory only
	// and are never persisted into Kubernetes status or logs.
	Revision       string
	RollbackConfig []byte
	Patch          []byte
}

// TalosAdapter is deliberately narrow. The Kubernetes reconciler owns desired
// state and rollout order; the adapter owns Talos inspection, transactional
// application, connectivity verification, confirmation and rollback mechanics.
type TalosAdapter interface {
	Inspect(ctx context.Context, node string) (NodeState, error)
	Apply(ctx context.Context, node string, operations []Operation) (ApplyReceipt, error)
	VerifyManagement(ctx context.Context, node string, protectedInterfaces []string) error
	Confirm(ctx context.Context, node string, receipt ApplyReceipt) error
	Rollback(ctx context.Context, node string, receipt ApplyReceipt) error
}
