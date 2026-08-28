package storageengine

import "testing"

func TestAdoptExistingPreservesReplicatedAndLocalStorageClasses(t *testing.T) {
	snapshot := DiscoverySnapshot{StorageClasses: []StorageClassInfo{
		{Name: "replicated", Provisioner: "linstor.csi.linbit.com", AllowExpansion: true, ReclaimPolicy: "Delete"},
		{Name: "local", Provisioner: "example.com/local-path", ReclaimPolicy: "Delete"},
	}}

	result := AdoptExisting(snapshot)
	if len(result.Backends) != 2 || len(result.Profiles) != 2 {
		t.Fatalf("expected 2 backends and 2 profiles, got %d and %d", len(result.Backends), len(result.Profiles))
	}

	replicated := result.Backends[0]
	if replicated.StorageClass != "replicated" {
		t.Fatalf("replicated StorageClass changed during adoption: %q", replicated.StorageClass)
	}
	if replicated.Mode != BackendModeAdopted {
		t.Fatalf("expected adopted mode, got %q", replicated.Mode)
	}
	if replicated.Type != BackendHCIReplicated {
		t.Fatalf("expected LINSTOR provisioner to be recognized as HCI replicated, got %q", replicated.Type)
	}
	if !containsPurpose(replicated.Purposes, PurposeTPMState) {
		t.Fatal("replicated backend must remain eligible for persistent TPM/VM state")
	}

	local := result.Backends[1]
	if local.StorageClass != "local" {
		t.Fatalf("local StorageClass changed during adoption: %q", local.StorageClass)
	}
	if local.Type == BackendLocalZFS {
		t.Fatalf("unknown local provisioner must not be mislabeled as Local ZFS")
	}
}

func TestAdoptExistingDoesNotMutateDiscoveryInput(t *testing.T) {
	parameters := map[string]string{"storagePool": "pool-a"}
	snapshot := DiscoverySnapshot{StorageClasses: []StorageClassInfo{{
		Name: "replicated", Provisioner: "linstor.csi.linbit.com", Parameters: parameters,
	}}}

	_ = AdoptExisting(snapshot)
	if got := snapshot.StorageClasses[0].Parameters["storagePool"]; got != "pool-a" {
		t.Fatalf("discovery input was mutated: %q", got)
	}
}

func TestProviderCatalogRequiresVerifiedProviderIntegration(t *testing.T) {
	withoutDriver := ProviderCatalog(DiscoverySnapshot{})
	if catalogEntry(t, withoutDriver, BackendNFS).CreateAvailable {
		t.Fatal("NFS must not be offered for creation without verified provider integration")
	}

	withDriver := ProviderCatalog(DiscoverySnapshot{Providers: map[BackendType]ProviderSupport{
		BackendNFS: {
			ControllerInstalled:  true,
			NodeIntegrationReady: true,
			DynamicProvisioning:  true,
		},
	}})
	if !catalogEntry(t, withDriver, BackendNFS).CreateAvailable {
		t.Fatal("NFS should be available after controller, node integration and dynamic provisioning are verified")
	}
}

func TestProviderCatalogAllowsSafeReplicatedAdoptionWithoutClaimingCreateSupport(t *testing.T) {
	catalog := ProviderCatalog(DiscoverySnapshot{StorageClasses: []StorageClassInfo{{Name: "replicated"}}})
	entry := catalogEntry(t, catalog, BackendHCIReplicated)
	if !entry.AdoptAvailable {
		t.Fatal("existing replicated class should be adoptable")
	}
	if entry.CreateAvailable {
		t.Fatal("existing replicated class must not imply that new HCI backend creation is supported")
	}
}

func TestValidateProfileRejectsUnprovenCapabilities(t *testing.T) {
	backend := Backend{
		ID:          "san-a",
		DisplayName: "SAN A",
		Type:        BackendFCSAN,
		Mode:        BackendModeManaged,
		Scope:       ScopeAllNodes,
		Purposes:    []Purpose{PurposeVMOSDisk},
		Capabilities: Capabilities{
			Block: true,
		},
	}
	backends := map[string]Backend{backend.ID: backend}

	profile := Profile{
		ID:               "san-gold",
		BackendRef:       backend.ID,
		Provisioning:     ProvisioningThin,
		Purposes:         []Purpose{PurposeVMOSDisk},
		VolumeMode:       VolumeModeBlock,
		ExpansionAllowed: true,
	}
	if err := ValidateProfile(profile, backends); err == nil {
		t.Fatal("expected validation failure for unproven thin/expansion capabilities")
	}
}

func TestValidateProfileAcceptsConservativeReplicatedProfile(t *testing.T) {
	result := AdoptExisting(DiscoverySnapshot{StorageClasses: []StorageClassInfo{{
		Name: "replicated", Provisioner: "linstor.csi.linbit.com", AllowExpansion: true, ReclaimPolicy: "Delete",
	}}})
	backends := map[string]Backend{result.Backends[0].ID: result.Backends[0]}
	if err := ValidateBackend(result.Backends[0]); err != nil {
		t.Fatalf("adopted backend invalid: %v", err)
	}
	if err := ValidateProfile(result.Profiles[0], backends); err != nil {
		t.Fatalf("adopted profile invalid: %v", err)
	}
}

func TestDeviceInUseUsesExplicitMembership(t *testing.T) {
	if (Device{Path: "/dev/sdb", UsedBytes: 1024}).InUse() {
		t.Fatal("UsedBytes alone must not be interpreted as an ownership signal")
	}
	if !(Device{Path: "/dev/sdb", WWID: "3600example", LINSTORPool: "pool-a"}).InUse() {
		t.Fatal("LINSTOR membership must mark a device as in use")
	}
	if !(Device{Path: "/dev/sdc", Filesystem: "xfs"}).InUse() {
		t.Fatal("existing filesystem must mark a device as in use")
	}
}

func catalogEntry(t *testing.T, entries []CatalogEntry, backendType BackendType) CatalogEntry {
	t.Helper()
	for _, entry := range entries {
		if entry.Type == backendType {
			return entry
		}
	}
	t.Fatalf("catalog entry %q not found", backendType)
	return CatalogEntry{}
}
