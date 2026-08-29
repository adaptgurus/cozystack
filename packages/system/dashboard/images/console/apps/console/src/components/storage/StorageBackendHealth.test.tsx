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

function makeClient(): K8sClient {
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
  return client
}

describe("StorageBackendHealth", () => {
  it("separates workload readiness from registration and surfaces a degraded backend", async () => {
    renderWithK8sProvider(<StorageBackendHealth />, { client: makeClient() })

    expect(await screen.findByText("Backend operational health")).toBeInTheDocument()

    const linstorRow = await screen.findByRole("row", { name: /LINSTOR/ })
    expect(within(linstorRow).getByText("2 classes")).toBeInTheDocument()
    expect(within(linstorRow).getByText("4 / 4 ready")).toBeInTheDocument()
    expect(within(linstorRow).getByText("Workloads ready")).toBeInTheDocument()

    const blockstorRow = screen.getByRole("row", { name: /Blockstor/ })
    expect(within(blockstorRow).getByText("None observed")).toBeInTheDocument()
    expect(within(blockstorRow).getByText("2 / 5 ready")).toBeInTheDocument()
    expect(within(blockstorRow).getByText("Degraded")).toBeInTheDocument()

    const nfsRow = screen.getByRole("row", { name: /NFS service/ })
    expect(within(nfsRow).getByText("2 / 2 ready")).toBeInTheDocument()
    expect(within(nfsRow).getByText("Workloads ready")).toBeInTheDocument()

    expect(
      screen.getByText(/does not certify storage-pool integrity, successful PVC provisioning/i),
    ).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /wipe|format|initialize|create pool/i })).toBeNull()
  })
})
