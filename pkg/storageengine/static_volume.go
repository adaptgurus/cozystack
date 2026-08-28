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
// ValidateConnector succeeds against current discovery evidence.
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
	ready, err := ValidateConnector(req.Connector, env)
	if err != nil {
		return StaticVolumePlan{}, fmt.Errorf("static volume %q connector preflight failed: %w", req.Name, err)
	}
	if !ready.Ready {
		return StaticVolumePlan{}, fmt.Errorf("static volume %q connector is not ready", req.Name)
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
		if req.Node == "" {
			return StaticVolumePlan{}, fmt.Errorf("local static volume %q requires a node", req.Name)
		}
		if !containsString(connectorNodes(req.Connector, env), req.Node) {
			return StaticVolumePlan{}, fmt.Errorf("local static volume %q node %q is outside connector scope", req.Name, req.Node)
		}
		if strings.TrimSpace(req.Connector.DevicePath) == "" {
			return StaticVolumePlan{}, fmt.Errorf("local static volume %q requires an existing device/LV path", req.Name)
		}
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
