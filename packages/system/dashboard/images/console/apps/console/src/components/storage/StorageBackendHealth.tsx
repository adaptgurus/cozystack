import { useMemo } from "react"
import { useK8sGet, useK8sList, type K8sResource } from "@cozystack/k8s-client"
import { Section, Spinner, StatusBadge } from "@cozystack/ui"
import { humanizeBytes } from "../../lib/k8s-quantity.ts"

interface StorageClass extends K8sResource {
  provisioner?: string
}

interface Pod extends K8sResource {
  status?: {
    phase?: string
    containerStatuses?: Array<{
      ready?: boolean
      restartCount?: number
    }>
  }
}

interface BackendInventoryConfigMap extends K8sResource {
  data?: Record<string, string>
}

interface LinstorPoolObservation {
  node?: string
  pool?: string
  driver?: string
  freeSpaceManager?: string
}

interface LinstorConditionObservation {
  type?: string
  status?: string
  reason?: string
  message?: string
}

interface BlockstorNodeObservation {
  node?: string
  connectionStatus?: string
  readyStatus?: string
  readyReason?: string
  readyMessage?: string
}

interface StorageBackendInventory {
  generatedAt?: string
  sourceCommit?: string
  sourceRun?: string
  readOnlyObservation?: boolean
  initializationAllowed?: boolean
  linstor?: {
    clusterCount?: number
    nodeCount?: number
    dataPoolCount?: number
    clusterReachable?: boolean
    capacity?: string
    availableCapacityBytes?: number
    freeCapacityBytes?: number
    conditions?: LinstorConditionObservation[]
    pools?: LinstorPoolObservation[]
  }
  blockstor?: {
    storagePoolCount?: number
    resourceCount?: number
    nodeCount?: number
    onlineNodes?: number
    offlineNodes?: number
    nodes?: BlockstorNodeObservation[]
  }
}

type BackendKey = "linstor" | "blockstor" | "nfs"
type HealthTone = "ok" | "warn" | "error" | "muted"

interface BackendDefinition {
  key: BackendKey
  name: string
  scope: string
  matchesPod: (pod: Pod) => boolean
  matchesProvisioner: (provisioner: string) => boolean
}

const BACKEND_INVENTORY_REF = {
  apiGroup: "",
  apiVersion: "v1",
  plural: "configmaps",
  namespace: "cozy-system",
  name: "layersentry-storage-backend-inventory",
}

const BACKENDS: BackendDefinition[] = [
  {
    key: "linstor",
    name: "LINSTOR",
    scope: "Controller, CSI controller/node and satellite pods",
    matchesPod: (pod) => {
      if (pod.metadata.namespace !== "cozy-linstor") return false
      const name = pod.metadata.name
      return (
        name.startsWith("linstor-controller-") ||
        name.startsWith("linstor-csi-controller-") ||
        name.startsWith("linstor-csi-node-") ||
        name.startsWith("linstor-satellite.")
      )
    },
    matchesProvisioner: (provisioner) => provisioner.toLowerCase().includes("linstor"),
  },
  {
    key: "blockstor",
    name: "Blockstor",
    scope: "API, controller and satellite pods",
    matchesPod: (pod) =>
      pod.metadata.namespace === "blockstor-system" && pod.metadata.name.startsWith("blockstor-"),
    matchesProvisioner: (provisioner) => provisioner.toLowerCase().includes("blockstor"),
  },
  {
    key: "nfs",
    name: "NFS service",
    scope: "LINSTOR CSI NFS server pods",
    matchesPod: (pod) =>
      pod.metadata.namespace === "cozy-linstor" && pod.metadata.name.startsWith("linstor-csi-nfs-server-"),
    matchesProvisioner: (provisioner) => provisioner.toLowerCase().includes("nfs"),
  },
]

function isPodReady(pod: Pod): boolean {
  const statuses = pod.status?.containerStatuses ?? []
  return pod.status?.phase === "Running" && statuses.length > 0 && statuses.every((status) => status.ready === true)
}

function healthState(
  total: number,
  ready: number,
  registeredClasses: number,
): { label: string; tone: HealthTone } {
  if (total === 0) {
    return registeredClasses > 0
      ? { label: "Registration only", tone: "warn" }
      : { label: "Not observed", tone: "muted" }
  }
  if (ready === total) return { label: "Workloads ready", tone: "ok" }
  if (ready === 0) return { label: "Offline", tone: "error" }
  return { label: "Degraded", tone: "warn" }
}

function parseBackendInventory(raw: string | undefined): StorageBackendInventory | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as StorageBackendInventory
    if (!parsed || parsed.readOnlyObservation !== true || !parsed.linstor || !parsed.blockstor) return null
    return parsed
  } catch {
    return null
  }
}

function shortCommit(value: string | undefined): string {
  if (!value) return "unknown"
  return value.length > 12 ? value.slice(0, 12) : value
}

function freshness(generatedAt: string | undefined): { label: string; tone: HealthTone } {
  if (!generatedAt) return { label: "Timestamp missing", tone: "warn" }
  const generated = Date.parse(generatedAt)
  if (!Number.isFinite(generated)) return { label: "Timestamp invalid", tone: "warn" }
  const ageMs = Math.max(0, Date.now() - generated)
  if (ageMs > 6 * 60 * 60 * 1000) return { label: "Stale > 6h", tone: "warn" }
  return { label: "Fresh < 6h", tone: "ok" }
}

function byteValue(value: number | undefined): string {
  return value && value > 0 ? humanizeBytes(value) : "—"
}

/**
 * Live, read-only backend workload readiness plus a provenance-backed backend
 * inventory published by the TESTSER lab workflow.
 *
 * This deliberately does not equate StorageClass registration, pod readiness,
 * or pool discovery with successful provisioning, failover or data-survival
 * certification. Those remain separate storage delivery gates.
 */
export function StorageBackendHealth() {
  const storageClasses = useK8sList<StorageClass>({
    apiGroup: "storage.k8s.io",
    apiVersion: "v1",
    plural: "storageclasses",
  })
  const pods = useK8sList<Pod>({
    apiGroup: "",
    apiVersion: "v1",
    plural: "pods",
  })
  const backendInventory = useK8sGet<BackendInventoryConfigMap>(BACKEND_INVENTORY_REF, {
    retry: false,
    refetchOnWindowFocus: false,
  })

  const classItems = storageClasses.data?.items ?? []
  const podItems = pods.data?.items ?? []

  const rows = useMemo(
    () =>
      BACKENDS.map((backend) => {
        const backendPods = podItems.filter(backend.matchesPod)
        const readyPods = backendPods.filter(isPodReady).length
        const restarts = backendPods.reduce(
          (total, pod) =>
            total +
            (pod.status?.containerStatuses ?? []).reduce(
              (podTotal, status) => podTotal + (status.restartCount ?? 0),
              0,
            ),
          0,
        )
        const registeredClasses = classItems.filter((storageClass) =>
          backend.matchesProvisioner(storageClass.provisioner ?? ""),
        ).length
        return {
          backend,
          totalPods: backendPods.length,
          readyPods,
          restarts,
          registeredClasses,
          state: healthState(backendPods.length, readyPods, registeredClasses),
        }
      }),
    [classItems, podItems],
  )

  const observedInventory = useMemo(
    () => parseBackendInventory(backendInventory.data?.data?.["inventory.json"]),
    [backendInventory.data],
  )
  const inventoryFreshness = freshness(observedInventory?.generatedAt)
  const linstorPools = observedInventory?.linstor?.pools ?? []
  const blockstorNodes = observedInventory?.blockstor?.nodes ?? []
  const linstorObservedHealthy =
    observedInventory?.linstor?.clusterReachable === true && (observedInventory?.linstor?.dataPoolCount ?? 0) > 0
  const blockstorObservedHealthy =
    (observedInventory?.blockstor?.nodeCount ?? 0) > 0 &&
    observedInventory?.blockstor?.onlineNodes === observedInventory?.blockstor?.nodeCount &&
    (observedInventory?.blockstor?.storagePoolCount ?? 0) > 0

  const loading = storageClasses.isLoading || pods.isLoading
  const error = storageClasses.error || pods.error

  return (
    <div className="space-y-6">
      <Section>
        <div className="border-b border-slate-200 px-4 py-3">
          <h2 className="text-sm font-semibold text-slate-900">Backend operational health</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            Live Kubernetes workload readiness, kept separate from StorageClass registration and storage certification.
          </p>
        </div>

        {loading ? (
          <div className="flex items-center gap-2 px-4 py-5 text-sm text-slate-500">
            <Spinner /> Loading backend workload signals…
          </div>
        ) : error ? (
          <p className="px-4 py-5 text-sm text-red-700">
            Backend workload signals could not be read. No health assumption is made from StorageClass registration.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50 text-left">
                  <th className="px-3 py-2 font-medium text-slate-600">Backend</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Observed scope</th>
                  <th className="px-3 py-2 font-medium text-slate-600">StorageClass registration</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Pod readiness</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Restarts</th>
                  <th className="px-3 py-2 font-medium text-slate-600">Operational signal</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rows.map((row) => (
                  <tr key={row.backend.key}>
                    <td className="px-3 py-2 font-medium text-slate-800">{row.backend.name}</td>
                    <td className="px-3 py-2 text-xs text-slate-600">{row.backend.scope}</td>
                    <td className="px-3 py-2 text-slate-600">
                      {row.registeredClasses === 0
                        ? "None observed"
                        : `${row.registeredClasses} class${row.registeredClasses === 1 ? "" : "es"}`}
                    </td>
                    <td className="px-3 py-2 tabular-nums text-slate-700">
                      {row.readyPods} / {row.totalPods} ready
                    </td>
                    <td className="px-3 py-2 tabular-nums text-slate-700">{row.restarts}</td>
                    <td className="px-3 py-2">
                      <StatusBadge tone={row.state.tone}>{row.state.label}</StatusBadge>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <div className="border-t border-slate-200 bg-slate-50 px-4 py-3 text-xs text-slate-600">
          Pod readiness is an operational control-plane signal only. It does not certify storage-pool integrity,
          successful PVC provisioning, replication, failover, rebuild, or workload data survival.
        </div>
      </Section>

      <Section>
        <div className="border-b border-slate-200 px-4 py-3">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-sm font-semibold text-slate-900">Observed backend pools and capacity</h2>
              <p className="mt-0.5 text-xs text-slate-500">
                Read-only TESTSER inventory from backend APIs. This is discovery evidence, not initialization authority.
              </p>
            </div>
            <StatusBadge tone="warn">Initialization remains locked</StatusBadge>
          </div>
        </div>

        {backendInventory.isLoading ? (
          <div className="flex items-center gap-2 px-4 py-5 text-sm text-slate-500">
            <Spinner /> Loading observed backend inventory…
          </div>
        ) : !observedInventory ? (
          <div className="px-4 py-5 text-sm text-slate-600">
            <p className="font-medium text-slate-800">Backend inventory unavailable</p>
            <p className="mt-1">
              No valid read-only backend inventory is available. Capacity and pool health are not inferred from
              StorageClass registration or pod readiness.
            </p>
          </div>
        ) : (
          <>
            {observedInventory.initializationAllowed === true ? (
              <p className="border-b border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-800">
                Safety violation: backend inventory unexpectedly reports initializationAllowed=true. The dashboard
                remains locked and exposes no destructive storage controls.
              </p>
            ) : null}

            <div className="grid grid-cols-2 gap-x-4 gap-y-2 border-b border-slate-200 bg-slate-50 px-4 py-3 text-xs sm:grid-cols-3 xl:grid-cols-6">
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Observation freshness</p>
                <div className="mt-1"><StatusBadge tone={inventoryFreshness.tone}>{inventoryFreshness.label}</StatusBadge></div>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Generated</p>
                <p className="mt-1 break-all text-slate-800">{observedInventory.generatedAt ?? "unknown"}</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Source run</p>
                <p className="mt-1 font-mono text-slate-800">{observedInventory.sourceRun ?? "unknown"}</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Source commit</p>
                <p className="mt-1 font-mono text-slate-800" title={observedInventory.sourceCommit}>
                  {shortCommit(observedInventory.sourceCommit)}
                </p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Collection mode</p>
                <p className="mt-1 font-semibold text-slate-800">Read-only</p>
              </div>
              <div>
                <p className="font-medium uppercase tracking-wide text-slate-500">Initialization</p>
                <p className="mt-1 font-semibold text-slate-800">Locked</p>
              </div>
            </div>

            <div className="grid grid-cols-1 gap-4 p-4 xl:grid-cols-2">
              <div className="rounded-lg border border-slate-200 bg-white p-4">
                <div className="flex items-center justify-between gap-3">
                  <h3 className="text-sm font-semibold text-slate-900">LINSTOR observed state</h3>
                  <StatusBadge tone={linstorObservedHealthy ? "ok" : "error"}>
                    {linstorObservedHealthy ? "Pools observed" : "Backend warning"}
                  </StatusBadge>
                </div>
                <dl className="mt-3 grid grid-cols-2 gap-3 text-xs sm:grid-cols-3">
                  <div>
                    <dt className="text-slate-500">Cluster reachable</dt>
                    <dd className="mt-0.5 font-semibold text-slate-800">
                      {observedInventory.linstor?.clusterReachable ? "Yes" : "No"}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Nodes</dt>
                    <dd className="mt-0.5 font-semibold tabular-nums text-slate-800">
                      {observedInventory.linstor?.nodeCount ?? 0}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Data pools</dt>
                    <dd className="mt-0.5 font-semibold tabular-nums text-slate-800">
                      {observedInventory.linstor?.dataPoolCount ?? 0}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Reported capacity</dt>
                    <dd className="mt-0.5 font-semibold text-slate-800">
                      {observedInventory.linstor?.capacity || "—"}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Available capacity</dt>
                    <dd className="mt-0.5 font-semibold text-slate-800">
                      {byteValue(observedInventory.linstor?.availableCapacityBytes)}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Free capacity</dt>
                    <dd className="mt-0.5 font-semibold text-slate-800">
                      {byteValue(observedInventory.linstor?.freeCapacityBytes)}
                    </dd>
                  </div>
                </dl>

                {linstorPools.length > 0 ? (
                  <div className="mt-4 overflow-x-auto">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="border-b border-slate-200 text-left text-slate-500">
                          <th className="py-2 pr-3 font-medium">Node</th>
                          <th className="py-2 pr-3 font-medium">Pool</th>
                          <th className="py-2 font-medium">Driver</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100">
                        {linstorPools.map((pool, index) => (
                          <tr key={`${pool.node ?? "node"}-${pool.pool ?? "pool"}-${index}`}>
                            <td className="py-2 pr-3 font-mono text-slate-700">{pool.node ?? "—"}</td>
                            <td className="py-2 pr-3 font-medium text-slate-800">{pool.pool ?? "—"}</td>
                            <td className="py-2 font-mono text-slate-700">{pool.driver ?? "—"}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                ) : (
                  <p className="mt-4 text-xs text-amber-700">No non-diskless LINSTOR data pools were observed.</p>
                )}
              </div>

              <div className="rounded-lg border border-slate-200 bg-white p-4">
                <div className="flex items-center justify-between gap-3">
                  <h3 className="text-sm font-semibold text-slate-900">Blockstor observed state</h3>
                  <StatusBadge tone={blockstorObservedHealthy ? "ok" : "error"}>
                    {blockstorObservedHealthy ? "Pools online" : "Offline / no pool"}
                  </StatusBadge>
                </div>
                <dl className="mt-3 grid grid-cols-2 gap-3 text-xs sm:grid-cols-3">
                  <div>
                    <dt className="text-slate-500">Storage pools</dt>
                    <dd className="mt-0.5 font-semibold tabular-nums text-slate-800">
                      {observedInventory.blockstor?.storagePoolCount ?? 0}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Resources</dt>
                    <dd className="mt-0.5 font-semibold tabular-nums text-slate-800">
                      {observedInventory.blockstor?.resourceCount ?? 0}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Nodes online</dt>
                    <dd className="mt-0.5 font-semibold tabular-nums text-slate-800">
                      {observedInventory.blockstor?.onlineNodes ?? 0} / {observedInventory.blockstor?.nodeCount ?? 0}
                    </dd>
                  </div>
                </dl>

                {blockstorNodes.length > 0 ? (
                  <div className="mt-4 overflow-x-auto">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="border-b border-slate-200 text-left text-slate-500">
                          <th className="py-2 pr-3 font-medium">Node</th>
                          <th className="py-2 pr-3 font-medium">Connection</th>
                          <th className="py-2 font-medium">Reason</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100">
                        {blockstorNodes.map((node, index) => (
                          <tr key={`${node.node ?? "node"}-${index}`}>
                            <td className="py-2 pr-3 font-mono text-slate-700">{node.node ?? "—"}</td>
                            <td className="py-2 pr-3">
                              <StatusBadge tone={node.connectionStatus === "ONLINE" ? "ok" : "error"}>
                                {node.connectionStatus || "Unknown"}
                              </StatusBadge>
                            </td>
                            <td className="py-2 text-slate-700">{node.readyReason || node.readyMessage || "—"}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                ) : (
                  <p className="mt-4 text-xs text-amber-700">No Blockstor node status was observed.</p>
                )}
              </div>
            </div>
          </>
        )}

        <div className="border-t border-slate-200 bg-amber-50 px-4 py-3 text-xs text-amber-900">
          Pool discovery and capacity reporting remain read-only. Existing ZFS DATA pools are preserved; this dashboard
          provides no wipe, import, mount, format, pool-create or initialization action.
        </div>
      </Section>
    </div>
  )
}
