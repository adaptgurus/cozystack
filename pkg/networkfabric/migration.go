// SPDX-License-Identifier: Apache-2.0

package networkfabric

import "sort"

// MigrationReport summarizes whether every selected KubeVirt node can carry
// the configured migration network. KubeVirt migrations must not be advertised
// as ready when a possible destination lacks the exact VLAN/bridge topology.
type MigrationReport struct {
	Configured       bool
	Network          string
	Bridge           string
	ReadyNodes       []string
	UnavailableNodes map[string]string
}

func (r MigrationReport) Ready() bool {
	return r.Configured && len(r.UnavailableNodes) == 0 && len(r.ReadyNodes) > 0
}

func ValidateMigrationCompatibility(spec Spec, states []NodeState) MigrationReport {
	report := MigrationReport{UnavailableNodes: map[string]string{}}
	var migration *Network
	for i := range spec.Networks {
		if spec.Networks[i].Migration {
			migration = &spec.Networks[i]
			break
		}
	}
	if migration == nil {
		return report
	}
	report.Configured = true
	report.Network = migration.Name
	report.Bridge = migration.Bridge

	for _, state := range states {
		if !state.ManagementReachable {
			report.UnavailableNodes[state.Name] = "Talos management API is unreachable"
			continue
		}
		if err := ValidateNetworkTopology(state, *migration); err != nil {
			report.UnavailableNodes[state.Name] = err.Error()
			continue
		}
		report.ReadyNodes = append(report.ReadyNodes, state.Name)
	}
	sort.Strings(report.ReadyNodes)
	return report
}
