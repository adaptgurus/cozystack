package storageengine

// BackendType is the customer-facing storage technology represented by a backend.
type BackendType string

const (
	BackendHCIReplicated       BackendType = "hci-replicated"
	BackendLocalZFS            BackendType = "local-zfs"
	BackendLVM                 BackendType = "lvm"
	BackendLVMThin             BackendType = "lvm-thin"
	BackendNFS                 BackendType = "nfs"
	BackendISCSI               BackendType = "iscsi"
	BackendFCSAN               BackendType = "fc-san"
	BackendNVMETCP             BackendType = "nvme-tcp"
	BackendExternalCSI         BackendType = "external-csi"
	BackendAdoptedStorageClass BackendType = "adopted-storage-class"
)

// BackendMode distinguishes storage that LayerSentry merely adopts from storage
// whose lifecycle is managed by a verified provider controller.
type BackendMode string

const (
	BackendModeAdopted BackendMode = "adopted"
	BackendModeManaged BackendMode = "managed"
)

// ScopeType controls where a backend can be consumed.
type ScopeType string

const (
	ScopeAllNodes      ScopeType = "all-nodes"
	ScopeSelectedNodes ScopeType = "selected-nodes"
	ScopeSingleNode    ScopeType = "single-node"
)

// Purpose describes a product workload that may consume a storage profile.
type Purpose string

const (
	PurposeVMOSDisk   Purpose = "vm-os-disk"
	PurposeVMDataDisk Purpose = "vm-data-disk"
	PurposeImageISO   Purpose = "image-iso"
	PurposeBackup     Purpose = "backup"
	PurposeTPMState   Purpose = "tpm-state"
)

// Provisioning is the allocation policy presented to customers.
type Provisioning string

const (
	ProvisioningProviderDefault Provisioning = "provider-default"
	ProvisioningThin            Provisioning = "thin"
	ProvisioningThick           Provisioning = "thick"
)

// VolumeMode is the storage interface exposed to a workload.
type VolumeMode string

const (
	VolumeModeBlock      VolumeMode = "block"
	VolumeModeFilesystem VolumeMode = "filesystem"
)

// StorageClassInfo is read-only discovery metadata. The engine never creates,
// patches, deletes or recreates a StorageClass while discovering/adopting it.
type StorageClassInfo struct {
	Name              string
	Provisioner       string
	AllowExpansion    bool
	ReclaimPolicy     string
	VolumeBindingMode string
	Parameters        map[string]string
}

// Device is read-only physical/LUN discovery metadata. Discovery intentionally
// has no format, wipe, partition, zpool, vgcreate or other destructive methods.
type Device struct {
	Node          string
	Path          string
	DeviceType    string
	SizeBytes     uint64
	UsedBytes     uint64
	FreeBytes     uint64
	Serial        string
	WWID          string
	Filesystem    string
	VolumeGroup   string
	ZFSPool       string
	LINSTORPool   string
	Status        string
	VisibleNodes  []string
	ExistingUsers []string
}

// InUse reports whether discovery found explicit ownership/membership metadata.
// UsedBytes alone is intentionally not treated as proof that the device can be
// safely overwritten.
func (d Device) InUse() bool {
	return d.Filesystem != "" || d.VolumeGroup != "" || d.ZFSPool != "" || d.LINSTORPool != "" || len(d.ExistingUsers) > 0
}

// ProviderSupport is populated only by a provider-specific capability probe.
// All three readiness fields must be true before new dynamic storage is offered.
type ProviderSupport struct {
	ControllerInstalled  bool
	NodeIntegrationReady bool
	DynamicProvisioning  bool
	Reason               string
}

// ReadyForCreate is deliberately strict so the GUI cannot fake support by
// emitting a Kubernetes StorageClass without the required data path.
func (p ProviderSupport) ReadyForCreate() bool {
	return p.ControllerInstalled && p.NodeIntegrationReady && p.DynamicProvisioning
}

// DiscoverySnapshot is a side-effect-free observation of cluster storage state.
type DiscoverySnapshot struct {
	StorageClasses []StorageClassInfo
	CSIDrivers     []string
	Devices        []Device
	Providers      map[BackendType]ProviderSupport
}

// Capabilities are facts proven by discovery/provider integration.
type Capabilities struct {
	DynamicProvisioning bool
	Expansion           bool
	Snapshot            bool
	Replication         bool
	Shared              bool
	ThinProvisioning    bool
	ThickProvisioning   bool
	Block               bool
	Filesystem          bool
}

// Backend is the physical/external storage abstraction consumed by profiles.
type Backend struct {
	ID           string
	DisplayName  string
	Description  string
	Type         BackendType
	Mode         BackendMode
	Scope        ScopeType
	Nodes        []string
	Purposes     []Purpose
	StorageClass string // implementation detail; normally hidden from customers
	Capabilities Capabilities
	Provider     map[string]string
}

// Profile is the customer-facing storage policy selected by VM/backup/image flows.
type Profile struct {
	ID               string
	DisplayName      string
	Description      string
	BackendRef       string
	Provisioning     Provisioning
	Purposes         []Purpose
	VolumeMode       VolumeMode
	ExpansionAllowed bool
	ReplicationCount int
	PerformanceTier  string
	Nodes            []string
	ReclaimPolicy    string
}

// CatalogEntry tells the UI whether a backend can be adopted and/or newly
// created. CreateAvailable is never inferred from a friendly backend name.
type CatalogEntry struct {
	Type            BackendType
	AdoptAvailable  bool
	CreateAvailable bool
	Reason          string
}

// AdoptionResult contains only declarative product abstractions. It contains no
// mutation plan and therefore cannot initialize discovered media.
type AdoptionResult struct {
	Backends []Backend
	Profiles []Profile
}
