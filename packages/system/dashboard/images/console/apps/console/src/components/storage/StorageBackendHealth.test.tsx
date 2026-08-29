import { describe, expect, it, vi } from "vitest"
import { screen, within } from "@testing-library/react"
import { K8sClient, type K8sList } from "@cozystack/k8s-client"
import { renderWithK8sProvider } from "../../test-utils/render.tsx"
import { StorageBackendHealth } from "./StorageBackendHealth.tsx"

function list(items: unknown[]): K8sList<never> {
  return {
    apiVersion: "v1",
    kind: "List",
    metadata: {},
    items: items as never[],
  }
}

function pod(name: string, namespace: string, phase: string, ready: boolean, restarts = 0) {
  return {
    apiVersion: "v1",
    kind: "Pod",
    metadata: { name, namespace },
    status: {
      phase,
      containerStatuses: [{ name: "main", ready, restartCount: restarts }],
    },
  }
}

async function backendRow(name: string): Promise<HTMLElement> {
  const cell = await screen.findByText(name, { selector: "td", exact: true })
  const row = cell.closest("tr")
  if (!row) throw new Error(`backend row not found for ${name}`)
  return row
}

function makeClient({ inventory = true }: { inventory?: boolean } = {}): K8sClient {
  const client = new K8sClient()
  vi.spyOn(client, "list").mockImplementation(async (_group, _version, plural) => {
    if (plural === "storageclasses") {
      return list([
        {
          apiVersion: "storage.k8s.io/v1",
          kind: "StorageClass",
          metadata: { name: "local" },
          provisioner: "linstor.csi.linbit.com",
        },
        {
          apiVersion: "storage.k8s.io/v1",
          kind: "StorageClass",
          metadata: { name: "replicated" },
          provisioner: "linstor.csi.linbit.com",
        },
      ]) as never
    }
    if (plural === "pods") {
      return list([
        pod("linstor-controller-abc", "cozy-linstor", "Running", true),
        pod("linstor-csi-controller-abc", "cozy-linstor", "Running", true, 1),
        pod("linstor-csi-node-a", "cozy-linstor", "Running", true),
        pod("linstor-satellite.talos-a-abc", "cozy-linstor", "Running", true),
        pod("linstor-csi-nfs-server-a", "cozy-linstor", "Running", true),
        pod("linstor-csi-nfs-server-b", "cozy-linstor", "Running", true),
        pod("blockstor-apiserver-a", "blockstor-system", "Running", true),
        pod("blockstor-controller-a", "blockstor-system", "Running", true),
        pod("blockstor-satellite-a", "blockstor-system", "Pending", false),
        pod("blockstor-satellite-b", "blockstor-system", "Pending", false),
        pod("blockstor-satellite-c", "blockstor-system", "Pending", false),
      ]) as never
    }
    return list([]) as never
  })

  vi.spyOn(client, "get").mockImplementation(async (_group, _version, plural, name, namespace) => {
    if (plural === "configmaps" && name === "layersentry-storage-backend-inventory" && namespace === "cozy-system") {
      if (!inventory) throw new Error("not found")
      return {
        apiVersion: "v1",
        kind: "ConfigMap",
        metadata: { name, namespace },
        data: {
          "inventory.json": JSON.stringify({
            schemaVersion: "storage-backend.layersentry.io/v1alpha1",
            generatedAt: "2026-08-29T19:15:42.000Z",
            sourceCommit: "2e7cda17d42616f7bf93aaba6a895e03738599b2",
            sourceRun: "33270401611",
            readOnlyObservation: true,
            initializationAllowed: false,
            linstor: {
              clusterCount: 1,
              nodeCount: 3,
              dataPoolCount: 3,
              clusterReachable: true,
              capacity: "368/960GiB",
              availableCapacityBytes: 959925190656,
              freeCapacityBytes: 591926837248,
              pools: [
                { node: "TALOS-2B1AE", pool: "DATA", driver: "ZFS" },
                { node: "TALOS-5284C", pool: "DATA", driver: "ZFS" },
                { node: "TALOS-E8576", pool: "DATA", driver: "ZFS" },
              ],
            },
            blockstor: {
              storagePoolCount: 0,
              resourceCount: 0,
              nodeCount: 3,
              onlineNodes: 0,
              offlineNodes: 3,
              nodes: [
                {
                  node: "talos-2b1ae",
                  connectionStatus: "OFFLINE",
                  readyStatus: "Unknown",
                  readyReason: "NodeStatusNeverUpdated",
                },
                {
                  node: "talos-5284c",
                  connectionStatus: "OFFLINE",
                  readyStatus: "Unknown",
                  readyReason: "NodeStatusNeverUpdated",
                },
                {
                  node: "talos-e8576",
                  connectionStatus: "OFFLINE",
                  readyStatus: "Unknown",
                  readyReason: "NodeStatusNeverUpdated",
                },
              ],
            },
          }),
        },
      } as never
    }
    throw new Error(`unexpected get ${plural}/${name}`)
  })

  return client
}

describe("StorageBackendHealth", () => {
  it("separates workload readiness from registration and shows read-only pool inventory", async () => {
    renderWithK8sProvider(<StorageBackendHealth />, { client: makeClient() })

    expect(await screen.findByText("Backend operational health")).toBeInTheDocument()

    const linstorRow = await backendRow("LINSTOR")
    expect(within(linstorRow).getByText("2 classes")).toBeInTheDocument()
    expect(within(linstorRow).getByText("4 / 4 ready")).toBeInTheDocument()
    expect(within(linstorRow).getByText("Workloads ready")).toBeInTheDocument()

    const blockstorRow = await backendRow("Blockstor")
    expect(within(blockstorRow).getByText("None observed")).toBeInTheDocument()
    expect(within(blockstorRow).getByText("2 / 5 ready")).toBeInTheDocument()
    expect(within(blockstorRow).getByText("Degraded")).toBeInTheDocument()

    const nfsRow = await backendRow("NFS service")
    expect(within(nfsRow).getByText("2 / 2 ready")).toBeInTheDocument()
    expect(within(nfsRow).getByText("Workloads ready")).toBeInTheDocument()

    expect(await screen.findByText("Observed backend pools and capacity")).toBeInTheDocument()
    expect(screen.getByText("368/960GiB")).toBeInTheDocument()
    expect(screen.getByText("33270401611")).toBeInTheDocument()
    expect(screen.getByText("2e7cda17d426")).toBeInTheDocument()
    expect(screen.getByText("TALOS-2B1AE")).toBeInTheDocument()
    expect(screen.getAllByText("DATA")).toHaveLength(3)
    expect(screen.getAllByText("ZFS")).toHaveLength(3)
    expect(screen.getByText("0 / 3")).toBeInTheDocument()
    expect(screen.getByText("Offline / no pool")).toBeInTheDocument()
    expect(screen.getAllByText("NodeStatusNeverUpdated")).toHaveLength(3)
    expect(screen.getByText("Initialization remains locked")).toBeInTheDocument()

    expect(
      screen.getByText(/does not certify storage-pool integrity, successful PVC provisioning/i),
    ).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /wipe|format|initialize|create pool|import|mount/i })).toBeNull()
  })

  it("does not infer pool health when the backend inventory is unavailable", async () => {
    renderWithK8sProvider(<StorageBackendHealth />, { client: makeClient({ inventory: false }) })

    expect(await screen.findByText("Backend inventory unavailable")).toBeInTheDocument()
    expect(
      screen.getByText(/Capacity and pool health are not inferred from StorageClass registration or pod readiness/i),
    ).toBeInTheDocument()
    expect(screen.getByText("Initialization remains locked")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /wipe|format|initialize|create pool|import|mount/i })).toBeNull()
  })
})
