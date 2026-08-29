import { describe, expect, it } from "vitest"
import { fireEvent, screen } from "@testing-library/react"
import { NetworkFabricPage, validateNetworkFabric } from "./NetworkFabricPage.tsx"
import type { NetworkInventory, NetworkLink, NodeNetworkInventory } from "../components/network/network-inventory.ts"
import { createMockK8sClient } from "../test-utils/mock-k8s-client.ts"
import { renderWithK8sProvider } from "../test-utils/render.tsx"

const link = (name: string, mac: string): NetworkLink => ({
  name,
  type: "ether",
  kind: "physical",
  physical: true,
  linkUp: true,
  operationalState: "up",
  mac,
  mtu: 1500,
  speedMbps: 10000,
  sriov: {
    supported: false,
    totalVfs: 0,
    configuredVfs: 0,
    source: "test",
    reason: "not-required-for-gui-test",
  },
  rdma: {
    supported: false,
    devices: [],
    source: "test",
    reason: "not-required-for-gui-test",
  },
})

const node = (name: string, address: string, macSuffix: string): NodeNetworkInventory => ({
  name,
  collectedAt: new Date().toISOString(),
  state: "ready",
  management: {
    interface: "eno1",
    physicalInterfaces: ["eno1"],
    addresses: [address],
    gateway: "10.10.10.1",
    family: "ipv4",
    confidence: "high",
    reason: "test-fixture",
  },
  links: [
    link("eno1", `00:11:22:33:44:${macSuffix}`),
    link("eno2", `00:11:22:33:55:${macSuffix}`),
  ],
  addresses: [],
  routes: [],
  resolvers: ["10.10.10.2"],
})

function renderNetworkFabric() {
  const inventory: NetworkInventory = {
    schemaVersion: "network.layersentry.io/v1alpha1",
    generatedAt: new Date().toISOString(),
    source: "test:talos-resource-api",
    nodeCount: 3,
    readyNodeCount: 3,
    partial: false,
    nodes: [
      node("sen1", "10.10.10.11/24", "11"),
      node("sen2", "10.10.10.12/24", "12"),
      node("sen3", "10.10.10.13/24", "13"),
    ],
  }
  const client = createMockK8sClient({
    gets: [
      {
        apiGroup: "",
        apiVersion: "v1",
        plural: "configmaps",
        namespace: "cozy-system",
        name: "layersentry-network-inventory",
        result: {
          apiVersion: "v1",
          kind: "ConfigMap",
          metadata: { name: "layersentry-network-inventory", namespace: "cozy-system" },
          data: { "inventory.json": JSON.stringify(inventory) },
        },
      },
    ],
  })
  return renderWithK8sProvider(<NetworkFabricPage />, { client })
}

describe("NetworkFabricPage", () => {
  it("renders the GUI workflow and desired topology without YAML", async () => {
    renderNetworkFabric()

    expect(screen.getByRole("heading", { name: "Network Fabric" })).toBeInTheDocument()
    expect(screen.getByText(/build host and vm networking without yaml/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Purpose/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Review/i })).toBeInTheDocument()
    expect((await screen.findAllByText("Live 3/3")).length).toBeGreaterThanOrEqual(2)
    expect(screen.queryByText(/machine:\s*network/i)).not.toBeInTheDocument()
  })

  it("walks from purpose into live node selection", async () => {
    renderNetworkFabric()

    expect((await screen.findAllByText("Live 3/3")).length).toBeGreaterThanOrEqual(2)
    fireEvent.click(screen.getByRole("button", { name: "Continue" }))
    expect(screen.getByRole("heading", { name: "2. Select nodes" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /sen1/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /sen2/i })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /sen3/i })).toBeInTheDocument()
  })

  it("rejects invalid VLAN, MTU and duplicate bond members", () => {
    const errors = validateNetworkFabric({
      name: "bad-fabric",
      purpose: "VM / Tenant",
      nodes: ["sen1"],
      nic1: "eno2",
      nic2: "eno2",
      bondEnabled: true,
      bondName: "bond0",
      bondMode: "802.3ad",
      bridgeName: "br-vm",
      vlanId: "4095",
      mtu: "1000",
      ipMode: "none",
      address: "",
      gateway: "",
      dns: "",
      vmNetworkName: "Production-Web",
    })

    expect(errors).toContain("Bond members must use different NICs")
    expect(errors).toContain("VLAN ID must be between 1 and 4094")
    expect(errors).toContain("MTU must be between 1280 and 9216")
  })

  it("enforces one-node staging for management network changes", () => {
    const errors = validateNetworkFabric({
      name: "management",
      purpose: "Management",
      nodes: ["sen1", "sen2"],
      nic1: "eno1",
      nic2: "eno2",
      bondEnabled: true,
      bondName: "bond-mgmt",
      bondMode: "active-backup",
      bridgeName: "br-mgmt",
      vlanId: "10",
      mtu: "1500",
      ipMode: "static",
      address: "10.10.10.11/24",
      gateway: "10.10.10.1",
      dns: "10.10.10.2",
      vmNetworkName: "",
    })

    expect(errors).toContain("Management changes must be staged one node at a time")
  })
})
