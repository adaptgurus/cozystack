package storageengine

import (
	"fmt"
	"strings"
)

// StaticVolumeRequest describes one existing volume that LayerSentry may expose
// without a CSI provisioner. It never means "create this LUN" or "initialize
// this device"; the external/local storage must already exist and pass the
// connector preflight.
type StaticVolumeRequest struct {
	Name          string
	Connector     ConnectorSpec
	CapacityBytes uint64
	VolumeMode    VolumeMode
	AccessModes   []string
	ReadOnly      bool
	FSType        string
	Node          string
}

// StaticVolumePlan is a provider-neutral representation of a Kubernetes static
// PV. A controller/API layer can render this into a PersistentVolume only after
// the connector succeeds against current discovery evidence.
type StaticVolumePlan struct {
	Name          string
	CapacityBytes uint64
	VolumeMode    VolumeMode
	AccessModes   []string
	ReclaimPolicy string
	ReadOnly      bool
	FSType        string
	Node          string
	Transport     Transport

	NFS   *NFSVolumeSource
	ISCSI *ISCSIVolumeSource
	FC    *FCVolumeSource
	Local *LocalVolumeSource
}

type NFSVolumeSource struct {
	Server string
	Export string
}

type ISCSIVolumeSource struct {
	Portals       []string
	TargetIQN     string
	LUN           int
	CHAPSecretRef string
	WWID          string
	Multipath     bool
}

type FCVolumeSource struct {
	TargetWWNs []string
	LUN        int
	WWID       string
	Multipath  bool
}

type LocalVolumeSource struct {
	Path        string
	VolumeGroup string
	ThinPool    string
}

// BuildStaticVolumePlan converts a verified non-CSI connector into a safe
// attach-only plan. It deliberately cannot build dynamic provisioning plans,
// create filesystems, create LVs, log in to SAN targets, or configure paths.
func BuildStaticVolumePlan(req StaticVolumeRequest, env ConnectorEnvironment) (StaticVolumePlan, error) {
	if strings.TrimSpace(req.Name) == "" {
		return StaticVolumePlan{}, fmt.Errorf("static volume name is required")
	}
	if req.CapacityBytes == 0 {
		return StaticVolumePlan{}, fmt.Errorf("static volume %q capacity must be greater than zero", req.Name)
	}
	if req.Connector.Mode == ConnectorModeCSI {
		return StaticVolumePlan{}, fmt.Errorf("static volume %q cannot use CSI connector mode", req.Name)
	}

	// Existing node-local LVs are an attach operation, not an initialization
	// operation. A matching expected VG is therefore valid ownership here even
	// though the same device remains protected from the initialization path.
	if req.Connector.Transport == TransportLocal && (req.Connector.BackendType == BackendLVM || req.Connector.BackendType == BackendLVMThin) {
		if err := validateExistingLocalLV(req, env); err != nil {
			return StaticVolumePlan{}, fmt.Errorf("static volume %q local-LVM preflight failed: %w", req.Name, err)
		}
	} else {
		ready, err := ValidateConnector(req.Connector, env)
		if err != nil {
			return StaticVolumePlan{}, fmt.Errorf("static volume %q connector preflight failed: %w", req.Name, err)
		}
		if !ready.Ready {
			return StaticVolumePlan{}, fmt.Errorf("static volume %q connector is not ready", req.Name)
		}
	}

	if req.VolumeMode != VolumeModeBlock && req.VolumeMode != VolumeModeFilesystem {
		return StaticVolumePlan{}, fmt.Errorf("static volume %q has invalid volume mode %q", req.Name, req.VolumeMode)
	}
	accessModes := req.AccessModes
	if len(accessModes) == 0 {
		accessModes = []string{"ReadWriteOnce"}
	}
	for _, mode := range accessModes {
		switch mode {
		case "ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany", "ReadWriteOncePod":
		default:
			return StaticVolumePlan{}, fmt.Errorf("static volume %q has unsupported access mode %q", req.Name, mode)
		}
	}

	plan := StaticVolumePlan{
		Name:          req.Name,
		CapacityBytes: req.CapacityBytes,
		VolumeMode:    req.VolumeMode,
		AccessModes:   append([]string(nil), accessModes...),
		ReclaimPolicy: "Retain",
		ReadOnly:      req.ReadOnly,
		FSType:        req.FSType,
		Node:          req.Node,
		Transport:     req.Connector.Transport,
	}

	switch req.Connector.Transport {
	case TransportNFS:
		if req.VolumeMode != VolumeModeFilesystem {
			return StaticVolumePlan{}, fmt.Errorf("NFS static volume %q must use filesystem mode", req.Name)
		}
		plan.NFS = &NFSVolumeSource{Server: req.Connector.Server, Export: req.Connector.Export}
	case TransportISCSI:
		plan.ISCSI = &ISCSIVolumeSource{
			Portals:       append([]string(nil), nonEmpty(req.Connector.Portals)...),
			TargetIQN:     req.Connector.TargetIQN,
			LUN:           *req.Connector.LUN,
			CHAPSecretRef: req.Connector.CHAPSecretRef,
			WWID:          req.Connector.WWID,
			Multipath:     req.Connector.Multipath,
		}
	case TransportFC:
		plan.FC = &FCVolumeSource{
			TargetWWNs: append([]string(nil), nonEmpty(req.Connector.TargetWWNs)...),
			LUN:        *req.Connector.LUN,
			WWID:       req.Connector.WWID,
			Multipath:  req.Connector.Multipath,
		}
	case TransportLocal:
		plan.Local = &LocalVolumeSource{
			Path:        req.Connector.DevicePath,
			VolumeGroup: req.Connector.VolumeGroup,
			ThinPool:    req.Connector.ThinPool,
		}
	case TransportNVMETCP:
		return StaticVolumePlan{}, fmt.Errorf("NVMe/TCP has no generic Kubernetes static PV source; use a CSI driver or a verified host-connect controller")
	default:
		return StaticVolumePlan{}, fmt.Errorf("transport %q cannot be rendered as a non-CSI static volume", req.Connector.Transport)
	}
	return plan, nil
}

func validateExistingLocalLV(req StaticVolumeRequest, env ConnectorEnvironment) error {
	spec := req.Connector
	if req.Node == "" {
		return fmt.Errorf("node is required")
	}
	if !containsString(connectorNodes(spec, env), req.Node) {
		return fmt.Errorf("node %q is outside connector scope", req.Node)
	}
	capability, ok := env.NodeCapabilities[req.Node]
	if !ok || !capability.LVMTools {
		return fmt.Errorf("LVM tooling has not been proven on node %q", req.Node)
	}
	if strings.TrimSpace(spec.VolumeGroup) == "" {
		return fmt.Errorf("volume group is required")
	}
	if spec.BackendType == BackendLVMThin && strings.TrimSpace(spec.ThinPool) == "" {
		return fmt.Errorf("thin pool is required for LVM Thin")
	}
	if strings.TrimSpace(spec.DevicePath) == "" {
		return fmt.Errorf("existing LV/device path is required")
	}

	for _, device := range env.Snapshot.Devices {
		if device.Node != req.Node || device.Path != spec.DevicePath {
			continue
		}
		if spec.WWID != "" && device.WWID != spec.WWID {
			continue
		}
		if device.Filesystem != "" {
			return fmt.Errorf("device %q already contains filesystem %q", device.Path, device.Filesystem)
		}
		if device.ZFSPool != "" || device.LINSTORPool != "" || len(device.ExistingUsers) > 0 {
			return fmt.Errorf("device %q is owned by another storage backend", device.Path)
		}
		if device.VolumeGroup != "" && device.VolumeGroup != spec.VolumeGroup {
			return fmt.Errorf("device %q belongs to volume group %q, expected %q", device.Path, device.VolumeGroup, spec.VolumeGroup)
		}
		if device.VolumeGroup == "" {
			return fmt.Errorf("device %q has not been proven to belong to expected volume group %q", device.Path, spec.VolumeGroup)
		}
		return nil
	}
	return fmt.Errorf("existing LV/device %q has not been discovered on node %q", spec.DevicePath, req.Node)
}
