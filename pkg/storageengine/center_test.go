package storageengine

import "testing"

func TestClassifyDeviceProtectsExistingStorage(t *testing.T) {
	device := Device{
		Node:        "sen1",
		Path:        "/dev/sdb",
		WWID:        "3600-test-existing",
		ZFSPool:     "data",
		LINSTORPool: "data",
	}

	got := ClassifyDevice(device)
	if got.Safety != DeviceSafetyProtected {
		t.Fatalf("expected protected device, got %q", got.Safety)
	}
	if got.DestructiveEligible {
		t.Fatal("existing ZFS/LINSTOR storage must never be marked destructive-eligible")
	}
}

func TestClassifyDeviceRequiresStableIdentity(t *testing.T) {
	got := ClassifyDevice(Device{Node: "sen2", Path: "/dev/sdb"})
	if got.Safety != DeviceSafetyUnverified {
		t.Fatalf("expected unverified device without WWID/serial, got %q", got.Safety)
	}
	if got.DestructiveEligible {
		t.Fatal("unidentified device must not be destructive-eligible")
	}
}

func TestClassifyDeviceDetectsSharedLUN(t *testing.T) {
	got := ClassifyDevice(Device{
		Node:         "sen1",
		Path:         "/dev/mapper/mpatha",
		WWID:         "3600-shared",
		VisibleNodes: []string{"sen1", "sen2", "sen3", "sen2"},
	})
	if !got.SharedLUN {
		t.Fatal("expected LUN visible on multiple nodes to be classified shared")
	}
	if got.Safety != DeviceSafetyCandidate {
		t.Fatalf("expected unused identified LUN to be a candidate, got %q", got.Safety)
	}
}

func TestBuildCenterAdoptsKnownClassesWithoutMutationPlan(t *testing.T) {
	center := BuildCenter(DiscoverySnapshot{
		StorageClasses: []StorageClassInfo{
			{Name: "replicated", Provisioner: "linstor.csi.linbit.com", AllowExpansion: true, ReclaimPolicy: "Delete"},
			{Name: "local", Provisioner: "example.com/local-path", ReclaimPolicy: "Delete"},
		},
		Devices: []Device{{Node: "sen1", Path: "/dev/sdb", WWID: "disk-1", ZFSPool: "data"}},
	})

	if len(center.Backends) != 2 || len(center.Profiles) != 2 {
		t.Fatalf("expected two adopted backends/profiles, got %d/%d", len(center.Backends), len(center.Profiles))
	}
	if len(center.Inventory) != 1 || center.Inventory[0].Safety != DeviceSafetyProtected {
		t.Fatal("expected existing discovered pool to remain protected")
	}
}

func TestResolveProfileHidesRawStorageClassFromCustomerFlow(t *testing.T) {
	snapshot := DiscoverySnapshot{StorageClasses: []StorageClassInfo{
		{Name: "replicated", Provisioner: "linstor.csi.linbit.com", AllowExpansion: true, ReclaimPolicy: "Delete"},
	}}
	adopted := AdoptExisting(snapshot)

	resolved, err := ResolveProfile("hci-replicated", PurposeVMOSDisk, "sen1", adopted.Profiles, adopted.Backends)
	if err != nil {
		t.Fatalf("resolve profile: %v", err)
	}
	if resolved.StorageClass != "replicated" {
		t.Fatalf("expected implementation target replicated, got %q", resolved.StorageClass)
	}
	if resolved.ProfileID != "hci-replicated" {
		t.Fatalf("expected customer profile identity to be preserved, got %q", resolved.ProfileID)
	}
}

func TestResolveProfileRejectsWrongPurpose(t *testing.T) {
	snapshot := DiscoverySnapshot{StorageClasses: []StorageClassInfo{
		{Name: "local", Provisioner: "example.com/local-path", ReclaimPolicy: "Delete"},
	}}
	adopted := AdoptExisting(snapshot)

	if _, err := ResolveProfile("local-vm", PurposeBackup, "", adopted.Profiles, adopted.Backends); err == nil {
		t.Fatal("expected local VM profile to reject backup purpose")
	}
}

func TestResolveProfileRejectsUnknownLocalTopologyWhenNodePinned(t *testing.T) {
	snapshot := DiscoverySnapshot{StorageClasses: []StorageClassInfo{
		{Name: "local", Provisioner: "example.com/local-path", ReclaimPolicy: "Delete"},
	}}
	adopted := AdoptExisting(snapshot)

	if _, err := ResolveProfile("local-vm", PurposeVMOSDisk, "sen2", adopted.Profiles, adopted.Backends); err == nil {
		t.Fatal("expected unresolved local topology to reject a node-pinned promise")
	}
}

func TestCompatibleProfilesFiltersByPurpose(t *testing.T) {
	snapshot := DiscoverySnapshot{StorageClasses: []StorageClassInfo{
		{Name: "replicated", Provisioner: "linstor.csi.linbit.com", AllowExpansion: true, ReclaimPolicy: "Delete"},
		{Name: "local", Provisioner: "example.com/local-path", ReclaimPolicy: "Delete"},
	}}
	adopted := AdoptExisting(snapshot)

	profiles := CompatibleProfiles(PurposeTPMState, "", adopted.Profiles, adopted.Backends)
	if len(profiles) != 1 || profiles[0].ID != "hci-replicated" {
		t.Fatalf("expected only replicated TPM profile, got %#v", profiles)
	}
}
