import { useMemo, useState } from "react"
import {
  AlertTriangle,
  CheckCircle2,
  Database,
  HardDrive,
  Network,
  Plus,
  Server,
  ShieldCheck,
  X,
} from "lucide-react"
import { Section, Spinner } from "@cozystack/ui"
import { useK8sList, type K8sResource } from "@cozystack/k8s-client"
import { ClusterStorageSection } from "../components/cluster-usage/ClusterStorageSection.tsx"

type StorageClass = K8sResource & {
  provisioner?: string
  reclaimPolicy?: string
  allowVolumeExpansion?: boolean
  volumeBindingMode?: string
}

type CSINode = K8sResource & {
  spec?: { drivers?: Array<{ name?: string }> }
}

type PersistentVolume = K8sResource & {
  spec?: {
    storageClassName?: string
    capacity?: Record<string, string>
    volumeMode?: string
    csi?: { driver?: string; volumeHandle?: string }
    iscsi?: { targetPortal?: string; iqn?: string; lun?: number }
    fc?: { targetWWNs?: string[]; lun?: number }
    nfs?: { server?: string; path?: string }
    local?: { path?: string }
  }
  status?: { phase?: string }
}

type Tab = "backends" | "connectors" | "profiles" | "devices" | "kubernetes"
type ConnectorKind = "hci" | "local-zfs" | "lvm" | "lvm-thin" | "nfs" | "iscsi" | "fc" | "nvme-tcp" | "external-csi"
type ConnectorMode = "csi" | "direct"

interface ConnectorChoice {
  id: ConnectorKind
  label: string
  description: string
  modes: ConnectorMode[]
}

const CONNECTORS: ConnectorChoice[] = [
  { id: "hci", label: "HCI Replicated", description: "Built-in LINSTOR/ZFS replicated VM storage", modes: ["csi"] },
  { id: "local-zfs", label: "Local ZFS", description: "Node-local ZFS for fast local workloads", modes: ["csi", "direct"] },
  { id: "lvm", label: "LVM", description: "Thick local block storage on selected nodes", modes: ["csi", "direct"] },
  { id: "lvm-thin", label: "LVM Thin", description: "Thin-provisioned local block storage", modes: ["csi", "direct"] },
  { id: "nfs", label: "NFS", description: "Shared NAS storage for VMs, images and backups", modes: ["csi", "direct"] },
  { id: "iscsi", label: "iSCSI SAN", description: "Shared SAN LUNs with optional multipathing", modes: ["csi", "direct"] },
  { id: "fc", label: "Fibre Channel SAN", description: "FC LUNs using discovered HBA/WWPN paths", modes: ["csi", "direct"] },
  { id: "nvme-tcp", label: "NVMe/TCP", description: "High-performance external NVMe block storage", modes: ["csi", "direct"] },
  { id: "external-csi", label: "External CSI", description: "Adopt a vendor CSI driver and StorageClass", modes: ["csi"] },
]

function friendlyStorageName(name: string, provisioner: string) {
  if (name === "replicated") return "HCI Replicated"
  if (name === "local") return provisioner.toLowerCase().includes("zfs") ? "Local ZFS" : "Local Storage"
  return name
}

function backendType(name: string, provisioner: string) {
  const p = provisioner.toLowerCase()
  if (name === "replicated" || p.includes("linstor")) return "HCI / LINSTOR"
  if (p.includes("zfs")) return "ZFS"
  if (p.includes("nfs")) return "NFS"
  if (p.includes("iscsi")) return "iSCSI"
  if (p.includes("fc") || p.includes("fibre")) return "Fibre Channel"
  if (p.includes("nvme")) return "NVMe"
  if (p.includes("lvm")) return "LVM"
  return "CSI / Kubernetes"
}

function StatusPill({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${ok ? "bg-emerald-50 text-emerald-700" : "bg-amber-50 text-amber-700"}`}>
      {ok ? <CheckCircle2 className="size-3" /> : <AlertTriangle className="size-3" />}
      {children}
    </span>
  )
}

function MetricCard({ label, value, note, icon: Icon }: { label: string; value: string | number; note: string; icon: typeof HardDrive }) {
  return (
    <Section>
      <div className="flex items-start justify-between p-4">
        <div>
          <p className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</p>
          <p className="mt-1 text-2xl font-semibold text-slate-900">{value}</p>
          <p className="mt-1 text-xs text-slate-500">{note}</p>
        </div>
        <div className="rounded-lg bg-slate-100 p-2.5"><Icon className="size-5 text-slate-600" /></div>
      </div>
    </Section>
  )
}

/**
 * Customer-facing Storage Center. Kubernetes StorageClasses remain an
 * implementation detail; the primary concepts are Backends, Connectors and
 * Profiles. Direct host/SAN options are preflight-only until the storage
 * controller has verified node tooling, WWID identity and topology.
 */
export function StoragePage() {
  const [tab, setTab] = useState<Tab>("backends")
  const [wizardOpen, setWizardOpen] = useState(false)

  const storageClasses = useK8sList<StorageClass>({ apiGroup: "storage.k8s.io", apiVersion: "v1", plural: "storageclasses" })
  const csiDrivers = useK8sList<K8sResource>({ apiGroup: "storage.k8s.io", apiVersion: "v1", plural: "csidrivers" })
  const csiNodes = useK8sList<CSINode>({ apiGroup: "storage.k8s.io", apiVersion: "v1", plural: "csinodes" })
  const pvs = useK8sList<PersistentVolume>({ apiGroup: "", apiVersion: "v1", plural: "persistentvolumes" })
  const nodes = useK8sList<K8sResource>({ apiGroup: "", apiVersion: "v1", plural: "nodes" })

  const classes = storageClasses.data?.items ?? []
  const drivers = csiDrivers.data?.items ?? []
  const nodeItems = nodes.data?.items ?? []
  const volumes = pvs.data?.items ?? []
  const nodeCount = nodeItems.length

  const driverCoverage = useMemo(() => {
    const result = new Map<string, number>()
    for (const node of csiNodes.data?.items ?? []) {
      const seen = new Set<string>()
      for (const driver of node.spec?.drivers ?? []) {
        if (driver.name) seen.add(driver.name)
      }
      for (const driver of seen) result.set(driver, (result.get(driver) ?? 0) + 1)
    }
    return result
  }, [csiNodes.data])

  const loading = storageClasses.isLoading || csiDrivers.isLoading || csiNodes.isLoading || pvs.isLoading || nodes.isLoading
  const replicated = classes.find((sc) => sc.metadata.name === "replicated")
  const replicatedDriver = replicated?.provisioner ?? ""
  const replicatedReady = Boolean(replicated && replicatedDriver && nodeCount > 0 && (driverCoverage.get(replicatedDriver) ?? 0) === nodeCount)
  const directVolumes = volumes.filter((pv) => pv.spec?.iscsi || pv.spec?.fc || pv.spec?.nfs || pv.spec?.local)

  if (loading && classes.length === 0) {
    return <div className="flex items-center gap-2 p-8 text-sm text-slate-500"><Spinner /> Loading Storage Center…</div>
  }

  return (
    <div className="space-y-5 p-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <HardDrive className="size-6 text-slate-700" />
            <h1 className="text-xl font-semibold text-slate-900">Storage Center</h1>
          </div>
          <p className="mt-1 max-w-3xl text-sm text-slate-500">
            Manage HCI, local and external storage without working with raw Kubernetes storage objects.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setWizardOpen(true)}
          className="inline-flex items-center gap-1.5 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          <Plus className="size-4" /> Add Storage
        </button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard label="Backends" value={classes.length} note="Adopted and available" icon={Database} />
        <MetricCard label="CSI Drivers" value={drivers.length} note="Registered in cluster" icon={Network} />
        <MetricCard label="Storage Nodes" value={nodeCount} note="Cluster node scope" icon={Server} />
        <MetricCard label="Persistent Volumes" value={volumes.length} note={`${directVolumes.length} direct/static`} icon={HardDrive} />
      </div>

      <Section>
        <div className="flex flex-wrap gap-1 border-b border-slate-200 px-3 pt-2">
          {([
            ["backends", "Backends"],
            ["connectors", "Connectors"],
            ["profiles", "Storage Profiles"],
            ["devices", "Devices & LUNs"],
            ["kubernetes", "Advanced"],
          ] as Array<[Tab, string]>).map(([id, label]) => (
            <button
              key={id}
              type="button"
              onClick={() => setTab(id)}
              className={`rounded-t-md px-3 py-2 text-sm font-medium ${tab === id ? "border-b-2 border-blue-600 text-blue-700" : "text-slate-500 hover:text-slate-800"}`}
            >
              {label}
            </button>
          ))}
        </div>

        {tab === "backends" && (
          <div className="p-4">
            <div className="mb-3 flex items-center justify-between">
              <div>
                <h2 className="font-medium text-slate-900">Storage Backends</h2>
                <p className="text-xs text-slate-500">Physical or external storage presented with customer-friendly capabilities.</p>
              </div>
              {replicated && <StatusPill ok={replicatedReady}>{replicatedReady ? "HCI ready on all nodes" : "HCI topology check required"}</StatusPill>}
            </div>
            {classes.length === 0 ? (
              <p className="py-8 text-center text-sm text-slate-500">No storage backends discovered.</p>
            ) : (
              <div className="overflow-x-auto rounded-md border border-slate-200">
                <table className="w-full text-sm">
                  <thead className="bg-slate-50 text-left text-xs text-slate-500">
                    <tr><th className="px-3 py-2">Name</th><th className="px-3 py-2">Type</th><th className="px-3 py-2">Scope</th><th className="px-3 py-2">Provisioning</th><th className="px-3 py-2">Status</th></tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {classes.map((sc) => {
                      const name = sc.metadata.name ?? "unnamed"
                      const provisioner = sc.provisioner ?? ""
                      const coverage = driverCoverage.get(provisioner) ?? 0
                      const ready = provisioner !== "" && nodeCount > 0 && coverage === nodeCount
                      return (
                        <tr key={name} className="hover:bg-slate-50">
                          <td className="px-3 py-3"><div className="font-medium text-slate-800">{friendlyStorageName(name, provisioner)}</div><div className="text-xs text-slate-400">{name}</div></td>
                          <td className="px-3 py-3 text-slate-600">{backendType(name, provisioner)}</td>
                          <td className="px-3 py-3 text-slate-600">{name === "local" ? "Node-local" : "Cluster"}</td>
                          <td className="px-3 py-3 text-slate-600">{provisioner ? "Dynamic" : "Static"}</td>
                          <td className="px-3 py-3"><StatusPill ok={ready}>{ready ? `Ready ${coverage}/${nodeCount}` : `Verify ${coverage}/${nodeCount}`}</StatusPill></td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {tab === "connectors" && (
          <div className="p-4">
            <h2 className="font-medium text-slate-900">Storage Connectors</h2>
            <p className="mb-4 text-xs text-slate-500">CSI provides dynamic provisioning. Direct mode is capability-gated and never assumes host tools or SAN ownership.</p>
            <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
              {CONNECTORS.map((connector) => {
                const isCSIOnly = connector.modes.length === 1 && connector.modes[0] === "csi"
                const observedCSI = connector.id === "hci"
                  ? Boolean(replicated)
                  : connector.id === "external-csi"
                    ? drivers.length > 0
                    : classes.some((sc) => backendType(sc.metadata.name ?? "", sc.provisioner ?? "").toLowerCase().includes(connector.id.split("-")[0]))
                return (
                  <button key={connector.id} type="button" onClick={() => setWizardOpen(true)} className="rounded-lg border border-slate-200 p-4 text-left hover:border-blue-300 hover:bg-blue-50/30">
                    <div className="flex items-start justify-between gap-2">
                      <div><p className="font-medium text-slate-800">{connector.label}</p><p className="mt-1 text-xs text-slate-500">{connector.description}</p></div>
                      <StatusPill ok={observedCSI}>{observedCSI ? "Detected" : isCSIOnly ? "Driver required" : "Preflight"}</StatusPill>
                    </div>
                    <div className="mt-3 flex flex-wrap gap-1.5">
                      {connector.modes.includes("csi") && <span className="rounded bg-slate-100 px-2 py-1 text-[11px] text-slate-600">CSI</span>}
                      {connector.modes.includes("direct") && <span className="rounded bg-slate-100 px-2 py-1 text-[11px] text-slate-600">Without CSI</span>}
                      {(connector.id === "iscsi" || connector.id === "fc") && <span className="rounded bg-slate-100 px-2 py-1 text-[11px] text-slate-600">Multipath</span>}
                    </div>
                  </button>
                )
              })}
            </div>
          </div>
        )}

        {tab === "profiles" && (
          <div className="p-4">
            <h2 className="font-medium text-slate-900">Storage Profiles</h2>
            <p className="mb-4 text-xs text-slate-500">Profiles are what VM, image and backup workflows select; raw StorageClass names stay hidden in normal provisioning.</p>
            <div className="grid gap-3 lg:grid-cols-2">
              {classes.map((sc) => {
                const name = sc.metadata.name ?? "unnamed"
                const provisioner = sc.provisioner ?? ""
                const replicatedProfile = name === "replicated"
                return (
                  <div key={name} className="rounded-lg border border-slate-200 p-4">
                    <div className="flex items-center justify-between gap-2"><p className="font-medium text-slate-800">{replicatedProfile ? "HCI Gold – Replicated" : `${friendlyStorageName(name, provisioner)} Profile`}</p><ShieldCheck className="size-4 text-slate-400" /></div>
                    <div className="mt-3 grid grid-cols-2 gap-2 text-xs text-slate-600">
                      <div><span className="text-slate-400">VM disks</span><br />Allowed</div>
                      <div><span className="text-slate-400">Expansion</span><br />{sc.allowVolumeExpansion ? "Allowed" : "Provider default"}</div>
                      <div><span className="text-slate-400">Protection</span><br />{replicatedProfile ? "Replicated" : "Backend policy"}</div>
                      <div><span className="text-slate-400">Binding</span><br />{sc.volumeBindingMode ?? "Provider default"}</div>
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {tab === "devices" && (
          <div className="p-4">
            <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
              <div className="flex items-start gap-2"><AlertTriangle className="mt-0.5 size-4 shrink-0" /><div><strong>Safe discovery only.</strong> Opening this page never formats or initializes a disk. Local disks and SAN LUNs become selectable only after stable WWID/serial identity and node visibility are proven by the host probe.</div></div>
            </div>
            <h2 className="mt-4 font-medium text-slate-900">Attached / Published Volumes</h2>
            <p className="mb-3 text-xs text-slate-500">Kubernetes-visible direct storage. Raw unclaimed host disks remain in the protected host discovery path.</p>
            {directVolumes.length === 0 ? (
              <p className="rounded-md border border-dashed border-slate-300 py-8 text-center text-sm text-slate-500">No direct/static NFS, iSCSI, FC or local PV attachments found.</p>
            ) : (
              <div className="overflow-x-auto rounded-md border border-slate-200">
                <table className="w-full text-sm"><thead className="bg-slate-50 text-left text-xs text-slate-500"><tr><th className="px-3 py-2">Volume</th><th className="px-3 py-2">Transport</th><th className="px-3 py-2">Identity / Target</th><th className="px-3 py-2">State</th></tr></thead>
                  <tbody className="divide-y divide-slate-100">{directVolumes.map((pv) => {
                    const transport = pv.spec?.iscsi ? "iSCSI" : pv.spec?.fc ? "Fibre Channel" : pv.spec?.nfs ? "NFS" : "Local"
                    const identity = pv.spec?.iscsi ? `${pv.spec.iscsi.targetPortal ?? ""} · ${pv.spec.iscsi.iqn ?? ""} · LUN ${pv.spec.iscsi.lun ?? "?"}` : pv.spec?.fc ? `${(pv.spec.fc.targetWWNs ?? []).join(", ")} · LUN ${pv.spec.fc.lun ?? "?"}` : pv.spec?.nfs ? `${pv.spec.nfs.server ?? ""}:${pv.spec.nfs.path ?? ""}` : pv.spec?.local?.path ?? ""
                    return <tr key={pv.metadata.name}><td className="px-3 py-3 font-medium text-slate-800">{pv.metadata.name}</td><td className="px-3 py-3 text-slate-600">{transport}</td><td className="px-3 py-3 font-mono text-xs text-slate-500">{identity || "—"}</td><td className="px-3 py-3"><StatusPill ok={pv.status?.phase === "Bound"}>{pv.status?.phase ?? "Unknown"}</StatusPill></td></tr>
                  })}</tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {tab === "kubernetes" && <div className="p-4"><div className="mb-3"><h2 className="font-medium text-slate-900">Advanced Kubernetes Details</h2><p className="text-xs text-slate-500">Implementation-level PVC and StorageClass usage for platform administrators.</p></div><ClusterStorageSection /></div>}
      </Section>

      {wizardOpen && <AddStorageWizard classes={classes} drivers={drivers} nodeCount={nodeCount} driverCoverage={driverCoverage} onClose={() => setWizardOpen(false)} />}
    </div>
  )
}

function AddStorageWizard({ classes, drivers, nodeCount, driverCoverage, onClose }: { classes: StorageClass[]; drivers: K8sResource[]; nodeCount: number; driverCoverage: Map<string, number>; onClose: () => void }) {
  const [kind, setKind] = useState<ConnectorKind>("hci")
  const choice = CONNECTORS.find((item) => item.id === kind) ?? CONNECTORS[0]
  const [mode, setMode] = useState<ConnectorMode>(choice.modes[0])
  const [name, setName] = useState("")
  const [scope, setScope] = useState("all")
  const [storageClass, setStorageClass] = useState(classes[0]?.metadata.name ?? "")
  const [server, setServer] = useState("")
  const [exportPath, setExportPath] = useState("")
  const [portal, setPortal] = useState("")
  const [target, setTarget] = useState("")
  const [lun, setLun] = useState("0")
  const [wwid, setWwid] = useState("")
  const [vg, setVg] = useState("")
  const [thinPool, setThinPool] = useState("")
  const [multipath, setMultipath] = useState(true)
  const [result, setResult] = useState<{ ok: boolean; message: string } | null>(null)

  const changeKind = (next: ConnectorKind) => {
    const nextChoice = CONNECTORS.find((item) => item.id === next) ?? CONNECTORS[0]
    setKind(next)
    setMode(nextChoice.modes[0])
    setResult(null)
  }

  const preflight = () => {
    if (!name.trim()) return setResult({ ok: false, message: "Enter a storage name." })
    if (mode === "csi") {
      const selected = classes.find((sc) => sc.metadata.name === storageClass)
      if (!selected) return setResult({ ok: false, message: "Select a discovered StorageClass." })
      const driver = selected.provisioner ?? ""
      const driverObject = drivers.some((item) => item.metadata.name === driver)
      const coverage = driverCoverage.get(driver) ?? 0
      if (!driverObject || nodeCount === 0 || coverage !== nodeCount) return setResult({ ok: false, message: `CSI driver ${driver || "(unknown)"} is not verified on every storage node (${coverage}/${nodeCount}).` })
      return setResult({ ok: true, message: `CSI path verified on ${coverage}/${nodeCount} nodes. This backend can be safely adopted without recreating the StorageClass.` })
    }
    if ((kind === "lvm" || kind === "lvm-thin") && !vg.trim()) return setResult({ ok: false, message: "Enter the volume group to use on the selected node(s)." })
    if (kind === "lvm-thin" && !thinPool.trim()) return setResult({ ok: false, message: "Enter the LVM thin-pool name." })
    if (kind === "nfs" && (!server.trim() || !exportPath.trim())) return setResult({ ok: false, message: "NFS requires server and export path." })
    if ((kind === "iscsi" || kind === "fc") && (!target.trim() || !wwid.trim() || lun.trim() === "")) return setResult({ ok: false, message: `${kind === "iscsi" ? "iSCSI" : "FC"} direct attach requires target identity, LUN and verified WWID.` })
    if (kind === "iscsi" && !portal.trim()) return setResult({ ok: false, message: "iSCSI direct attach requires at least one portal." })
    return setResult({ ok: false, message: "Configuration is valid syntactically, but direct host storage remains blocked until the three-node Talos capability probe verifies LVM/iSCSI/FC/NVMe tooling, WWID visibility and multipath state." })
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/40 p-4">
      <div className="max-h-[90vh] w-full max-w-3xl overflow-y-auto rounded-xl bg-white shadow-2xl">
        <div className="flex items-start justify-between border-b border-slate-200 p-5"><div><h2 className="text-lg font-semibold text-slate-900">Add Storage</h2><p className="text-sm text-slate-500">Connect storage using CSI or a verified direct host path.</p></div><button type="button" onClick={onClose} className="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-slate-700"><X className="size-5" /></button></div>
        <div className="space-y-5 p-5">
          <div><label className="mb-1 block text-sm font-medium text-slate-700">Storage type</label><select value={kind} onChange={(e) => changeKind(e.target.value as ConnectorKind)} className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm">{CONNECTORS.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}</select><p className="mt-1 text-xs text-slate-500">{choice.description}</p></div>
          <div className="grid gap-4 md:grid-cols-2"><div><label className="mb-1 block text-sm font-medium text-slate-700">Name</label><input value={name} onChange={(e) => setName(e.target.value)} placeholder="san-gold" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div><div><label className="mb-1 block text-sm font-medium text-slate-700">Node scope</label><select value={scope} onChange={(e) => setScope(e.target.value)} className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"><option value="all">All nodes</option><option value="selected">Selected nodes</option><option value="single">Single node</option></select></div></div>
          <div><label className="mb-2 block text-sm font-medium text-slate-700">Connection mode</label><div className="grid gap-2 sm:grid-cols-2">{choice.modes.map((item) => <button key={item} type="button" onClick={() => { setMode(item); setResult(null) }} className={`rounded-lg border p-3 text-left ${mode === item ? "border-blue-500 bg-blue-50" : "border-slate-200"}`}><p className="text-sm font-medium text-slate-800">{item === "csi" ? "Use CSI driver" : "Without CSI / Direct"}</p><p className="mt-1 text-xs text-slate-500">{item === "csi" ? "Dynamic provisioning through a registered CSI driver." : "Static/direct host attachment with strict WWID and tooling preflight."}</p></button>)}</div></div>

          {mode === "csi" && <div><label className="mb-1 block text-sm font-medium text-slate-700">Discovered CSI storage</label><select value={storageClass} onChange={(e) => setStorageClass(e.target.value)} className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"><option value="">Select…</option>{classes.map((sc) => <option key={sc.metadata.name} value={sc.metadata.name}>{friendlyStorageName(sc.metadata.name ?? "", sc.provisioner ?? "")} — {sc.provisioner}</option>)}</select></div>}

          {mode === "direct" && kind === "nfs" && <div className="grid gap-4 md:grid-cols-2"><div><label className="mb-1 block text-sm font-medium text-slate-700">NFS server</label><input value={server} onChange={(e) => setServer(e.target.value)} placeholder="10.20.30.40" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div><div><label className="mb-1 block text-sm font-medium text-slate-700">Export</label><input value={exportPath} onChange={(e) => setExportPath(e.target.value)} placeholder="/vm-storage" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div></div>}

          {mode === "direct" && (kind === "lvm" || kind === "lvm-thin") && <div className="grid gap-4 md:grid-cols-2"><div><label className="mb-1 block text-sm font-medium text-slate-700">Volume Group</label><input value={vg} onChange={(e) => setVg(e.target.value)} placeholder="layersentry-vm" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div>{kind === "lvm-thin" && <div><label className="mb-1 block text-sm font-medium text-slate-700">Thin Pool</label><input value={thinPool} onChange={(e) => setThinPool(e.target.value)} placeholder="vm-thin" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div>}</div>}

          {mode === "direct" && (kind === "iscsi" || kind === "fc") && <div className="space-y-4">{kind === "iscsi" && <div><label className="mb-1 block text-sm font-medium text-slate-700">Portal(s)</label><input value={portal} onChange={(e) => setPortal(e.target.value)} placeholder="10.20.0.10:3260, 10.20.1.10:3260" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div>}<div><label className="mb-1 block text-sm font-medium text-slate-700">{kind === "iscsi" ? "Target IQN" : "Target WWN(s)"}</label><input value={target} onChange={(e) => setTarget(e.target.value)} placeholder={kind === "iscsi" ? "iqn.2026-08.example:array.vm" : "50:00:..."} className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div><div className="grid gap-4 md:grid-cols-2"><div><label className="mb-1 block text-sm font-medium text-slate-700">LUN</label><input type="number" min="0" value={lun} onChange={(e) => setLun(e.target.value)} className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" /></div><div><label className="mb-1 block text-sm font-medium text-slate-700">WWID</label><input value={wwid} onChange={(e) => setWwid(e.target.value)} placeholder="3600..." className="w-full rounded-md border border-slate-300 px-3 py-2 font-mono text-sm" /></div></div><label className="flex items-center gap-2 text-sm text-slate-700"><input type="checkbox" checked={multipath} onChange={(e) => setMultipath(e.target.checked)} /> Enable multipathing</label></div>}

          <div className="rounded-md bg-slate-50 p-3 text-xs text-slate-600"><strong>Safety:</strong> this wizard never formats a discovered device. Direct LVM/SAN initialization remains a separate guarded operation requiring stable identity, ownership checks and explicit destructive confirmation.</div>
          {result && <div className={`rounded-md border p-3 text-sm ${result.ok ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-amber-200 bg-amber-50 text-amber-800"}`}><div className="flex gap-2">{result.ok ? <CheckCircle2 className="mt-0.5 size-4 shrink-0" /> : <AlertTriangle className="mt-0.5 size-4 shrink-0" />}<span>{result.message}</span></div></div>}
        </div>
        <div className="flex items-center justify-end gap-2 border-t border-slate-200 px-5 py-4"><button type="button" onClick={onClose} className="rounded-md border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">Cancel</button><button type="button" onClick={preflight} className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700">Run preflight</button></div>
      </div>
    </div>
  )
}
