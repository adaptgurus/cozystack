package storageengine

import "testing"

func intPtr(v int) *int { return &v }

func TestCSIConnectorRequiresDriverRegistrationOnEveryTargetNode(t *testing.T) {
	spec := ConnectorSpec{
		ID: "san-csi", DisplayName: "SAN CSI", BackendType: BackendExternalCSI,
		Mode: ConnectorModeCSI, Transport: TransportCSI, Scope: ScopeAllNodes,
		CSIDriver: "vendor.csi.example", StorageClass: "san-gold",
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{
			CSIDrivers: []string{"vendor.csi.example"},
			StorageClasses: []StorageClassInfo{{Name: "san-gold", Provisioner: "vendor.csi.example"}},
		},
		CSINodes: map[string][]string{
			"sen1": {"vendor.csi.example"},
			"sen2": {"vendor.csi.example"},
			"sen3": {},
		},
	}
	if _, err := ValidateConnector(spec, env); err == nil {
		t.Fatal("expected CSI connector to fail when one target node lacks driver registration")
	}
	env.CSINodes["sen3"] = []string{"vendor.csi.example"}
	ready, err := ValidateConnector(spec, env)
	if err != nil || !ready.Ready {
		t.Fatalf("expected verified CSI connector to be ready: readiness=%#v err=%v", ready, err)
	}
}

func TestPerNodeLVMRequiresLVMToolsAndNeverClaimsSharedStorage(t *testing.T) {
	spec := ConnectorSpec{
		ID: "local-lvm", DisplayName: "Local LVM", BackendType: BackendLVM,
		Mode: ConnectorModeHostManaged, Transport: TransportLocal,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1", "sen2", "sen3"},
		VolumeGroup: "layersentry-vm", PerNode: true,
	}
	env := ConnectorEnvironment{NodeCapabilities: map[string]NodeStorageCapability{
		"sen1": {Node: "sen1", LVMTools: true},
		"sen2": {Node: "sen2", LVMTools: true},
		"sen3": {Node: "sen3", LVMTools: false},
	}}
	if _, err := ValidateConnector(spec, env); err == nil {
		t.Fatal("expected per-node LVM to fail until every selected node proves LVM tooling")
	}
	env.NodeCapabilities["sen3"] = NodeStorageCapability{Node: "sen3", LVMTools: true}
	ready, err := ValidateConnector(spec, env)
	if err != nil || !ready.Ready {
		t.Fatalf("expected per-node LVM connector ready: %#v err=%v", ready, err)
	}
	if len(ready.Warnings) == 0 {
		t.Fatal("per-node LVM must warn that it is node-affine/non-shared")
	}
}

func TestISCSIStaticMultipathRequiresWWIDVisibilityAndTools(t *testing.T) {
	spec := ConnectorSpec{
		ID: "iscsi-san", DisplayName: "iSCSI SAN", BackendType: BackendISCSI,
		Mode: ConnectorModeStaticPV, Transport: TransportISCSI,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1", "sen2", "sen3"},
		Portals: []string{"10.20.0.10:3260", "10.20.1.10:3260"},
		TargetIQN: "iqn.2026-08.example:array.vm", LUN: intPtr(0),
		WWID: "3600d0231example", Multipath: true,
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{Devices: []Device{{
			Node: "sen1", Path: "/dev/mapper/mpatha", WWID: "3600d0231example",
			VisibleNodes: []string{"sen1", "sen2", "sen3"},
		}}},
		NodeCapabilities: map[string]NodeStorageCapability{
			"sen1": {Node: "sen1", ISCSITools: true, MultipathTools: true},
			"sen2": {Node: "sen2", ISCSITools: true, MultipathTools: true},
			"sen3": {Node: "sen3", ISCSITools: true, MultipathTools: false},
		},
	}
	if _, err := ValidateConnector(spec, env); err == nil {
		t.Fatal("expected multipath iSCSI connector to fail until multipath is proven on all nodes")
	}
	env.NodeCapabilities["sen3"] = NodeStorageCapability{Node: "sen3", ISCSITools: true, MultipathTools: true}
	ready, err := ValidateConnector(spec, env)
	if err != nil || !ready.Ready {
		t.Fatalf("expected verified static iSCSI connector to be ready: %#v err=%v", ready, err)
	}
}

func TestFCStaticRequiresHostHBAAndNeverAcceptsProtectedLUN(t *testing.T) {
	spec := ConnectorSpec{
		ID: "fc-san", DisplayName: "FC SAN", BackendType: BackendFCSAN,
		Mode: ConnectorModeStaticPV, Transport: TransportFC,
		Scope: ScopeSelectedNodes, Nodes: []string{"sen1"},
		TargetWWNs: []string{"50:00:00:00:00:00:00:01"}, LUN: intPtr(7),
		WWID: "3600fcshared", Multipath: true,
	}
	env := ConnectorEnvironment{
		Snapshot: DiscoverySnapshot{Devices: []Device{{
			Node: "sen1", Path: "/dev/mapper/mpathb", WWID: "3600fcshared", VolumeGroup: "existing-vg",
		}}},
		NodeCapabilities: map[string]NodeStorageCapability{
			"sen1": {Node: "sen1", MultipathTools: true, FCHostWWPNs: []string{"10:00:00:00:00:00:00:01"}},
		},
	}
	if _, err := ValidateConnector(spec, env); err == nil {
		t.Fatal("existing LVM ownership must protect an FC LUN from connector provisioning")
	}
	env.Snapshot.Devices[0].VolumeGroup = ""
	ready, err := ValidateConnector(spec, env)
	if err != nil || !ready.Ready {
		t.Fatalf("expected identified unused FC LUN to pass static attach preflight: %#v err=%v", ready, err)
	}
}

func TestNFSStaticRequiresServerAndExport(t *testing.T) {
	spec := ConnectorSpec{
		ID: "nfs", DisplayName: "NFS Shared", BackendType: BackendNFS,
		Mode: ConnectorModeStaticPV, Transport: TransportNFS,
		Scope: ScopeAllNodes,
	}
	env := ConnectorEnvironment{NodeCapabilities: map[string]NodeStorageCapability{
		"sen1": {Node: "sen1"}, "sen2": {Node: "sen2"}, "sen3": {Node: "sen3"},
	}}
	if _, err := ValidateConnector(spec, env); err == nil {
		t.Fatal("NFS connector without server/export must fail")
	}
	spec.Server = "10.30.0.20"
	spec.Export = "/vm-storage"
	ready, err := ValidateConnector(spec, env)
	if err != nil || !ready.Ready {
		t.Fatalf("expected static NFS connector ready: %#v err=%v", ready, err)
	}
}
