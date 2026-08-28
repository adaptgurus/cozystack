package storageengine

import (
	"fmt"
	"strings"
)

// AdoptExisting safely projects known existing StorageClasses into LayerSentry
// backends/profiles. It performs no Kubernetes or host mutation.
func AdoptExisting(snapshot DiscoverySnapshot) AdoptionResult {
	result := AdoptionResult{}

	for _, sc := range snapshot.StorageClasses {
		switch sc.Name {
		case "replicated":
			backend := adoptedReplicated(sc)
			result.Backends = append(result.Backends, backend)
			result.Profiles = append(result.Profiles, Profile{
				ID:               "hci-replicated",
				DisplayName:      backend.DisplayName,
				Description:      "Adopted profile for replicated VM disks and persistent VM state.",
				BackendRef:       backend.ID,
				Provisioning:     ProvisioningProviderDefault,
				Purposes:         []Purpose{PurposeVMOSDisk, PurposeVMDataDisk, PurposeTPMState},
				VolumeMode:       VolumeModeBlock,
				ExpansionAllowed: backend.Capabilities.Expansion,
				PerformanceTier:  "replicated",
				ReclaimPolicy:    sc.ReclaimPolicy,
			})
		case "local":
			backend := adoptedLocal(sc)
			result.Backends = append(result.Backends, backend)
			result.Profiles = append(result.Profiles, Profile{
				ID:               "local-vm",
				DisplayName:      backend.DisplayName,
				Description:      "Adopted node-local profile for VM disks.",
				BackendRef:       backend.ID,
				Provisioning:     ProvisioningProviderDefault,
				Purposes:         []Purpose{PurposeVMOSDisk, PurposeVMDataDisk},
				VolumeMode:       VolumeModeFilesystem,
				ExpansionAllowed: backend.Capabilities.Expansion,
				PerformanceTier:  "local",
				ReclaimPolicy:    sc.ReclaimPolicy,
			})
		}
	}

	return result
}

func adoptedReplicated(sc StorageClassInfo) Backend {
	backendType := BackendAdoptedStorageClass
	displayName := "Replicated Storage (adopted)"
	caps := Capabilities{
		DynamicProvisioning: sc.Provisioner != "",
		Expansion:           sc.AllowExpansion,
		Block:               true,
		Filesystem:          true,
	}

	if containsFold(sc.Provisioner, "linstor") {
		backendType = BackendHCIReplicated
		displayName = "HCI Replicated"
		caps.Replication = true
		caps.Shared = true
		caps.ThinProvisioning = true
	}

	return Backend{
		ID:           "builtin-replicated",
		DisplayName:  displayName,
		Description:  "Existing replicated StorageClass adopted without recreation.",
		Type:         backendType,
		Mode:         BackendModeAdopted,
		Scope:        ScopeAllNodes,
		Purposes:     []Purpose{PurposeVMOSDisk, PurposeVMDataDisk, PurposeTPMState},
		StorageClass: sc.Name,
		Capabilities: caps,
	}
}

func adoptedLocal(sc StorageClassInfo) Backend {
	backendType := BackendAdoptedStorageClass
	displayName := "Local Storage (adopted)"
	caps := Capabilities{
		DynamicProvisioning: sc.Provisioner != "",
		Expansion:           sc.AllowExpansion,
		Filesystem:          true,
	}

	// Do not label an arbitrary class named "local" as ZFS unless discovery
	// actually identifies a ZFS-backed provisioner.
	if containsFold(sc.Provisioner, "zfs") {
		backendType = BackendLocalZFS
		displayName = "Local ZFS"
		caps.ThinProvisioning = true
		caps.Snapshot = true
	}

	return Backend{
		ID:           "builtin-local",
		DisplayName:  displayName,
		Description:  "Existing local StorageClass adopted without recreation.",
		Type:         backendType,
		Mode:         BackendModeAdopted,
		Scope:        ScopeSelectedNodes,
		Purposes:     []Purpose{PurposeVMOSDisk, PurposeVMDataDisk},
		StorageClass: sc.Name,
		Capabilities: caps,
	}
}

// ProviderCatalog returns the backend choices the product may display. Adoption
// is based on observed existing classes; new creation requires an explicit,
// successful provider capability probe.
func ProviderCatalog(snapshot DiscoverySnapshot) []CatalogEntry {
	types := []BackendType{
		BackendHCIReplicated,
		BackendLocalZFS,
		BackendLVM,
		BackendLVMThin,
		BackendNFS,
		BackendISCSI,
		BackendFCSAN,
		BackendNVMETCP,
		BackendExternalCSI,
	}

	entries := make([]CatalogEntry, 0, len(types))
	for _, backendType := range types {
		support := snapshot.Providers[backendType]
		entry := CatalogEntry{
			Type:            backendType,
			AdoptAvailable:  adoptable(snapshot, backendType),
			CreateAvailable: support.ReadyForCreate(),
			Reason:          support.Reason,
		}
		if !entry.CreateAvailable && entry.Reason == "" {
			entry.Reason = "required provider controller, node integration, or dynamic provisioning has not been verified"
		}
		entries = append(entries, entry)
	}
	return entries
}

func adoptable(snapshot DiscoverySnapshot, backendType BackendType) bool {
	for _, sc := range snapshot.StorageClasses {
		switch backendType {
		case BackendHCIReplicated:
			if sc.Name == "replicated" {
				return true
			}
		case BackendLocalZFS:
			if sc.Name == "local" && containsFold(sc.Provisioner, "zfs") {
				return true
			}
		}
	}
	return false
}

// ValidateBackend validates only the declarative backend contract. Provider
// controllers remain responsible for provider-specific connectivity tests.
func ValidateBackend(backend Backend) error {
	if backend.ID == "" {
		return fmt.Errorf("backend id is required")
	}
	if backend.DisplayName == "" {
		return fmt.Errorf("backend %q display name is required", backend.ID)
	}
	if backend.Mode != BackendModeAdopted && backend.Mode != BackendModeManaged {
		return fmt.Errorf("backend %q has invalid mode %q", backend.ID, backend.Mode)
	}
	if backend.Mode == BackendModeAdopted && backend.StorageClass == "" {
		return fmt.Errorf("adopted backend %q must reference an existing StorageClass", backend.ID)
	}
	if err := validateScope(backend.Scope, backend.Nodes); err != nil {
		return fmt.Errorf("backend %q: %w", backend.ID, err)
	}
	if len(backend.Purposes) == 0 {
		return fmt.Errorf("backend %q must allow at least one purpose", backend.ID)
	}
	return nil
}

// ValidateProfile enforces that customer-facing policy never promises a
// capability that its backend has not proven.
func ValidateProfile(profile Profile, backends map[string]Backend) error {
	if profile.ID == "" {
		return fmt.Errorf("profile id is required")
	}
	backend, ok := backends[profile.BackendRef]
	if !ok {
		return fmt.Errorf("profile %q references unknown backend %q", profile.ID, profile.BackendRef)
	}
	if len(profile.Purposes) == 0 {
		return fmt.Errorf("profile %q must allow at least one purpose", profile.ID)
	}
	for _, purpose := range profile.Purposes {
		if !containsPurpose(backend.Purposes, purpose) {
			return fmt.Errorf("profile %q purpose %q is not allowed by backend %q", profile.ID, purpose, backend.ID)
		}
	}
	if profile.ExpansionAllowed && !backend.Capabilities.Expansion {
		return fmt.Errorf("profile %q enables expansion but backend %q does not support it", profile.ID, backend.ID)
	}
	switch profile.Provisioning {
	case ProvisioningProviderDefault:
	case ProvisioningThin:
		if !backend.Capabilities.ThinProvisioning {
			return fmt.Errorf("profile %q requests thin provisioning but backend %q has not proven it", profile.ID, backend.ID)
		}
	case ProvisioningThick:
		if !backend.Capabilities.ThickProvisioning {
			return fmt.Errorf("profile %q requests thick provisioning but backend %q has not proven it", profile.ID, backend.ID)
		}
	default:
		return fmt.Errorf("profile %q has invalid provisioning %q", profile.ID, profile.Provisioning)
	}
	if profile.ReplicationCount < 0 {
		return fmt.Errorf("profile %q replication count cannot be negative", profile.ID)
	}
	if profile.ReplicationCount > 0 && !backend.Capabilities.Replication {
		return fmt.Errorf("profile %q requests replication but backend %q has not proven it", profile.ID, backend.ID)
	}
	switch profile.VolumeMode {
	case VolumeModeBlock:
		if !backend.Capabilities.Block {
			return fmt.Errorf("profile %q requests block mode but backend %q does not support it", profile.ID, backend.ID)
		}
	case VolumeModeFilesystem:
		if !backend.Capabilities.Filesystem {
			return fmt.Errorf("profile %q requests filesystem mode but backend %q does not support it", profile.ID, backend.ID)
		}
	default:
		return fmt.Errorf("profile %q has invalid volume mode %q", profile.ID, profile.VolumeMode)
	}
	if profile.ReclaimPolicy != "" && profile.ReclaimPolicy != "Retain" && profile.ReclaimPolicy != "Delete" {
		return fmt.Errorf("profile %q has invalid reclaim policy %q", profile.ID, profile.ReclaimPolicy)
	}
	if err := validateProfileNodes(profile.Nodes, backend); err != nil {
		return fmt.Errorf("profile %q: %w", profile.ID, err)
	}
	return nil
}

func validateScope(scope ScopeType, nodes []string) error {
	switch scope {
	case ScopeAllNodes:
		return nil
	case ScopeSelectedNodes:
		// An adopted node-local StorageClass may not expose its concrete node set
		// through StorageClass metadata alone; an empty list is therefore allowed
		// until the read-only topology probe fills it in.
		return nil
	case ScopeSingleNode:
		if len(nodes) != 1 {
			return fmt.Errorf("single-node scope requires exactly one node")
		}
		return nil
	default:
		return fmt.Errorf("invalid scope %q", scope)
	}
}

func validateProfileNodes(nodes []string, backend Backend) error {
	if len(nodes) == 0 || backend.Scope == ScopeAllNodes || len(backend.Nodes) == 0 {
		return nil
	}
	allowed := make(map[string]struct{}, len(backend.Nodes))
	for _, node := range backend.Nodes {
		allowed[node] = struct{}{}
	}
	for _, node := range nodes {
		if _, ok := allowed[node]; !ok {
			return fmt.Errorf("node %q is outside backend %q topology", node, backend.ID)
		}
	}
	return nil
}

func containsPurpose(purposes []Purpose, want Purpose) bool {
	for _, purpose := range purposes {
		if purpose == want {
			return true
		}
	}
	return false
}

func containsFold(value, fragment string) bool {
	return strings.Contains(strings.ToLower(value), strings.ToLower(fragment))
}
