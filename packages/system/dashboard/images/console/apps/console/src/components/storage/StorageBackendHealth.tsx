import { useMemo } from "react"
import { useK8sList, type K8sResource } from "@cozystack/k8s-client"
import { Section, Spinner, StatusBadge } from "@cozystack/ui"

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

type BackendKey = "linstor" | "blockstor" | "nfs"

type HealthTone = "ok" | "warn" | "error" | "muted"

interface BackendDefinition {
  key: BackendKey
  name: string
  scope: string
  matchesPod: (pod: Pod) => boolean
  matchesProvisioner: (provisioner: string) => boolean
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

/**
 * Live, read-only backend workload readiness.
 *
 * This deliberately does not equate StorageClass registration or pod readiness
 * with successful provisioning, pool integrity, failover or data-survival
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

  const loading = storageClasses.isLoading || pods.isLoading
  const error = storageClasses.error || pods.error

  return (
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
  )
}
