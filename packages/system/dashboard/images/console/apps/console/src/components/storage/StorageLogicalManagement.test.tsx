import { fireEvent, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { K8sClient, type K8sList } from "@cozystack/k8s-client"
import { renderWithK8sProvider } from "../../test-utils/render.tsx"
import { StorageLogicalManagement } from "./StorageLogicalManagement.tsx"

function list(items: unknown[]): K8sList<never> {
  return { apiVersion: "v1", kind: "List", metadata: { resourceVersion: "1" }, items: items as never[] }
}

function makeClient(allowed = true): K8sClient {
  const client = new K8sClient()
  vi.spyOn(client, "list").mockImplementation(async (_group, _version, plural) => {
    if (plural === "storageclasses") {
      return list([
        {
          apiVersion: "storage.k8s.io/v1",
          kind: "StorageClass",
          metadata: {
            name: "local",
            annotations: { "storageclass.kubernetes.io/is-default-class": "true" },
          },
          provisioner: "linstor.csi.linbit.com",
          parameters: {
            "linstor.csi.linbit.com/storagePool": "data",
            "linstor.csi.linbit.com/allowRemoteVolumeAccess": "false",
          },
          allowVolumeExpansion: true,
          reclaimPolicy: "Delete",
          volumeBindingMode: "WaitForFirstConsumer",
        },
      ]) as never
    }
    if (plural === "persistentvolumeclaims") {
      return list([
        {
          apiVersion: "v1",
          kind: "PersistentVolumeClaim",
          metadata: { name: "claim-a", namespace: "default" },
          spec: {
            accessModes: ["ReadWriteOnce"],
            storageClassName: "local",
            resources: { requests: { storage: "10Gi" } },
          },
          status: { phase: "Bound", capacity: { storage: "10Gi" } },
        },
      ]) as never
    }
    if (plural === "volumesnapshotclasses") {
      return list([
        {
          apiVersion: "snapshot.storage.k8s.io/v1",
          kind: "VolumeSnapshotClass",
          metadata: {
            name: "linstor-snapshots",
            annotations: { "snapshot.storage.kubernetes.io/is-default-class": "true" },
          },
          driver: "linstor.csi.linbit.com",
          deletionPolicy: "Delete",
        },
      ]) as never
    }
    if (plural === "volumesnapshots") return list([]) as never
    if (plural === "csidrivers") {
      return list([
        {
          apiVersion: "storage.k8s.io/v1",
          kind: "CSIDriver",
          metadata: { name: "linstor.csi.linbit.com" },
          spec: { attachRequired: true, volumeLifecycleModes: ["Persistent"] },
        },
      ]) as never
    }
    return list([]) as never
  })

  vi.spyOn(client, "create").mockImplementation(async (_group, _version, plural, body) => {
    if (plural === "selfsubjectaccessreviews") {
      return {
        apiVersion: "authorization.k8s.io/v1",
        kind: "SelfSubjectAccessReview",
        metadata: { name: "" },
        status: { allowed },
      } as never
    }
    return body as never
  })
  vi.spyOn(client, "patch").mockImplementation(async () => ({}) as never)
  vi.spyOn(client, "delete").mockResolvedValue({})
  vi.spyOn(client, "watch").mockReturnValue(() => undefined)
  return client
}

describe("StorageLogicalManagement", () => {
  it("renders logical lifecycle state without exposing physical destructive actions", async () => {
    renderWithK8sProvider(<StorageLogicalManagement />, { client: makeClient() })

    expect(await screen.findByText("Logical storage lifecycle")).toBeInTheDocument()
    expect(await screen.findByText("claim-a")).toBeInTheDocument()
    expect(screen.getAllByText("linstor.csi.linbit.com").length).toBeGreaterThan(0)
    expect(screen.getByText(/Shrink is prohibited/i)).toBeInTheDocument()
    expect(screen.getByText(/never grant dashboard write access to PersistentVolumes/i)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /wipe|format|initialize|import|mount|create pool/i })).toBeNull()
  })

  it("clones the observed StorageClass parameters instead of inventing backend settings", async () => {
    const client = makeClient(true)
    renderWithK8sProvider(<StorageLogicalManagement />, { client })

    await screen.findByText("Clone StorageClass")
    fireEvent.change(screen.getByDisplayValue("Select source StorageClass"), { target: { value: "local" } })
    fireEvent.change(screen.getByPlaceholderText("new-storage-class"), { target: { value: "local-copy" } })

    const createButton = screen.getByRole("button", { name: "Create from observed class" })
    await waitFor(() => expect(createButton).not.toBeDisabled())
    fireEvent.click(createButton)

    await waitFor(() => {
      const call = vi.mocked(client.create).mock.calls.find((args) => args[2] === "storageclasses")
      expect(call).toBeTruthy()
      const body = call?.[3] as {
        metadata: { name: string }
        provisioner: string
        parameters: Record<string, string>
      }
      expect(body.metadata.name).toBe("local-copy")
      expect(body.provisioner).toBe("linstor.csi.linbit.com")
      expect(body.parameters["linstor.csi.linbit.com/storagePool"]).toBe("data")
      expect(body.parameters["linstor.csi.linbit.com/allowRemoteVolumeAccess"]).toBe("false")
    })
  })

  it("fails closed when logical mutation permissions are denied", async () => {
    renderWithK8sProvider(<StorageLogicalManagement />, { client: makeClient(false) })

    expect(
      await screen.findByText("Create permission is not granted; this control is fail-closed."),
    ).toBeInTheDocument()
    expect(screen.getByText("PVC create permission is not granted; provisioning is fail-closed.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create from observed class" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Create PVC" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Create VolumeSnapshot" })).toBeDisabled()
  })
})
