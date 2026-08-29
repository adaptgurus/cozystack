import { useMemo } from "react"
import {
  K8sApiError,
  useApiGroupAvailable,
  useK8sGet,
  useK8sList,
  type K8sResource,
} from "@cozystack/k8s-client"
import { Section, Spinner, StatusBadge } from "@cozystack/ui"
import { humanizeBytes, parseQuantity } from "../../lib/k8s-quantity.ts"

interface StorageClass extends K8sResource {
  provisioner?: string
  reclaimPolicy?: string
  volumeBindingMode?: string
  allowVolumeExpansion?: boolean
}

interface PersistentVolume extends K8sResource {
  spec?: {
    storageClassName?: string
    capacity?: { storage?: string }
    claimRef?: { namespace?: string; name?: string }
    csi?: { driver?: string }
    persistentVolumeReclaimPolicy?: string
  }
  status?: { phase?: string; message?: string; reason?: string }
}

interface PersistentVolumeClaim extends K8sResource {
  spec?: {
    storageClassName?: string
    volumeName?: string
    resources?: { requests?: { storage?: string } }
  }
  status?: { phase?: string; capacity?: { storage?: string } }
}

interface VolumeSnapshot extends K8sResource {
  spec?: {
    volumeSnapshotClassName?: string
    source?: { persistentVolumeClaimName?: string; volumeSnapshotContentName?: string }
  }
  status?: { readyToUse?: boolean; restoreSize?: string; error?: { message?: string } }
}

interface StorageInventoryConfigMap extends K8sResource {
  data?: Record<string, string>
}

interface CertifiedDisk {
  Node?: string
  Device?: string
  Size?: string
  Identity?: string
  ById?: string
  Model?: string
  Transport?: string
  Status?: string
  Reason?: string
  ExistingDataEvidence?: string
}

interface CertifiedInventory {
  generatedAt?: string
  sourceCommit?: string
  sourceRun?: string
  identityGate?: string
  initializationAllowed?: boolean
  blockedDevices?: number
  devices?: CertifiedDisk[]
}

const INVENTORY_REF = {
  apiGroup: "",
  apiVersion: "v1",
  plural: "configmaps",
  namespace: "cozy-system",
  name: "layersentry-storage-inventory",
}

function phaseTone(phase: string | undefined): "ok" | "warn" | "error" | "muted" {
  switch ((phase ?? "").toLowerCase()) {
    case "bound":
    case "available":
      return "ok"
    case "pending":
    case "released":
      return "warn"
    case "failed":
    case "lost":
      return "error"
    default:
      return "muted"
  }
}

function backendName(provisioner: string | undefined): string {
  const value = (provisioner ?? "").toLowerCase()
  if (value.includes("linstor")) return "LINSTOR"
  if (value.includes("blockstor")) return "Blockstor"
  if (value.includes("nfs")) return "NFS"
  if (value.includes("csi")) return "CSI"
  return provisioner ? "External" : "Unknown"
}

function parseCertifiedInventory(raw: string | undefined): CertifiedInventory | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as CertifiedInventory
    if (!parsed || !Array.isArray(parsed.devices)) return null
    return parsed
  } catch {
    return null
  }
}

function existingDataEvidence(value: string | undefined): string[] {
  return (value ?? "")
    .split(";")
    .map((item) => item.trim())
    .filter(Boolean)
}

function shortCommit(value: string | undefined): string {
  if (!value) return "unknown"
  return value.length > 12 ? value.slice(0, 12) : value
}

function MetricCard({
  label,
  value,
  detail,
  tone = "normal",
}: {
  label: string
  value: string | number
  detail: string
  tone?: "normal" | "warn" | "error"
}) {
  const valueClass =
    tone === "error" ? "text-red-700" : tone === "warn" ? "text-amber-700" : "text-slate-900"
  return (
    <div className="rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm">
      <p className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</p>
      <p className={`mt-1 text-2xl font-semibold tabular-nums ${valueClass}`}>{value}</p>
      <p className="mt-1 text-xs text-slate-500">{detail}</p>
    </div>
  )
}

/**
 * Read-only operational storage overview for the cluster administrator.
 *
 * Deliberate safety boundary: this component exposes no wipe, format, pool or
 * initialize action. Physical devices are shown only when the self-hosted Talos
 * certification workflow publishes a persistent hardware identity. Kernel
 * paths such as /dev/sdb remain observational metadata and are never treated as
 * device identity.
 */
export function StorageManagementOverview() {
  const storageClasses = useK8sList<StorageClass>({
    apiGroup: "storage.k8s.io",
    apiVersion: "v1",
    plural: "storageclasses",
  })
  const pvs = useK8sList<PersistentVolume>({
    apiGroup: "",
    apiVersion: "v1",
    plural: "persistentvolumes",
  })
  const pvcs = useK8sList<PersistentVolumeClaim>({
    apiGroup: "",
    apiVersion: "v1",
    plural: "persistentvolumeclaims",
  })
  const inventory = useK8sGet<StorageInventoryConfigMap>(INVENTORY_REF, {
    retry: false,
    refetchOnWindowFocus: false,
  })

  const snapshotApi = useApiGroupAvailable("snapshot.storage.k8s.io")
  const snapshots = useK8sList<VolumeSnapshot>(
    {
      apiGroup: "snapshot.storage.k8s.io",
      apiVersion: "v1",
      plural: "volumesnapshots",
    },
    { enabled: snapshotApi.available },
  )

  const classItems = storageClasses.data?.items ?? []
  const pvItems = pvs.data?.items ?? []
  const pvcItems = pvcs.data?.items ?? []
  const snapshotItems = snapshots.data?.items ?? []

  const boundClaims = pvcItems.filter((item) => item.status?.phase === "Bound").length
  const unhealthyClaims = pvcItems.filter((item) => ["Pending", "Lost"].includes(item.status?.phase ?? ""))
  const unhealthyPvs = pvItems.filter((item) => ["Failed", "Released"].includes(item.status?.phase ?? ""))
  const requestedBytes = pvcItems.reduce(
    (total, item) => total + parseQuantity(item.spec?.resources?.requests?.storage ?? "0"),
    0,
  )
  const readySnapshots = snapshotItems.filter((item) => item.status?.readyToUse === true).length

  const classRows = useMemo(() => {
    return classItems
      .map((storageClass) => {
        const name = storageClass.metadata.name
        return {
          storageClass,
          claims: pvcItems.filter((claim) => claim.spec?.storageClassName === name).length,
          volumes: pvItems.filter((pv) => pv.spec?.storageClassName === name).length,
        }
      })
      .sort((a, b) => a.storageClass.metadata.name.localeCompare(b.storageClass.metadata.name))
  }, [classItems, pvItems, pvcItems])

  const certifiedInventory = useMemo(
    () => parseCertifiedInventory(inventory.data?.data?.["inventory.json"]),
    [inventory.data],
  )
  const certifiedDisks = certifiedInventory?.devices ?? []
  const candidateDisks = certifiedDisks.filter((device) => device.Status === "CANDIDATE")
  const blockedDisks = certifiedDisks.filter((device) => device.Status !== "CANDIDATE")
  const inventoryGate = certifiedInventory?.identityGate ?? (blockedDisks.length > 0 ? "BLOCKED" : "UNKNOWN")
  const blockedDeviceCount = certifiedInventory?.blockedDevices ?? blockedDisks.length

  const baseLoading = storageClasses.isLoading || pvs.isLoading || pvcs.isLoading
  const baseError = storageClasses.error || pvs.error || pvcs.error
  const inventoryForbidden = inventory.error instanceof K8sApiError && inventory.error.status === 403

  if (baseLoading) {
    return (
      <div className="flex items-center gap-2 text-sm text-slate-500">
        <Spinner /> Loading storage management…
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {baseError ? (
        <Section>
          <p className="px-3 py-4 text-sm text-red-700">
            One or more storage resources could not be loaded. The dashboard remains read-only and
            initialization controls are locked.
          </p>
        </Section>
      ) : null}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <MetricCard
          label="Storage classes"
          value={classItems.length}
          detail={`${new Set(classItems.map((item) => item.provisioner ?? "unknown")).size} provisioner(s)`}
        />
        <MetricCard
          label="Claims"
          value={pvcItems.length}
          detail={`${boundClaims} bound · ${humanizeBytes(requestedBytes)} requested`}
          tone={unhealthyClaims.length > 0 ? "warn" : "normal"}
        />
        <MetricCard
          label="Persistent volumes"
          value={pvItems.length}
          detail={`${unhealthyPvs.length} released/failed`}
          tone={unhealthyPvs.length > 0 ? "warn" : "normal"}
        />
        <MetricCard
          label="Snapshots"
          value={snapshotApi.available ? snapshotItems.length : "N/A"}
          detail={
            snapshotApi.available
              ? `${readySnapshots} ready`
              : snapshotApi.isLoading
                ? "Discovering snapshot API"
                : "Snapshot API not registered"
          }
          tone={snapshotApi.available && readySnapshots < snapshotItems.length ? "warn" : "normal"}
        />
        <MetricCard
          label="Physical disks"
          value={certifiedDisks.length > 0 ? certifiedDisks.length : "Locked"}
          detail={
            certifiedDisks.length > 0
              ? `${candidateDisks.length} identity-certified · ${blockedDisks.length} blocked`
              : "Awaiting certified Talos inventory"
          }
          tone={blockedDisks.length > 0 || certifiedDisks.length === 0 ? "warn" : "normal"}
        />
      </div>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-sm font-semibold text-slate-900">Physical disk safety</h2>
              <p className="mt-0.5 text-xs text-slate-500">
                Persistent hardware identity is mandatory. Linux kernel names are observations only.
              </p>
            </div>
            <StatusBadge tone="warn">Initialization locked</StatusBadge>
          </div>

          {certifiedInventory ? (
            <div className="mt-3 grid grid-cols-2 gap-x-4 gap-y-2 rounded-md border border-slate-200 bg-slate-50 p-3 text-xs sm:grid-cols-3 xl:grid-cols-6">
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Inventory gate</p>
                <p className="mt-1 font-semibold text-slate-800">{inventoryGate}</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Last certified</p>
                <p className="mt-1 break-all text-slate-800">{certifiedInventory.generatedAt ?? "unknown"}</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Source run</p>
                <p className="mt-1 font-mono text-slate-800">{certifiedInventory.sourceRun ?? "unknown"}</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Source commit</p>
                <p className="mt-1 font-mono text-slate-800" title={certifiedInventory.sourceCommit}>
                  {shortCommit(certifiedInventory.sourceCommit)}
                </p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Blocked devices</p>
                <p className="mt-1 font-semibold tabular-nums text-slate-800">{blockedDeviceCount}</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Initialization</p>
                <p className="mt-1 font-semibold text-slate-800">
                  {certifiedInventory.initializationAllowed === true ? "Reported allowed; UI locked" : "Locked"}
                </p>
              </div>
            </div>
          ) : null}
        </div>

        {certifiedInventory?.initializationAllowed === true ? (
          <p className="border-b border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-800">
            Safety violation: the inventory report unexpectedly advertises initializationAllowed=true. This UI
            remains locked and exposes no destructive controls.
          </p>
        ) : null}

        {inventoryForbidden ? (
          <p className="px-4 py-5 text-sm text-red-700">
            You do not have permission to read the certified storage inventory.
          </p>
        ) : certifiedDisks.length === 0 ? (
          <div className="px-4 py-5 text-sm text-slate-600">
            <p className="font-medium text-slate-800">Awaiting certified inventory</p>
            <p className="mt-1">
              No persistent device identity report is available yet. Pool initialization remains
              disabled until WWID/WWN, NVMe NGUID/EUI, a validated /dev/disk/by-id alias, or another
              stable hardware identifier is independently verified.
            </p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50 text-left">
                  <th className="px-3 py-2 font-medium text-slate-600">Node</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Observed path</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Size</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Model / transport</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Persistent identity</th>
                  <th className="px-3 py-2 font-medium text-slate-600">By-id alias</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Certification</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Reason</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Existing-data evidence</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {certifiedDisks.map((device, index) => {
                  const candidate = device.Status === "CANDIDATE"
                  const evidence = existingDataEvidence(device.ExistingDataEvidence)
                  return (
                    <tr key={`${device.Node ?? "node"}-${device.Identity ?? device.Device ?? index}`}>
                      <td className="px-3 py-2 font-medium text-slate-800">{device.Node ?? "—"}</td>
                      <td className="px-3 py-2 font-mono text-xs text-slate-600">{device.Device ?? "—"}</td>
                      <td className="px-3 py-2 text-slate-600">{device.Size ?? "—"}</td>
                      <td className="px-3 py-2 text-xs text-slate-600">
                        <div>{device.Model || "—"}</div>
                        <div className="mt-0.5 font-mono text-slate-500">{device.Transport || "—"}</div>
                      </td>
                      <td className="px-3 py-2 font-mono text-xs text-slate-700">
                        {device.Identity || "NONE"}
                      </td>
                      <td className="max-w-[24rem] break-all px-3 py-2 font-mono text-xs text-slate-600">
                        {device.ById || "—"}
                      </td>
                      <td className="px-3 py-2">
                        <StatusBadge tone={candidate ? "ok" : "error"}>
                          {candidate ? "Identity certified" : "Blocked"}
                        </StatusBadge>
                      </td>
                      <td className="px-3 py-2 text-xs text-slate-600">{device.Reason || "—"}</td>
                      <td className="px-3 py-2 text-xs text-slate-600">
                        {evidence.length === 0 ? (
                          "—"
                        ) : (
                          <details className="min-w-[18rem]">
                            <summary className="cursor-pointer font-medium text-slate-700">
                              {evidence.length} evidence item{evidence.length === 1 ? "" : "s"}
                            </summary>
                            <ul className="mt-2 space-y-1">
                              {evidence.map((item, evidenceIndex) => (
                                <li
                                  key={`${item}-${evidenceIndex}`}
                                  className="break-all font-mono text-[11px] leading-4 text-slate-600"
                                >
                                  {item}
                                </li>
                              ))}
                            </ul>
                          </details>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
        <div className="border-t border-slate-200 bg-amber-50 px-4 py-3 text-xs text-amber-900">
          Identity certification does not authorize destructive operations. Wipe, partition, format,
          LVM/ZFS creation and StoragePool creation remain outside this UI until a separately reviewed
          initialization controller enforces the same identity and existing-data checks server-side.
        </div>
      </Section>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3">
          <h2 className="text-sm font-semibold text-slate-900">Storage backends and classes</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            Registered StorageClasses and their observed provisioners. Registration is not presented as
            backend health.
          </p>
        </div>
        {classRows.length === 0 ? (
          <p className="py-6 text-center text-sm text-slate-500">No StorageClasses found.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50 text-left">
                  <th className="px-3 py-2 font-medium text-slate-600">StorageClass</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Backend</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Provisioner</th>
                  <th className="px-3 py-2 text-right font-medium text-slate-600">Claims</th>
                  <th className="px-3 py-2 text-right font-medium text-slate-600">PVs</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Binding</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Expansion</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {classRows.map(({ storageClass, claims, volumes }) => (
                  <tr key={storageClass.metadata.name}>
                    <td className="px-3 py-2 font-medium text-slate-800">{storageClass.metadata.name}</td>
                    <td className="px-3 py-2 text-slate-600">{backendName(storageClass.provisioner)}</td>
                    <td className="px-3 py-2 font-mono text-xs text-slate-600">
                      {storageClass.provisioner ?? "—"}
                    </td>
                    <td className="px-3 py-2 text-right tabular-nums text-slate-700">{claims}</td>
                    <td className="px-3 py-2 text-right tabular-nums text-slate-700">{volumes}</td>
                    <td className="px-3 py-2 text-slate-600">{storageClass.volumeBindingMode ?? "—"}</td>
                    <td className="px-3 py-2">
                      <StatusBadge tone={storageClass.allowVolumeExpansion ? "ok" : "muted"}>
                        {storageClass.allowVolumeExpansion ? "Allowed" : "Not advertised"}
                      </StatusBadge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Section>

      <div className="grid grid-cols-1 gap-6 2xl:grid-cols-2">
        <Section>
          <div className="border-b border-slate-200 px-4 py-3">
            <h2 className="text-sm font-semibold text-slate-900">PersistentVolumeClaims</h2>
            <p className="mt-0.5 text-xs text-slate-500">Cluster-wide claim state; newest names sort first.</p>
          </div>
          {pvcItems.length === 0 ? (
            <p className="py-6 text-center text-sm text-slate-500">No claims found.</p>
          ) : (
            <div className="max-h-[28rem] overflow-auto">
              <table className="w-full text-sm">
                <thead className="sticky top-0 bg-slate-50">
                  <tr className="border-b border-slate-200 text-left">
                    <th className="px-3 py-2 font-medium text-slate-600">Claim</th>
                    <th className="px-3 py-2 font-medium text-slate-600">Class</th>
                    <th className="px-3 py-2 text-right font-medium text-slate-600">Requested</th>
                    <th className="px-3 py-2 font-medium text-slate-600">Phase</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {[...pvcItems]
                    .sort((a, b) =>
                      `${b.metadata.namespace}/${b.metadata.name}`.localeCompare(
                        `${a.metadata.namespace}/${a.metadata.name}`,
                      ),
                    )
                    .map((claim) => (
                      <tr key={`${claim.metadata.namespace}/${claim.metadata.name}`}>
                        <td className="px-3 py-2">
                          <div className="font-medium text-slate-800">{claim.metadata.name}</div>
                          <div className="text-xs text-slate-500">{claim.metadata.namespace ?? "—"}</div>
                        </td>
                        <td className="px-3 py-2 text-slate-600">{claim.spec?.storageClassName ?? "—"}</td>
                        <td className="px-3 py-2 text-right tabular-nums text-slate-700">
                          {humanizeBytes(parseQuantity(claim.spec?.resources?.requests?.storage ?? "0"))}
                        </td>
                        <td className="px-3 py-2">
                          <StatusBadge tone={phaseTone(claim.status?.phase)}>
                            {claim.status?.phase ?? "Unknown"}
                          </StatusBadge>
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          )}
        </Section>

        <Section>
          <div className="border-b border-slate-200 px-4 py-3">
            <h2 className="text-sm font-semibold text-slate-900">PersistentVolumes</h2>
            <p className="mt-0.5 text-xs text-slate-500">Volume phase, claim binding and CSI driver.</p>
          </div>
          {pvItems.length === 0 ? (
            <p className="py-6 text-center text-sm text-slate-500">No persistent volumes found.</p>
          ) : (
            <div className="max-h-[28rem] overflow-auto">
              <table className="w-full text-sm">
                <thead className="sticky top-0 bg-slate-50">
                  <tr className="border-b border-slate-200 text-left">
                    <th className="px-3 py-2 font-medium text-slate-600">Volume</th>
                    <th className="px-3 py-2 font-medium text-slate-600">Claim</th>
                    <th className="px-3 py-2 font-medium text-slate-600">Driver</th>
                    <th className="px-3 py-2 font-medium text-slate-600">Phase</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {[...pvItems]
                    .sort((a, b) => a.metadata.name.localeCompare(b.metadata.name))
                    .map((pv) => (
                      <tr key={pv.metadata.name}>
                        <td className="px-3 py-2">
                          <div className="max-w-[14rem] truncate font-medium text-slate-800" title={pv.metadata.name}>
                            {pv.metadata.name}
                          </div>
                          <div className="text-xs text-slate-500">{pv.spec?.storageClassName ?? "no class"}</div>
                        </td>
                        <td className="px-3 py-2 text-xs text-slate-600">
                          {pv.spec?.claimRef?.name
                            ? `${pv.spec.claimRef.namespace ?? "?"}/${pv.spec.claimRef.name}`
                            : "—"}
                        </td>
                        <td className="px-3 py-2 font-mono text-xs text-slate-600">{pv.spec?.csi?.driver ?? "—"}</td>
                        <td className="px-3 py-2">
                          <StatusBadge tone={phaseTone(pv.status?.phase)}>
                            {pv.status?.phase ?? "Unknown"}
                          </StatusBadge>
                        </td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          )}
        </Section>
      </div>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3">
          <h2 className="text-sm font-semibold text-slate-900">Snapshots and protection</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            CSI VolumeSnapshot readiness. Restore and destructive snapshot actions are intentionally not
            exposed by this operational overview.
          </p>
        </div>
        {snapshotApi.isLoading ? (
          <div className="flex items-center gap-2 px-4 py-5 text-sm text-slate-500">
            <Spinner /> Discovering snapshot API…
          </div>
        ) : !snapshotApi.available ? (
          <p className="px-4 py-5 text-sm text-slate-600">VolumeSnapshot API is not registered on this cluster.</p>
        ) : snapshots.error ? (
          <p className="px-4 py-5 text-sm text-red-700">VolumeSnapshots could not be read.</p>
        ) : snapshotItems.length === 0 ? (
          <p className="px-4 py-5 text-sm text-slate-600">No VolumeSnapshots found.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50 text-left">
                  <th className="px-3 py-2 font-medium text-slate-600">Snapshot</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Source PVC</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Class</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Restore size</th>
                  <th className="px-3 py-2 font-medium text-slate-600">State</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {snapshotItems.map((snapshot) => (
                  <tr key={`${snapshot.metadata.namespace}/${snapshot.metadata.name}`}>
                    <td className="px-3 py-2">
                      <div className="font-medium text-slate-800">{snapshot.metadata.name}</div>
                      <div className="text-xs text-slate-500">{snapshot.metadata.namespace ?? "—"}</div>
                    </td>
                    <td className="px-3 py-2 text-slate-600">
                      {snapshot.spec?.source?.persistentVolumeClaimName ?? "—"}
                    </td>
                    <td className="px-3 py-2 text-slate-600">{snapshot.spec?.volumeSnapshotClassName ?? "—"}</td>
                    <td className="px-3 py-2 text-slate-600">
                      {snapshot.status?.restoreSize
                        ? humanizeBytes(parseQuantity(snapshot.status.restoreSize))
                        : "—"}
                    </td>
                    <td className="px-3 py-2">
                      <StatusBadge
                        tone={snapshot.status?.readyToUse ? "ok" : snapshot.status?.error ? "error" : "warn"}
                      >
                        {snapshot.status?.readyToUse ? "Ready" : snapshot.status?.error ? "Error" : "Pending"}
                      </StatusBadge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Section>
    </div>
  )
}
