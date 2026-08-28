package storageengine

import "testing"

func TestBuildStaticISCSIBlockPlanRetainsExistingLUN(t *testing.T) {
	connector := ConnectorSpec{
		ID: "iscsi-san", DisplayName: "iSCSI SAN", BackendType: BackendISCSI,
		Mode: ConnectorModeStaticPV, Transport: TransportISCSI,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1", "sen2", "sen3"},
		Portals: []string{"10.20.0.10:3260", "10.20.1.10:3260"},
		TargetIQN: "iqn.2026-08.example:array.vm", LUN: intPtr(4),
		WWID: "3600staticiscsi", Multipath: true,
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{Devices: []Device{{
			Node: "sen1", Path: "/dev/mapper/mpatha", WWID: "3600staticiscsi",
			VisibleNodes: []string{"sen1", "sen2", "sen3"},
		}}},
		NodeCapabilities: map[string]NodeStorageCapability{
			"sen1": {Node: "sen1", ISCSITools: true, MultipathTools: true},
			"sen2": {Node: "sen2", ISCSITools: true, MultipathTools: true},
			"sen3": {Node: "sen3", ISCSITools: true, MultipathTools: true},
		},
	}
	plan, err := BuildStaticVolumePlan(StaticVolumeRequest{
		Name: "san-vm-001", Connector: connector, CapacityBytes: 100 << 30,
		VolumeMode: VolumeModeBlock,
	}, env)
	if err != nil {
		t.Fatalf("expected static iSCSI plan: %v", err)
	}
	if plan.ReclaimPolicy != "Retain" {
		t.Fatalf("external static LUN must default to Retain, got %q", plan.ReclaimPolicy)
	}
	if plan.ISCSI == nil || plan.ISCSI.WWID != "3600staticiscsi" || !plan.ISCSI.Multipath {
		t.Fatalf("unexpected iSCSI plan: %#v", plan.ISCSI)
	}
}

func TestBuildStaticFCRejectsProtectedLUN(t *testing.T) {
	connector := ConnectorSpec{
		ID: "fc-san", DisplayName: "FC SAN", BackendType: BackendFCSAN,
		Mode: ConnectorModeStaticPV, Transport: TransportFC,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1"},
		TargetWWNs: []string{"50:00:00:00:00:00:00:01"}, LUN: intPtr(2),
		WWID: "3600protectedfc", Multipath: true,
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{Devices: []Device{{
			Node: "sen1", Path: "/dev/mapper/mpathb", WWID: "3600protectedfc", LINSTORPool: "data",
		}}},
		NodeCapabilities: map[string]NodeStorageCapability{
			"sen1": {Node: "sen1", MultipathTools: true, FCHostWWPNs: []string{"10:00:00:00:00:00:00:01"}},
		},
	}
	_, err := BuildStaticVolumePlan(StaticVolumeRequest{
		Name: "fc-existing", Connector: connector, CapacityBytes: 50 << 30, VolumeMode: VolumeModeBlock,
	}, env)
	if err == nil {
		t.Fatal("protected LINSTOR-owned FC LUN must not produce a static attach plan")
	}
}

func TestBuildStaticNFSFilesystemPlan(t *testing.T) {
	connector := ConnectorSpec{
		ID: "backup-nfs", DisplayName: "Backup NFS", BackendType: BackendNFS,
		Mode: ConnectorModeStaticPV, Transport: TransportNFS, Scope: ScopeAllNodes,
		Server: "10.30.0.20", Export: "/backup",
	}
	env := ConnectorEnvironment{NodeCapabilities: map[string]NodeStorageCapability{
		"sen1": {Node: "sen1"}, "sen2": {Node: "sen2"}, "sen3": {Node: "sen3"},
	}}
	plan, err := BuildStaticVolumePlan(StaticVolumeRequest{
		Name: "backup-repository", Connector: connector, CapacityBytes: 1 << 40,
		VolumeMode: VolumeModeFilesystem, AccessModes: []string{"ReadWriteMany"},
	}, env)
	if err != nil {
		t.Fatalf("expected NFS plan: %v", err)
	}
	if plan.NFS == nil || plan.NFS.Server != "10.30.0.20" || plan.NFS.Export != "/backup" {
		t.Fatalf("unexpected NFS plan: %#v", plan.NFS)
	}
}

func TestBuildStaticLocalLVMRequiresExistingPathAndNode(t *testing.T) {
	connector := ConnectorSpec{
		ID: "node-lvm", DisplayName: "Node LVM", BackendType: BackendLVM,
		Mode: ConnectorModeHostManaged, Transport: TransportLocal,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1"}, PerNode: true,
		VolumeGroup: "vm-vg", DevicePath: "/dev/vm-vg/vm-001",
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{Devices: []Device{{
			Node: "sen1", Path: "/dev/vm-vg/vm-001", WWID: "local-lv-001", VolumeGroup: "vm-vg",
		}}},
		NodeCapabilities: map[string]NodeStorageCapability{"sen1": {Node: "sen1", LVMTools: true}},
	}
	plan, err := BuildStaticVolumePlan(StaticVolumeRequest{
		Name: "local-vm-001", Connector: connector, CapacityBytes: 20 << 30,
		VolumeMode: VolumeModeBlock, Node: "sen1",
	}, env)
	if err != nil {
		t.Fatalf("expected existing local LVM attach plan: %v", err)
	}
	if plan.Local == nil || plan.Local.Path != "/dev/vm-vg/vm-001" || plan.Node != "sen1" {
		t.Fatalf("unexpected local plan: %#v", plan)
	}
}

func TestBuildStaticLocalLVMRejectsForeignVG(t *testing.T) {
	connector := ConnectorSpec{
		ID: "node-lvm", DisplayName: "Node LVM", BackendType: BackendLVM,
		Mode: ConnectorModeHostManaged, Transport: TransportLocal,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1"}, PerNode: true,
		VolumeGroup: "vm-vg", DevicePath: "/dev/other-vg/vm-001",
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{Devices: []Device{{
			Node: "sen1", Path: "/dev/other-vg/vm-001", WWID: "local-lv-002", VolumeGroup: "other-vg",
		}}},
		NodeCapabilities: map[string]NodeStorageCapability{"sen1": {Node: "sen1", LVMTools: true}},
	}
	_, err := BuildStaticVolumePlan(StaticVolumeRequest{
		Name: "local-vm-001", Connector: connector, CapacityBytes: 20 << 30,
		VolumeMode: VolumeModeBlock, Node: "sen1",
	}, env)
	if err == nil {
		t.Fatal("foreign volume-group ownership must be rejected")
	}
}

func TestBuildStaticNVMeTCPRequiresCSIOrHostController(t *testing.T) {
	connector := ConnectorSpec{
		ID: "nvme", DisplayName: "NVMe/TCP", BackendType: BackendNVMETCP,
		Mode: ConnectorModeStaticPV, Transport: TransportNVMETCP,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1"},
		Portals: []string{"10.40.0.10:4420"}, SubsystemNQN: "nqn.2026-08.example:vm",
	}
	env := ConnectorEnvironment{NodeCapabilities: map[string]NodeStorageCapability{
		"sen1": {Node: "sen1", NVMeTools: true},
	}}
	_, err := BuildStaticVolumePlan(StaticVolumeRequest{
		Name: "nvme-vm", Connector: connector, CapacityBytes: 100 << 30, VolumeMode: VolumeModeBlock,
	}, env)
	if err == nil {
		t.Fatal("generic static NVMe/TCP must be rejected; it needs CSI or a verified host-connect controller")
	}
}
