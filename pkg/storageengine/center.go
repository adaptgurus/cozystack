package storageengine

import (
	"fmt"
	"sort"
	"strings"
)

// DeviceSafety is a conservative classification for discovered media. The
// storage engine never turns this classification into a destructive host
// operation; it only tells higher layers whether a device is even eligible to
// enter a separately-confirmed provisioning workflow.
type DeviceSafety string

const (
	DeviceSafetyProtected  DeviceSafety = "protected"
	DeviceSafetyUnverified DeviceSafety = "unverified"
	DeviceSafetyCandidate  DeviceSafety = "candidate"
)

// DeviceInventory is the product-facing representation of a discovered disk or
// shared LUN. DestructiveEligible means only that discovery found no ownership
// and a stable identity. It is NOT authorization to format or initialize media.
type DeviceInventory struct {
	Device              Device
	Safety              DeviceSafety
	SafetyReason        string
	DestructiveEligible bool
	SharedLUN           bool
}

// CenterSnapshot is the read-only Storage Center state consumed by the API/UI.
// It deliberately separates discovery, adopted abstractions and provider
// catalog state. Building it has no side effects.
type CenterSnapshot struct {
	Inventory []DeviceInventory
	Backends  []Backend
	Profiles  []Profile
	Catalog   []CatalogEntry
}

// ProfileResolution is the implementation detail returned to VM/backup/image
// controllers after a customer selects a Storage Profile.
type ProfileResolution struct {
	ProfileID    string
	BackendID    string
	StorageClass string
	VolumeMode   VolumeMode
	Provisioning Provisioning
	ReclaimPolicy string
}

// BuildCenter creates a deterministic, side-effect-free Storage Center view.
func BuildCenter(snapshot DiscoverySnapshot) CenterSnapshot {
	adopted := AdoptExisting(snapshot)
	inventory := make([]DeviceInventory, 0, len(snapshot.Devices))
	for _, device := range snapshot.Devices {
		inventory = append(inventory, ClassifyDevice(device))
	}

	sort.Slice(inventory, func(i, j int) bool {
		if inventory[i].Device.Node == inventory[j].Device.Node {
			return inventory[i].Device.Path < inventory[j].Device.Path
		}
		return inventory[i].Device.Node < inventory[j].Device.Node
	})
	sort.Slice(adopted.Backends, func(i, j int) bool { return adopted.Backends[i].ID < adopted.Backends[j].ID })
	sort.Slice(adopted.Profiles, func(i, j int) bool { return adopted.Profiles[i].ID < adopted.Profiles[j].ID })

	return CenterSnapshot{
		Inventory: inventory,
		Backends:  adopted.Backends,
		Profiles:  adopted.Profiles,
		Catalog:   ProviderCatalog(snapshot),
	}
}

// ClassifyDevice applies the storage engine's non-destructive discovery policy.
// Existing filesystem/LVM/ZFS/LINSTOR/known users always wins over any apparent
// free-space signal. A stable identity is required before a device can even be
// considered a provisioning candidate.
func ClassifyDevice(device Device) DeviceInventory {
	result := DeviceInventory{
		Device:    device,
		SharedLUN: len(uniqueNonEmpty(device.VisibleNodes)) > 1,
	}

	if device.InUse() {
		result.Safety = DeviceSafetyProtected
		result.SafetyReason = ownershipSummary(device)
		return result
	}

	if strings.TrimSpace(device.WWID) == "" && strings.TrimSpace(device.Serial) == "" {
		result.Safety = DeviceSafetyUnverified
		result.SafetyReason = "stable device identity (WWID or serial) was not discovered"
		return result
	}

	if strings.TrimSpace(device.Path) == "" || strings.TrimSpace(device.Node) == "" {
		result.Safety = DeviceSafetyUnverified
		result.SafetyReason = "node and device path must be discovered before provisioning can be considered"
		return result
	}

	result.Safety = DeviceSafetyCandidate
	result.SafetyReason = "no existing filesystem/VG/ZFS/LINSTOR ownership was discovered; explicit identity verification and destructive confirmation are still required"
	result.DestructiveEligible = true
	return result
}

// ResolveProfile converts a customer-facing Storage Profile selection into the
// minimum implementation detail needed by a workload controller. It prevents a
// caller from bypassing profile purpose/topology validation and directly using
// an arbitrary StorageClass.
func ResolveProfile(profileID string, purpose Purpose, node string, profiles []Profile, backends []Backend) (ProfileResolution, error) {
	backendMap := make(map[string]Backend, len(backends))
	for _, backend := range backends {
		if err := ValidateBackend(backend); err != nil {
			return ProfileResolution{}, err
		}
		backendMap[backend.ID] = backend
	}

	var profile *Profile
	for i := range profiles {
		if profiles[i].ID == profileID {
			profile = &profiles[i]
			break
		}
	}
	if profile == nil {
		return ProfileResolution{}, fmt.Errorf("storage profile %q was not found", profileID)
	}
	if err := ValidateProfile(*profile, backendMap); err != nil {
		return ProfileResolution{}, err
	}
	if !containsPurpose(profile.Purposes, purpose) {
		return ProfileResolution{}, fmt.Errorf("storage profile %q does not allow purpose %q", profile.ID, purpose)
	}

	backend := backendMap[profile.BackendRef]
	if node != "" && !nodeAllowed(node, *profile, backend) {
		return ProfileResolution{}, fmt.Errorf("storage profile %q is not available on node %q", profile.ID, node)
	}
	if strings.TrimSpace(backend.StorageClass) == "" {
		return ProfileResolution{}, fmt.Errorf("storage backend %q has no resolved dynamic provisioning target", backend.ID)
	}

	return ProfileResolution{
		ProfileID:     profile.ID,
		BackendID:     backend.ID,
		StorageClass:  backend.StorageClass,
		VolumeMode:    profile.VolumeMode,
		Provisioning:  profile.Provisioning,
		ReclaimPolicy: profile.ReclaimPolicy,
	}, nil
}

// CompatibleProfiles returns only profiles that are valid for a given workload
// purpose and optional target node. Invalid/incomplete profiles are omitted
// rather than exposed as selectable choices.
func CompatibleProfiles(purpose Purpose, node string, profiles []Profile, backends []Backend) []Profile {
	compatible := make([]Profile, 0, len(profiles))
	for _, profile := range profiles {
		if _, err := ResolveProfile(profile.ID, purpose, node, profiles, backends); err == nil {
			compatible = append(compatible, profile)
		}
	}
	sort.Slice(compatible, func(i, j int) bool { return compatible[i].DisplayName < compatible[j].DisplayName })
	return compatible
}

func nodeAllowed(node string, profile Profile, backend Backend) bool {
	if backend.Scope == ScopeAllNodes {
		return true
	}
	if len(profile.Nodes) > 0 {
		return containsString(profile.Nodes, node)
	}
	if len(backend.Nodes) > 0 {
		return containsString(backend.Nodes, node)
	}
	// An adopted local class with unresolved topology is not safe to promise on
	// a specific node. Callers may resolve it without node pinning only until the
	// topology discovery probe populates concrete nodes.
	return false
}

func ownershipSummary(device Device) string {
	owners := make([]string, 0, 5+len(device.ExistingUsers))
	if device.Filesystem != "" {
		owners = append(owners, "filesystem="+device.Filesystem)
	}
	if device.VolumeGroup != "" {
		owners = append(owners, "vg="+device.VolumeGroup)
	}
	if device.ZFSPool != "" {
		owners = append(owners, "zfs="+device.ZFSPool)
	}
	if device.LINSTORPool != "" {
		owners = append(owners, "linstor="+device.LINSTORPool)
	}
	for _, owner := range device.ExistingUsers {
		if strings.TrimSpace(owner) != "" {
			owners = append(owners, "user="+owner)
		}
	}
	if len(owners) == 0 {
		return "existing storage ownership was discovered"
	}
	return "existing storage ownership: " + strings.Join(owners, ", ")
}

func uniqueNonEmpty(values []string) []string {
	seen := map[string]struct{}{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
