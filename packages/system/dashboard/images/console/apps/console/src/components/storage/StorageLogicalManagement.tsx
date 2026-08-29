import { useMemo, useState } from "react"
import {
  useK8sClient,
  useK8sList,
  useSelfSubjectAccessReview,
  type K8sResource,
} from "@cozystack/k8s-client"
import { Button, Section, Spinner, StatusBadge } from "@cozystack/ui"

const DEFAULT_STORAGE_CLASS = "storageclass.kubernetes.io/is-default-class"
const DEFAULT_SNAPSHOT_CLASS = "snapshot.storage.kubernetes.io/is-default-class"
const NO_DELETE_LABEL = "platform.cozystack.io/no-delete"

type Tone = "ok" | "warn" | "error" | "muted"

interface StorageClass extends K8sResource {
  provisioner: string
  parameters?: Record<string, string>
  reclaimPolicy?: string
  allowVolumeExpansion?: boolean
  volumeBindingMode?: string
  mountOptions?: string[]
  allowedTopologies?: unknown[]
}

interface PersistentVolumeClaim extends K8sResource {
  spec?: {
    accessModes?: string[]
    storageClassName?: string
    volumeName?: string
    resources?: { requests?: { storage?: string } }
    dataSource?: {
      apiGroup?: string
      kind?: string
      name?: string
    }
  }
  status?: {
    phase?: string
    capacity?: { storage?: string }
    conditions?: Array<{ type?: string; status?: string; reason?: string; message?: string }>
  }
}

interface VolumeSnapshot extends K8sResource {
  spec?: {
    volumeSnapshotClassName?: string
    source?: { persistentVolumeClaimName?: string }
  }
  status?: {
    readyToUse?: boolean
    restoreSize?: string
    error?: { message?: string; time?: string }
  }
}

interface VolumeSnapshotClass extends K8sResource {
  driver?: string
  deletionPolicy?: string
}

interface CSIDriver extends K8sResource {
  spec?: {
    attachRequired?: boolean
    podInfoOnMount?: boolean
    storageCapacity?: boolean
    fsGroupPolicy?: string
    volumeLifecycleModes?: string[]
  }
}

function isDefaultStorageClass(item: StorageClass): boolean {
  return item.metadata.annotations?.[DEFAULT_STORAGE_CLASS] === "true"
}

function isDefaultSnapshotClass(item: VolumeSnapshotClass): boolean {
  return item.metadata.annotations?.[DEFAULT_SNAPSHOT_CLASS] === "true"
}

function quantityBytes(value: string | undefined): number | null {
  if (!value) return null
  const match = value.trim().match(/^([0-9]+(?:\.[0-9]+)?)(Ki|Mi|Gi|Ti|Pi|K|M|G|T|P)?$/)
  if (!match) return null
  const number = Number(match[1])
  if (!Number.isFinite(number)) return null
  const suffix = match[2] ?? ""
  const powers: Record<string, number> = {
    "": 1,
    K: 1_000,
    M: 1_000_000,
    G: 1_000_000_000,
    T: 1_000_000_000_000,
    P: 1_000_000_000_000_000,
    Ki: 1024,
    Mi: 1024 ** 2,
    Gi: 1024 ** 3,
    Ti: 1024 ** 4,
    Pi: 1024 ** 5,
  }
  return number * powers[suffix]
}

function pvcTone(phase: string | undefined): Tone {
  if (phase === "Bound") return "ok"
  if (phase === "Pending") return "warn"
  if (phase === "Lost") return "error"
  return "muted"
}

function snapshotTone(snapshot: VolumeSnapshot): Tone {
  if (snapshot.status?.error?.message) return "error"
  if (snapshot.status?.readyToUse) return "ok"
  return "warn"
}

function cloneStorageClass(source: StorageClass, name: string, makeDefault: boolean): StorageClass {
  const annotations = { ...(source.metadata.annotations ?? {}) }
  if (makeDefault) annotations[DEFAULT_STORAGE_CLASS] = "true"
  else delete annotations[DEFAULT_STORAGE_CLASS]

  return {
    apiVersion: "storage.k8s.io/v1",
    kind: "StorageClass",
    metadata: {
      name,
      labels: { ...(source.metadata.labels ?? {}), "app.kubernetes.io/managed-by": "cozystack-dashboard" },
      annotations,
    },
    provisioner: source.provisioner,
    parameters: source.parameters ? { ...source.parameters } : undefined,
    reclaimPolicy: source.reclaimPolicy,
    allowVolumeExpansion: source.allowVolumeExpansion,
    volumeBindingMode: source.volumeBindingMode,
    mountOptions: source.mountOptions ? [...source.mountOptions] : undefined,
    allowedTopologies: source.allowedTopologies ? structuredClone(source.allowedTopologies) : undefined,
  }
}

function cleanName(value: string): string {
  return value.trim().toLowerCase()
}

export function StorageLogicalManagement() {
  const client = useK8sClient()
  const storageClasses = useK8sList<StorageClass>({
    apiGroup: "storage.k8s.io",
    apiVersion: "v1",
    plural: "storageclasses",
  })
  const pvcs = useK8sList<PersistentVolumeClaim>({ apiGroup: "", apiVersion: "v1", plural: "persistentvolumeclaims" })
  const snapshots = useK8sList<VolumeSnapshot>({
    apiGroup: "snapshot.storage.k8s.io",
    apiVersion: "v1",
    plural: "volumesnapshots",
  })
  const snapshotClasses = useK8sList<VolumeSnapshotClass>({
    apiGroup: "snapshot.storage.k8s.io",
    apiVersion: "v1",
    plural: "volumesnapshotclasses",
  })
  const csiDrivers = useK8sList<CSIDriver>({
    apiGroup: "storage.k8s.io",
    apiVersion: "v1",
    plural: "csidrivers",
  })

  const canCreateClass = useSelfSubjectAccessReview({ resourceAttributes: { verb: "create", group: "storage.k8s.io", version: "v1", resource: "storageclasses" } })
  const canPatchClass = useSelfSubjectAccessReview({ resourceAttributes: { verb: "patch", group: "storage.k8s.io", version: "v1", resource: "storageclasses" } })
  const canDeleteClass = useSelfSubjectAccessReview({ resourceAttributes: { verb: "delete", group: "storage.k8s.io", version: "v1", resource: "storageclasses" } })
  const canCreatePvc = useSelfSubjectAccessReview({ resourceAttributes: { namespace: "default", verb: "create", group: "", version: "v1", resource: "persistentvolumeclaims" } })
  const canPatchPvc = useSelfSubjectAccessReview({ resourceAttributes: { namespace: "default", verb: "patch", group: "", version: "v1", resource: "persistentvolumeclaims" } })
  const canDeletePvc = useSelfSubjectAccessReview({ resourceAttributes: { namespace: "default", verb: "delete", group: "", version: "v1", resource: "persistentvolumeclaims" } })
  const canCreateSnapshot = useSelfSubjectAccessReview({ resourceAttributes: { namespace: "default", verb: "create", group: "snapshot.storage.k8s.io", version: "v1", resource: "volumesnapshots" } })
  const canDeleteSnapshot = useSelfSubjectAccessReview({ resourceAttributes: { namespace: "default", verb: "delete", group: "snapshot.storage.k8s.io", version: "v1", resource: "volumesnapshots" } })

  const classItems = storageClasses.data?.items ?? []
  const pvcItems = pvcs.data?.items ?? []
  const snapshotItems = snapshots.data?.items ?? []
  const snapshotClassItems = snapshotClasses.data?.items ?? []
  const driverItems = csiDrivers.data?.items ?? []

  const [cloneSource, setCloneSource] = useState("")
  const [cloneName, setCloneName] = useState("")
  const [cloneDefault, setCloneDefault] = useState(false)
  const [claimNamespace, setClaimNamespace] = useState("default")
  const [claimName, setClaimName] = useState("")
  const [claimClass, setClaimClass] = useState("")
  const [claimSize, setClaimSize] = useState("10Gi")
  const [claimMode, setClaimMode] = useState("ReadWriteOnce")
  const [snapshotNamespace, setSnapshotNamespace] = useState("default")
  const [snapshotName, setSnapshotName] = useState("")
  const [snapshotPvc, setSnapshotPvc] = useState("")
  const [snapshotClass, setSnapshotClass] = useState("")
  const [busy, setBusy] = useState("")

  const defaultClass = classItems.find(isDefaultStorageClass)
  const defaultSnapshotClass = snapshotClassItems.find(isDefaultSnapshotClass)

  const claimsPerClass = useMemo(() => {
    const counts = new Map<string, number>()
    for (const pvc of pvcItems) {
      const name = pvc.spec?.storageClassName
      if (name) counts.set(name, (counts.get(name) ?? 0) + 1)
    }
    return counts
  }, [pvcItems])

  const snapshotPvcOptions = pvcItems.filter((pvc) => pvc.metadata.namespace === snapshotNamespace)
  const loading = storageClasses.isLoading || pvcs.isLoading || snapshots.isLoading || snapshotClasses.isLoading || csiDrivers.isLoading

  const refresh = async () => {
    await Promise.all([
      storageClasses.refetch(),
      pvcs.refetch(),
      snapshots.refetch(),
      snapshotClasses.refetch(),
      csiDrivers.refetch(),
    ])
  }

  const handleCloneClass = async () => {
    const name = cleanName(cloneName)
    const source = classItems.find((item) => item.metadata.name === cloneSource)
    if (!canCreateClass.allowed) return alert("Your account is not authorized to create StorageClasses.")
    if (!source) return alert("Choose an observed StorageClass to clone.")
    if (!name || !/^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/.test(name)) return alert("Enter a valid Kubernetes StorageClass name.")
    if (classItems.some((item) => item.metadata.name === name)) return alert("That StorageClass already exists.")

    setBusy("clone-class")
    try {
      await client.create("storage.k8s.io", "v1", "storageclasses", cloneStorageClass(source, name, cloneDefault))
      if (cloneDefault) {
        for (const current of classItems.filter(isDefaultStorageClass)) {
          await client.patch("storage.k8s.io", "v1", "storageclasses", current.metadata.name, {
            metadata: { annotations: { [DEFAULT_STORAGE_CLASS]: "false" } },
          })
        }
      }
      setCloneName("")
      setCloneDefault(false)
      await refresh()
    } catch (error) {
      alert(`Failed to create StorageClass: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleSetDefault = async (target: StorageClass) => {
    if (!canPatchClass.allowed) return alert("Your account is not authorized to change the default StorageClass.")
    if (!confirm(`Make ${target.metadata.name} the only default StorageClass?`)) return
    setBusy(`default:${target.metadata.name}`)
    try {
      for (const item of classItems) {
        const value = item.metadata.name === target.metadata.name ? "true" : "false"
        if (item.metadata.annotations?.[DEFAULT_STORAGE_CLASS] === value) continue
        await client.patch("storage.k8s.io", "v1", "storageclasses", item.metadata.name, {
          metadata: { annotations: { [DEFAULT_STORAGE_CLASS]: value } },
        })
      }
      await refresh()
    } catch (error) {
      alert(`Failed to change default StorageClass: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleDeleteClass = async (item: StorageClass) => {
    if (!canDeleteClass.allowed) return alert("Your account is not authorized to delete StorageClasses.")
    const inUse = claimsPerClass.get(item.metadata.name) ?? 0
    if (inUse > 0) return alert(`Deletion blocked: ${inUse} PVC(s) still reference ${item.metadata.name}.`)
    if (item.metadata.labels?.[NO_DELETE_LABEL] === "true") return alert("Deletion blocked by platform no-delete protection.")
    if (!confirm(`Delete StorageClass ${item.metadata.name}? Existing PV data is not touched by this action.`)) return
    setBusy(`delete-class:${item.metadata.name}`)
    try {
      await client.delete("storage.k8s.io", "v1", "storageclasses", item.metadata.name)
      await refresh()
    } catch (error) {
      alert(`Failed to delete StorageClass: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleCreatePvc = async () => {
    const namespace = claimNamespace.trim()
    const name = cleanName(claimName)
    const sizeBytes = quantityBytes(claimSize)
    if (!canCreatePvc.allowed) return alert("Your account is not authorized to create PVCs.")
    if (!namespace || !name) return alert("Namespace and claim name are required.")
    if (!claimClass) return alert("Choose a StorageClass.")
    if (sizeBytes === null || sizeBytes <= 0) return alert("Enter a valid positive Kubernetes storage quantity, for example 10Gi.")

    const body: PersistentVolumeClaim = {
      apiVersion: "v1",
      kind: "PersistentVolumeClaim",
      metadata: { name, namespace, labels: { "app.kubernetes.io/managed-by": "cozystack-dashboard" } },
      spec: {
        accessModes: [claimMode],
        storageClassName: claimClass,
        resources: { requests: { storage: claimSize.trim() } },
      },
    }
    setBusy("create-pvc")
    try {
      await client.create("", "v1", "persistentvolumeclaims", body, namespace)
      setClaimName("")
      await refresh()
    } catch (error) {
      alert(`Failed to create PVC: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleExpandPvc = async (pvc: PersistentVolumeClaim) => {
    if (!canPatchPvc.allowed) return alert("Your account is not authorized to expand PVCs.")
    const sc = classItems.find((item) => item.metadata.name === pvc.spec?.storageClassName)
    if (!sc?.allowVolumeExpansion) return alert("This StorageClass does not advertise allowVolumeExpansion=true.")
    const current = pvc.status?.capacity?.storage ?? pvc.spec?.resources?.requests?.storage
    const requested = prompt(`Current size is ${current ?? "unknown"}. Enter a larger size:`, current ?? "")
    if (!requested) return
    const currentBytes = quantityBytes(current)
    const requestedBytes = quantityBytes(requested)
    if (currentBytes === null || requestedBytes === null) return alert("Unable to compare storage quantities safely.")
    if (requestedBytes <= currentBytes) return alert("PVC shrink or same-size update is blocked. Expansion must be strictly larger.")
    const namespace = pvc.metadata.namespace
    if (!namespace) return alert("PVC namespace is missing.")

    setBusy(`expand:${namespace}/${pvc.metadata.name}`)
    try {
      await client.patch("", "v1", "persistentvolumeclaims", pvc.metadata.name, {
        spec: { resources: { requests: { storage: requested.trim() } } },
      }, namespace)
      await refresh()
    } catch (error) {
      alert(`Failed to expand PVC: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleDeletePvc = async (pvc: PersistentVolumeClaim) => {
    if (!canDeletePvc.allowed) return alert("Your account is not authorized to delete PVCs.")
    const namespace = pvc.metadata.namespace
    if (!namespace) return alert("PVC namespace is missing.")
    if (!confirm(`Delete PVC ${namespace}/${pvc.metadata.name}? The StorageClass reclaim policy determines backend volume cleanup.`)) return
    setBusy(`delete-pvc:${namespace}/${pvc.metadata.name}`)
    try {
      await client.delete("", "v1", "persistentvolumeclaims", pvc.metadata.name, namespace)
      await refresh()
    } catch (error) {
      alert(`Failed to delete PVC: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleCreateSnapshot = async () => {
    const namespace = snapshotNamespace.trim()
    const name = cleanName(snapshotName)
    const chosenClass = snapshotClass || defaultSnapshotClass?.metadata.name
    if (!canCreateSnapshot.allowed) return alert("Your account is not authorized to create VolumeSnapshots.")
    if (!namespace || !name || !snapshotPvc) return alert("Namespace, snapshot name and source PVC are required.")
    if (!chosenClass) return alert("No VolumeSnapshotClass is available.")

    const body: VolumeSnapshot = {
      apiVersion: "snapshot.storage.k8s.io/v1",
      kind: "VolumeSnapshot",
      metadata: { name, namespace, labels: { "app.kubernetes.io/managed-by": "cozystack-dashboard" } },
      spec: {
        volumeSnapshotClassName: chosenClass,
        source: { persistentVolumeClaimName: snapshotPvc },
      },
    }
    setBusy("create-snapshot")
    try {
      await client.create("snapshot.storage.k8s.io", "v1", "volumesnapshots", body, namespace)
      setSnapshotName("")
      await refresh()
    } catch (error) {
      alert(`Failed to create snapshot: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleDeleteSnapshot = async (snapshot: VolumeSnapshot) => {
    if (!canDeleteSnapshot.allowed) return alert("Your account is not authorized to delete VolumeSnapshots.")
    const namespace = snapshot.metadata.namespace
    if (!namespace) return alert("Snapshot namespace is missing.")
    if (!confirm(`Delete snapshot ${namespace}/${snapshot.metadata.name}? SnapshotClass deletionPolicy is enforced by CSI.`)) return
    setBusy(`delete-snapshot:${namespace}/${snapshot.metadata.name}`)
    try {
      await client.delete("snapshot.storage.k8s.io", "v1", "volumesnapshots", snapshot.metadata.name, namespace)
      await refresh()
    } catch (error) {
      alert(`Failed to delete snapshot: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  const handleRestoreSnapshot = async (snapshot: VolumeSnapshot) => {
    if (!canCreatePvc.allowed) return alert("Your account is not authorized to restore snapshots into PVCs.")
    if (!snapshot.status?.readyToUse) return alert("Snapshot restore is blocked until readyToUse=true.")
    const namespace = snapshot.metadata.namespace
    if (!namespace) return alert("Snapshot namespace is missing.")
    const sourceName = snapshot.spec?.source?.persistentVolumeClaimName
    const sourcePvc = pvcItems.find((item) => item.metadata.namespace === namespace && item.metadata.name === sourceName)
    if (!sourcePvc?.spec?.storageClassName) return alert("The source PVC StorageClass could not be determined.")
    const restoredName = prompt("Name for restored PVC:", `${snapshot.metadata.name}-restore`)
    if (!restoredName) return
    const size = snapshot.status.restoreSize ?? sourcePvc.spec.resources?.requests?.storage
    if (!size) return alert("Restore size could not be determined safely.")

    const body: PersistentVolumeClaim = {
      apiVersion: "v1",
      kind: "PersistentVolumeClaim",
      metadata: { name: cleanName(restoredName), namespace, labels: { "app.kubernetes.io/managed-by": "cozystack-dashboard" } },
      spec: {
        accessModes: sourcePvc.spec.accessModes ?? ["ReadWriteOnce"],
        storageClassName: sourcePvc.spec.storageClassName,
        resources: { requests: { storage: size } },
        dataSource: {
          apiGroup: "snapshot.storage.k8s.io",
          kind: "VolumeSnapshot",
          name: snapshot.metadata.name,
        },
      },
    }

    setBusy(`restore:${namespace}/${snapshot.metadata.name}`)
    try {
      await client.create("", "v1", "persistentvolumeclaims", body, namespace)
      await refresh()
    } catch (error) {
      alert(`Failed to restore snapshot: ${(error as Error).message}`)
    } finally {
      setBusy("")
    }
  }

  return (
    <div className="space-y-6">
      <Section>
        <div className="border-b border-slate-200 px-4 py-3">
          <h2 className="text-sm font-semibold text-slate-900">Logical storage lifecycle</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            Permission-gated Kubernetes storage administration. These controls never initialize, format, import or mount physical disks.
          </p>
        </div>
        {loading ? (
          <div className="flex items-center gap-2 p-5 text-sm text-slate-500"><Spinner /> Loading storage resources…</div>
        ) : (
          <div className="grid gap-5 p-5 xl:grid-cols-2">
            <div className="space-y-3 rounded-lg border border-slate-200 p-4">
              <div>
                <h3 className="text-sm font-semibold text-slate-900">Clone StorageClass</h3>
                <p className="text-xs text-slate-500">Copies the observed provisioner and parameters instead of guessing backend settings.</p>
              </div>
              <select value={cloneSource} onChange={(e) => setCloneSource(e.target.value)} className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
                <option value="">Select source StorageClass</option>
                {classItems.map((item) => <option key={item.metadata.name} value={item.metadata.name}>{item.metadata.name}</option>)}
              </select>
              <input value={cloneName} onChange={(e) => setCloneName(e.target.value)} placeholder="new-storage-class" className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              <label className="flex items-center gap-2 text-sm text-slate-700"><input type="checkbox" checked={cloneDefault} onChange={(e) => setCloneDefault(e.target.checked)} /> Make this the only default class</label>
              <Button variant="primary" size="sm" onClick={handleCloneClass} disabled={!canCreateClass.allowed || busy !== "" || classItems.length === 0}>{busy === "clone-class" ? "Creating…" : "Create from observed class"}</Button>
              {!canCreateClass.allowed && <p className="text-xs text-amber-700">Create permission is not granted; this control is fail-closed.</p>}
            </div>

            <div className="space-y-3 rounded-lg border border-slate-200 p-4">
              <div>
                <h3 className="text-sm font-semibold text-slate-900">Create PVC</h3>
                <p className="text-xs text-slate-500">Provision RWO or RWX storage from an existing StorageClass.</p>
              </div>
              <div className="grid grid-cols-2 gap-2">
                <input value={claimNamespace} onChange={(e) => setClaimNamespace(e.target.value)} placeholder="namespace" className="rounded-lg border border-slate-300 px-3 py-2 text-sm" />
                <input value={claimName} onChange={(e) => setClaimName(e.target.value)} placeholder="claim-name" className="rounded-lg border border-slate-300 px-3 py-2 text-sm" />
              </div>
              <select value={claimClass} onChange={(e) => setClaimClass(e.target.value)} className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
                <option value="">Select StorageClass{defaultClass ? ` (default: ${defaultClass.metadata.name})` : ""}</option>
                {classItems.map((item) => <option key={item.metadata.name} value={item.metadata.name}>{item.metadata.name} — {item.provisioner}</option>)}
              </select>
              <div className="grid grid-cols-2 gap-2">
                <input value={claimSize} onChange={(e) => setClaimSize(e.target.value)} placeholder="10Gi" className="rounded-lg border border-slate-300 px-3 py-2 text-sm" />
                <select value={claimMode} onChange={(e) => setClaimMode(e.target.value)} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"><option value="ReadWriteOnce">RWO</option><option value="ReadWriteMany">RWX</option></select>
              </div>
              <Button variant="primary" size="sm" onClick={handleCreatePvc} disabled={!canCreatePvc.allowed || busy !== ""}>{busy === "create-pvc" ? "Provisioning…" : "Create PVC"}</Button>
              {!canCreatePvc.allowed && <p className="text-xs text-amber-700">PVC create permission is not granted; provisioning is fail-closed.</p>}
            </div>

            <div className="space-y-3 rounded-lg border border-slate-200 p-4 xl:col-span-2">
              <div>
                <h3 className="text-sm font-semibold text-slate-900">Create snapshot</h3>
                <p className="text-xs text-slate-500">Uses the cluster CSI snapshot API. Default: {defaultSnapshotClass?.metadata.name ?? "not observed"}.</p>
              </div>
              <div className="grid gap-2 md:grid-cols-4">
                <input value={snapshotNamespace} onChange={(e) => { setSnapshotNamespace(e.target.value); setSnapshotPvc("") }} placeholder="namespace" className="rounded-lg border border-slate-300 px-3 py-2 text-sm" />
                <input value={snapshotName} onChange={(e) => setSnapshotName(e.target.value)} placeholder="snapshot-name" className="rounded-lg border border-slate-300 px-3 py-2 text-sm" />
                <select value={snapshotPvc} onChange={(e) => setSnapshotPvc(e.target.value)} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Source PVC</option>{snapshotPvcOptions.map((item) => <option key={item.metadata.name} value={item.metadata.name}>{item.metadata.name}</option>)}</select>
                <select value={snapshotClass} onChange={(e) => setSnapshotClass(e.target.value)} className="rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"><option value="">Default snapshot class</option>{snapshotClassItems.map((item) => <option key={item.metadata.name} value={item.metadata.name}>{item.metadata.name}</option>)}</select>
              </div>
              <Button variant="primary" size="sm" onClick={handleCreateSnapshot} disabled={!canCreateSnapshot.allowed || busy !== ""}>{busy === "create-snapshot" ? "Creating…" : "Create VolumeSnapshot"}</Button>
            </div>
          </div>
        )}
      </Section>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3"><h2 className="text-sm font-semibold text-slate-900">StorageClasses</h2></div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm"><thead><tr className="border-b border-slate-200 bg-slate-50 text-left"><th className="px-3 py-2">Name</th><th className="px-3 py-2">Provisioner</th><th className="px-3 py-2">Default</th><th className="px-3 py-2">Expansion</th><th className="px-3 py-2">Reclaim</th><th className="px-3 py-2">PVCs</th><th className="px-3 py-2">Actions</th></tr></thead>
            <tbody className="divide-y divide-slate-100">{classItems.map((item) => { const inUse = claimsPerClass.get(item.metadata.name) ?? 0; return <tr key={item.metadata.name}><td className="px-3 py-2 font-medium">{item.metadata.name}</td><td className="px-3 py-2 text-xs">{item.provisioner}</td><td className="px-3 py-2"><StatusBadge tone={isDefaultStorageClass(item) ? "ok" : "muted"}>{isDefaultStorageClass(item) ? "Default" : "No"}</StatusBadge></td><td className="px-3 py-2">{item.allowVolumeExpansion ? "Yes" : "No"}</td><td className="px-3 py-2">{item.reclaimPolicy ?? "—"}</td><td className="px-3 py-2">{inUse}</td><td className="px-3 py-2"><div className="flex gap-2"><Button size="sm" variant="outline" onClick={() => handleSetDefault(item)} disabled={!canPatchClass.allowed || busy !== "" || isDefaultStorageClass(item)}>Set default</Button><Button size="sm" variant="outline" onClick={() => handleDeleteClass(item)} disabled={!canDeleteClass.allowed || busy !== "" || inUse > 0 || item.metadata.labels?.[NO_DELETE_LABEL] === "true"}>Delete</Button></div></td></tr> })}</tbody></table>
        </div>
      </Section>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3"><h2 className="text-sm font-semibold text-slate-900">PersistentVolumeClaims</h2><p className="mt-0.5 text-xs text-slate-500">Shrink is prohibited. Expansion is enabled only when the selected StorageClass advertises support.</p></div>
        <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr className="border-b border-slate-200 bg-slate-50 text-left"><th className="px-3 py-2">Claim</th><th className="px-3 py-2">Class</th><th className="px-3 py-2">Mode</th><th className="px-3 py-2">Requested / Capacity</th><th className="px-3 py-2">State</th><th className="px-3 py-2">Actions</th></tr></thead><tbody className="divide-y divide-slate-100">{pvcItems.map((pvc) => { const phase = pvc.status?.phase ?? "Unknown"; const sc = classItems.find((item) => item.metadata.name === pvc.spec?.storageClassName); return <tr key={`${pvc.metadata.namespace}/${pvc.metadata.name}`}><td className="px-3 py-2 font-medium">{pvc.metadata.namespace}/{pvc.metadata.name}</td><td className="px-3 py-2">{pvc.spec?.storageClassName ?? "—"}</td><td className="px-3 py-2">{(pvc.spec?.accessModes ?? []).join(", ") || "—"}</td><td className="px-3 py-2">{pvc.spec?.resources?.requests?.storage ?? "—"} / {pvc.status?.capacity?.storage ?? "—"}</td><td className="px-3 py-2"><StatusBadge tone={pvcTone(phase)}>{phase}</StatusBadge>{pvc.status?.conditions?.some((c) => c.status === "True") && <div className="mt-1 text-xs text-amber-700">{pvc.status.conditions.filter((c) => c.status === "True").map((c) => c.message || c.reason || c.type).join("; ")}</div>}</td><td className="px-3 py-2"><div className="flex gap-2"><Button size="sm" variant="outline" onClick={() => handleExpandPvc(pvc)} disabled={!canPatchPvc.allowed || busy !== "" || !sc?.allowVolumeExpansion}>Expand</Button><Button size="sm" variant="outline" onClick={() => handleDeletePvc(pvc)} disabled={!canDeletePvc.allowed || busy !== ""}>Delete</Button></div></td></tr> })}</tbody></table></div>
      </Section>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3"><h2 className="text-sm font-semibold text-slate-900">VolumeSnapshots</h2></div>
        <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr className="border-b border-slate-200 bg-slate-50 text-left"><th className="px-3 py-2">Snapshot</th><th className="px-3 py-2">Source PVC</th><th className="px-3 py-2">Class</th><th className="px-3 py-2">State</th><th className="px-3 py-2">Restore size</th><th className="px-3 py-2">Actions</th></tr></thead><tbody className="divide-y divide-slate-100">{snapshotItems.map((snapshot) => <tr key={`${snapshot.metadata.namespace}/${snapshot.metadata.name}`}><td className="px-3 py-2 font-medium">{snapshot.metadata.namespace}/{snapshot.metadata.name}</td><td className="px-3 py-2">{snapshot.spec?.source?.persistentVolumeClaimName ?? "—"}</td><td className="px-3 py-2">{snapshot.spec?.volumeSnapshotClassName ?? "—"}</td><td className="px-3 py-2"><StatusBadge tone={snapshotTone(snapshot)}>{snapshot.status?.error?.message ? "Error" : snapshot.status?.readyToUse ? "Ready" : "Pending"}</StatusBadge>{snapshot.status?.error?.message && <div className="mt-1 max-w-md text-xs text-red-700">{snapshot.status.error.message}</div>}</td><td className="px-3 py-2">{snapshot.status?.restoreSize ?? "—"}</td><td className="px-3 py-2"><div className="flex gap-2"><Button size="sm" variant="outline" onClick={() => handleRestoreSnapshot(snapshot)} disabled={!canCreatePvc.allowed || busy !== "" || !snapshot.status?.readyToUse}>Restore</Button><Button size="sm" variant="outline" onClick={() => handleDeleteSnapshot(snapshot)} disabled={!canDeleteSnapshot.allowed || busy !== ""}>Delete</Button></div></td></tr>)}</tbody></table></div>
      </Section>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3"><h2 className="text-sm font-semibold text-slate-900">CSI capabilities</h2><p className="mt-0.5 text-xs text-slate-500">Live CSIDriver objects; capability visibility is separate from provisioning certification.</p></div>
        <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr className="border-b border-slate-200 bg-slate-50 text-left"><th className="px-3 py-2">Driver</th><th className="px-3 py-2">Attach</th><th className="px-3 py-2">Capacity tracking</th><th className="px-3 py-2">FSGroup</th><th className="px-3 py-2">Lifecycle modes</th></tr></thead><tbody className="divide-y divide-slate-100">{driverItems.map((driver) => <tr key={driver.metadata.name}><td className="px-3 py-2 font-medium">{driver.metadata.name}</td><td className="px-3 py-2">{driver.spec?.attachRequired === false ? "Not required" : "Required"}</td><td className="px-3 py-2">{driver.spec?.storageCapacity ? "Yes" : "No"}</td><td className="px-3 py-2">{driver.spec?.fsGroupPolicy ?? "—"}</td><td className="px-3 py-2">{(driver.spec?.volumeLifecycleModes ?? []).join(", ") || "—"}</td></tr>)}</tbody></table></div>
      </Section>

      <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-900">
        Physical storage safety boundary: logical operations above never grant dashboard write access to PersistentVolumes, LayerSentry inventory ConfigMaps, Talos block devices, ZFS pools, LINSTOR storage pools, mounts or disk initialization.
      </div>
    </div>
  )
}
