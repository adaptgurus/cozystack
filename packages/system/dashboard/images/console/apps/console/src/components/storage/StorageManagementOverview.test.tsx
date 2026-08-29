import { describe, expect, it, vi } from "vitest"
import { screen } from "@testing-library/react"
import { K8sClient, type K8sList } from "@cozystack/k8s-client"
import { renderWithK8sProvider } from "../../test-utils/render.tsx"
import { StorageManagementOverview } from "./StorageManagementOverview.tsx"

function list(items: unknown[]): K8sList<never> {
  return {
    apiVersion: "v1",
    kind: "List",
    metadata: {},
    items: items as never[],
  }
}

function makeClient({ inventory = true }: { inventory?: boolean } = {}): K8sClient {
  const client = new K8sClient()

  vi.spyOn(client, "getApiGroups").mockResolvedValue({
    apiVersion: "v1",
    kind: "APIGroupList",
    groups: [
      {
        name: "snapshot.storage.k8s.io",
        versions: [{ groupVersion: "snapshot.storage.k8s.io/v1", version: "v1" }],
        preferredVersion: { groupVersion: "snapshot.storage.k8s.io/v1", version: "v1" },
      },
    ],
  })

  vi.spyOn(client, "list").mockImplementation(async (_group, _version, plural) => {
    switch (plural) {
      case "storageclasses":
        return list([
          {
            apiVersion: "storage.k8s.io/v1",
            kind: "StorageClass",
            metadata: { name: "replicated" },
            provisioner: "linstor.csi.linbit.com",
            volumeBindingMode: "WaitForFirstConsumer",
            allowVolumeExpansion: true,
          },
          {
            apiVersion: "storage.k8s.io/v1",
            kind: "StorageClass",
            metadata: { name: "shared" },
            provisioner: "nfs.csi.k8s.io",
            volumeBindingMode: "Immediate",
            allowVolumeExpansion: true,
          },
        ]) as never
      case "persistentvolumes":
        return list([
          {
            apiVersion: "v1",
            kind: "PersistentVolume",
            metadata: { name: "pv-demo" },
            spec: {
              storageClassName: "replicated",
              capacity: { storage: "20Gi" },
              claimRef: { namespace: "tenant-demo", name: "data" },
              csi: { driver: "linstor.csi.linbit.com" },
            },
            status: { phase: "Bound" },
          },
        ]) as never
      case "persistentvolumeclaims":
        return list([
          {
            apiVersion: "v1",
            kind: "PersistentVolumeClaim",
            metadata: { name: "data", namespace: "tenant-demo" },
            spec: {
              storageClassName: "replicated",
              volumeName: "pv-demo",
              resources: { requests: { storage: "20Gi" } },
            },
            status: { phase: "Bound", capacity: { storage: "20Gi" } },
          },
        ]) as never
      case "volumesnapshots":
        return list([
          {
            apiVersion: "snapshot.storage.k8s.io/v1",
            kind: "VolumeSnapshot",
            metadata: { name: "snap-demo", namespace: "tenant-demo" },
            spec: {
              volumeSnapshotClassName: "linstor-snapshots",
              source: { persistentVolumeClaimName: "data" },
            },
            status: { readyToUse: true, restoreSize: "20Gi" },
          },
        ]) as never
      default:
        return list([]) as never
    }
  })

  vi.spyOn(client, "get").mockImplementation(async (_group, _version, plural, name, namespace) => {
    if (plural === "configmaps" && name === "layersentry-storage-inventory" && namespace === "cozy-system") {
      if (!inventory) throw new Error("not found")
      return {
        apiVersion: "v1",
        kind: "ConfigMap",
        metadata: { name, namespace },
        data: {
          "inventory.json": JSON.stringify({
            schemaVersion: "storage.layersentry.io/v1alpha1",
            generatedAt: "2026-08-29T16:30:00Z",
            sourceCommit: "test-commit",
            identityGate: "BLOCKED",
            initializationAllowed: false,
            blockedDevices: 1,
            devices: [
              {
                Node: "10.10.10.11",
                Device: "/dev/sdb",
                Size: "322 GB",
                Identity: "wwid:naa.600224806dc058308dd8a3bf014a297c",
                Status: "BLOCKED",
                Reason: "existing-data-present",
                ExistingDataEvidence: "child:sdb1;sdb:discovered=gpt",
              },
            ],
          }),
        },
      } as never
    }
    throw new Error(`unexpected get ${plural}/${name}`)
  })

  return client
}

describe("StorageManagementOverview", () => {
  it("renders certified disk identity and keeps destructive initialization locked", async () => {
    renderWithK8sProvider(<StorageManagementOverview />, { client: makeClient() })

    expect(await screen.findByText("wwid:naa.600224806dc058308dd8a3bf014a297c")).toBeInTheDocument()
    expect(screen.getByText("existing-data-present")).toBeInTheDocument()
    expect(screen.getByText("Initialization locked")).toBeInTheDocument()
    expect(screen.getByText("LINSTOR")).toBeInTheDocument()
    expect(screen.getByText("NFS")).toBeInTheDocument()
    expect(await screen.findByText("snap-demo")).toBeInTheDocument()

    expect(screen.queryByRole("button", { name: /wipe|format|initialize|create pool/i })).toBeNull()
  })

  it("fails closed when no certified physical inventory has been published", async () => {
    renderWithK8sProvider(<StorageManagementOverview />, { client: makeClient({ inventory: false }) })

    expect(await screen.findByText("Awaiting certified inventory")).toBeInTheDocument()
    expect(screen.getByText("Initialization locked")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /wipe|format|initialize|create pool/i })).toBeNull()
  })
})
