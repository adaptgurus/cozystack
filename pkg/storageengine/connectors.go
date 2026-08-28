package storageengine

import (
	"fmt"
	"sort"
	"strings"
)

// ConnectorMode describes how LayerSentry connects a backend to workloads.
// CSI is the dynamic-provisioning path. HostManaged is for node-side storage
// such as per-node LVM/LVM-thin. StaticPV exposes a pre-existing shared LUN or
// export without pretending that LayerSentry can create/delete storage on the
// external array.
type ConnectorMode string

const (
	ConnectorModeCSI         ConnectorMode = "csi"
	ConnectorModeHostManaged ConnectorMode = "host-managed"
	ConnectorModeStaticPV    ConnectorMode = "static-pv"
)

// Transport is the actual data path beneath a Storage Backend.
type Transport string

const (
	TransportLocal   Transport = "local"
	TransportNFS     Transport = "nfs"
	TransportISCSI   Transport = "iscsi"
	TransportFC      Transport = "fc"
	TransportNVMETCP Transport = "nvme-tcp"
	TransportCSI     Transport = "csi"
)

// NodeStorageCapability contains read-only host facts gathered by the storage
// discovery probe. A false value means "not proven", never "install it now".
type NodeStorageCapability struct {
	Node           string
	LVMTools       bool
	ISCSITools     bool
	MultipathTools bool
	NVMeTools      bool
	FCHostWWPNs    []string
}

// ConnectorEnvironment is the evidence used to validate a connector. CSINodes
// maps node names to the CSI drivers registered on that node.
type ConnectorEnvironment struct {
	Snapshot         DiscoverySnapshot
	CSINodes         map[string][]string
	NodeCapabilities map[string]NodeStorageCapability
}

// ConnectorSpec is intentionally declarative. It never carries commands such
// as pvcreate/vgcreate/mkfs or a destructive mutation plan.
type ConnectorSpec struct {
	ID          string
	DisplayName string
	BackendType BackendType
	Mode        ConnectorMode
	Transport   Transport
	Scope       ScopeType
	Nodes       []string

	// CSI mode.
	CSIDriver    string
	StorageClass string

	// NFS.
	Server     string
	Export     string
	NFSVersion string

	// iSCSI.
	Portals       []string
	TargetIQN     string
	CHAPSecretRef string

	// FC.
	TargetWWNs []string

	// Shared block identity. LUN zero is valid, hence the pointer.
	LUN   *int
	WWID  string

	// NVMe/TCP.
	SubsystemNQN string

	// Local or LUN-backed LVM. PerNode means independent VGs on each selected
	// node and therefore intentionally does not imply live-migration capability.
	DevicePath  string
	VolumeGroup string
	ThinPool    string
	PerNode     bool

	Multipath bool
}

// ConnectorReadiness is suitable for a customer-facing preflight result.
type ConnectorReadiness struct {
	Ready    bool
	Mode     ConnectorMode
	Warnings []string
}

// ValidateConnector is fail-closed. It only validates whether the requested
// connector is supported by discovered evidence; it performs no storage or host
// mutation.
func ValidateConnector(spec ConnectorSpec, env ConnectorEnvironment) (ConnectorReadiness, error) {
	readiness := ConnectorReadiness{Mode: spec.Mode}
	if strings.TrimSpace(spec.ID) == "" {
		return readiness, fmt.Errorf("connector id is required")
	}
	if strings.TrimSpace(spec.DisplayName) == "" {
		return readiness, fmt.Errorf("connector %q display name is required", spec.ID)
	}
	if err := validateScope(spec.Scope, spec.Nodes); err != nil {
		return readiness, fmt.Errorf("connector %q: %w", spec.ID, err)
	}
	if spec.Mode != ConnectorModeCSI && spec.Mode != ConnectorModeHostManaged && spec.Mode != ConnectorModeStaticPV {
		return readiness, fmt.Errorf("connector %q has invalid mode %q", spec.ID, spec.Mode)
	}

	var err error
	switch spec.Mode {
	case ConnectorModeCSI:
		err = validateCSIConnector(spec, env)
	case ConnectorModeHostManaged:
		err = validateHostManagedConnector(spec, env)
	case ConnectorModeStaticPV:
		err = validateStaticConnector(spec, env)
	}
	if err != nil {
		return readiness, err
	}

	if spec.PerNode {
		readiness.Warnings = append(readiness.Warnings, "per-node storage is node-affine and must not be presented as shared/live-migratable storage")
	}
	if spec.Mode == ConnectorModeStaticPV {
		readiness.Warnings = append(readiness.Warnings, "static mode attaches existing storage only; LayerSentry does not create or delete LUNs on the external array")
	}
	readiness.Ready = true
	return readiness, nil
}

func validateCSIConnector(spec ConnectorSpec, env ConnectorEnvironment) error {
	if strings.TrimSpace(spec.CSIDriver) == "" {
		return fmt.Errorf("CSI connector %q requires a CSI driver", spec.ID)
	}
	if !containsString(env.Snapshot.CSIDrivers, spec.CSIDriver) {
		return fmt.Errorf("CSI driver %q has not been discovered", spec.CSIDriver)
	}
	if strings.TrimSpace(spec.StorageClass) == "" {
		return fmt.Errorf("CSI connector %q requires an existing verified StorageClass", spec.ID)
	}
	sc, ok := findStorageClass(env.Snapshot.StorageClasses, spec.StorageClass)
	if !ok {
		return fmt.Errorf("StorageClass %q has not been discovered", spec.StorageClass)
	}
	if sc.Provisioner != spec.CSIDriver {
		return fmt.Errorf("StorageClass %q uses provisioner %q, not CSI driver %q", sc.Name, sc.Provisioner, spec.CSIDriver)
	}
	for _, node := range connectorNodes(spec, env) {
		if !containsString(env.CSINodes[node], spec.CSIDriver) {
			return fmt.Errorf("CSI driver %q is not registered on node %q", spec.CSIDriver, node)
		}
	}
	return nil
}

func validateHostManagedConnector(spec ConnectorSpec, env ConnectorEnvironment) error {
	if spec.Transport != TransportLocal {
		return fmt.Errorf("host-managed connector %q currently supports only local LVM/LVM-thin", spec.ID)
	}
	if spec.BackendType != BackendLVM && spec.BackendType != BackendLVMThin {
		return fmt.Errorf("host-managed connector %q must use LVM or LVM Thin backend type", spec.ID)
	}
	if spec.Scope == ScopeAllNodes && !spec.PerNode {
		return fmt.Errorf("host-managed LVM cannot promise one shared all-node volume group; use per-node mode or a shared-storage connector")
	}
	if strings.TrimSpace(spec.VolumeGroup) == "" {
		return fmt.Errorf("LVM connector %q requires a volume group name", spec.ID)
	}
	if spec.BackendType == BackendLVMThin && strings.TrimSpace(spec.ThinPool) == "" {
		return fmt.Errorf("LVM Thin connector %q requires a thin pool name", spec.ID)
	}
	nodes := connectorNodes(spec, env)
	if len(nodes) == 0 {
		return fmt.Errorf("LVM connector %q requires discovered target nodes", spec.ID)
	}
	for _, node := range nodes {
		capability, ok := env.NodeCapabilities[node]
		if !ok || !capability.LVMTools {
			return fmt.Errorf("LVM tooling has not been proven on node %q", node)
		}
	}
	if spec.DevicePath != "" || spec.WWID != "" {
		if _, err := findSafeDevice(spec, env.Snapshot.Devices, nodes); err != nil {
			return err
		}
	}
	return nil
}

func validateStaticConnector(spec ConnectorSpec, env ConnectorEnvironment) error {
	nodes := connectorNodes(spec, env)
	if len(nodes) == 0 {
		return fmt.Errorf("static connector %q requires discovered target nodes", spec.ID)
	}

	switch spec.Transport {
	case TransportNFS:
		if strings.TrimSpace(spec.Server) == "" || strings.TrimSpace(spec.Export) == "" {
			return fmt.Errorf("NFS connector %q requires server and export", spec.ID)
		}
		return nil
	case TransportISCSI:
		if len(nonEmpty(spec.Portals)) == 0 || strings.TrimSpace(spec.TargetIQN) == "" || spec.LUN == nil {
			return fmt.Errorf("iSCSI connector %q requires portal, target IQN and LUN", spec.ID)
		}
		for _, node := range nodes {
			capability := env.NodeCapabilities[node]
			if !capability.ISCSITools {
				return fmt.Errorf("iSCSI tooling has not been proven on node %q", node)
			}
		}
	case TransportFC:
		if len(nonEmpty(spec.TargetWWNs)) == 0 || spec.LUN == nil {
			return fmt.Errorf("FC connector %q requires target WWN(s) and LUN", spec.ID)
		}
		for _, node := range nodes {
			capability := env.NodeCapabilities[node]
			if len(nonEmpty(capability.FCHostWWPNs)) == 0 {
				return fmt.Errorf("no Fibre Channel HBA/WWPN has been proven on node %q", node)
			}
		}
	case TransportNVMETCP:
		if strings.TrimSpace(spec.SubsystemNQN) == "" || len(nonEmpty(spec.Portals)) == 0 {
			return fmt.Errorf("NVMe/TCP connector %q requires subsystem NQN and address", spec.ID)
		}
		for _, node := range nodes {
			if !env.NodeCapabilities[node].NVMeTools {
				return fmt.Errorf("NVMe tooling has not been proven on node %q", node)
			}
		}
	default:
		return fmt.Errorf("static connector %q has unsupported transport %q", spec.ID, spec.Transport)
	}

	if spec.Transport == TransportISCSI || spec.Transport == TransportFC {
		if strings.TrimSpace(spec.WWID) == "" {
			return fmt.Errorf("shared block connector %q requires verified WWID", spec.ID)
		}
		if spec.Multipath {
			for _, node := range nodes {
				if !env.NodeCapabilities[node].MultipathTools {
					return fmt.Errorf("multipath tooling has not been proven on node %q", node)
				}
			}
		}
		if _, err := findSafeDevice(spec, env.Snapshot.Devices, nodes); err != nil {
			return err
		}
	}
	return nil
}

func connectorNodes(spec ConnectorSpec, env ConnectorEnvironment) []string {
	if spec.Scope != ScopeAllNodes {
		return sortedUnique(spec.Nodes)
	}
	set := map[string]struct{}{}
	for node := range env.NodeCapabilities {
		if strings.TrimSpace(node) != "" {
			set[node] = struct{}{}
		}
	}
	for node := range env.CSINodes {
		if strings.TrimSpace(node) != "" {
			set[node] = struct{}{}
		}
	}
	for _, device := range env.Snapshot.Devices {
		if strings.TrimSpace(device.Node) != "" {
			set[device.Node] = struct{}{}
		}
		for _, node := range device.VisibleNodes {
			if strings.TrimSpace(node) != "" {
				set[node] = struct{}{}
			}
		}
	}
	result := make([]string, 0, len(set))
	for node := range set {
		result = append(result, node)
	}
	sort.Strings(result)
	return result
}

func findSafeDevice(spec ConnectorSpec, devices []Device, nodes []string) (DeviceInventory, error) {
	for _, device := range devices {
		if spec.WWID != "" && device.WWID != spec.WWID {
			continue
		}
		if spec.DevicePath != "" && device.Path != spec.DevicePath {
			continue
		}
		inventory := ClassifyDevice(device)
		if inventory.Safety == DeviceSafetyProtected {
			return DeviceInventory{}, fmt.Errorf("device %q is protected: %s", device.Path, inventory.SafetyReason)
		}
		if inventory.Safety != DeviceSafetyCandidate {
			return DeviceInventory{}, fmt.Errorf("device %q is not safely identified: %s", device.Path, inventory.SafetyReason)
		}
		for _, node := range nodes {
			if device.Node != node && !containsString(device.VisibleNodes, node) {
				return DeviceInventory{}, fmt.Errorf("WWID %q has not been proven visible on node %q", device.WWID, node)
			}
		}
		return inventory, nil
	}
	return DeviceInventory{}, fmt.Errorf("requested device/WWID has not been discovered")
}

func findStorageClass(classes []StorageClassInfo, name string) (StorageClassInfo, bool) {
	for _, sc := range classes {
		if sc.Name == name {
			return sc, true
		}
	}
	return StorageClassInfo{}, false
}

func nonEmpty(values []string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			result = append(result, strings.TrimSpace(value))
		}
	}
	return result
}

func sortedUnique(values []string) []string {
	result := uniqueNonEmpty(values)
	sort.Strings(result)
	return result
}
