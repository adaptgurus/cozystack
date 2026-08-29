import { describe, expect, it } from "vitest"
import {
  capabilityLabel,
  compatiblePhysicalLinkNames,
  isInventoryStale,
  parseNetworkInventory,
  speedLabel,
  type NetworkInventory,
} from "./network-inventory.ts"

const INVENTORY: NetworkInventory = {
  schemaVersion: "network.layersentry.io/v1alpha1",
  generatedAt: "2026-08-29T18:00:00.000Z",
  source: "talos-resource-api+sysfs",
  nodeCount: 2,
  readyNodeCount: 2,
  partial: false,
  nodes: [
    {
      name: "sen1",
      collectedAt: "2026-08-29T18:00:00.000Z",
      state: "ready",
      management: { interface: "eno1", gateway: "10.10.10.1", confidence: "high", reason: "lowest-priority-default-route" },
      addresses: [],
      routes: [],
      resolvers: [],
      links: [
        {
          name: "eno1",
          type: "ether",
          kind: "physical",
          physical: true,
          linkUp: true,
          operationalState: "up",
          mac: "00:11:22:33:44:55",
          mtu: 1500,
          speedMbps: 10000,
          sriov: { supported: false, totalVfs: 0, configuredVfs: 0, source: "sysfs:sriov_totalvfs" },
          rdma: { supported: false, devices: [], source: "sysfs:not-present" },
        },
        {
          name: "eno2",
          type: "ether",
          kind: "physical",
          physical: true,
          linkUp: true,
          operationalState: "up",
          mac: "00:11:22:33:44:66",
          mtu: 9000,
          speedMbps: 25000,
          sriov: { supported: true, totalVfs: 64, configuredVfs: 8, source: "sysfs:sriov_totalvfs" },
          rdma: { supported: true, devices: ["mlx5_0"], source: "sysfs:infiniband" },
        },
      ],
    },
    {
      name: "sen2",
      collectedAt: "2026-08-29T18:00:00.000Z",
      state: "ready",
      management: { interface: "eno1", gateway: "10.10.10.1", confidence: "high", reason: "lowest-priority-default-route" },
      addresses: [],
      routes: [],
      resolvers: [],
      links: [
        {
          name: "eno1",
          type: "ether",
          kind: "physical",
          physical: true,
          linkUp: true,
          operationalState: "up",
          mac: "00:11:22:33:44:77",
          mtu: 1500,
          speedMbps: 10000,
          sriov: { supported: null, totalVfs: null, configuredVfs: null, source: "not-probed" },
          rdma: { supported: null, devices: [], source: "not-probed" },
        },
        {
          name: "eno2",
          type: "ether",
          kind: "physical",
          physical: true,
          linkUp: true,
          operationalState: "up",
          mac: "00:11:22:33:44:88",
          mtu: 9000,
          speedMbps: 25000,
          sriov: { supported: true, totalVfs: 64, configuredVfs: 0, source: "sysfs:sriov_totalvfs" },
          rdma: { supported: true, devices: ["mlx5_1"], source: "sysfs:infiniband" },
        },
      ],
    },
  ],
}

describe("network inventory", () => {
  it("rejects malformed and wrong-schema inventory", () => {
    expect(parseNetworkInventory("not-json")).toBeNull()
    expect(parseNetworkInventory(JSON.stringify({ ...INVENTORY, schemaVersion: "wrong" }))).toBeNull()
  })

  it("finds only physical NICs common to every selected node", () => {
    expect(compatiblePhysicalLinkNames(INVENTORY, ["sen1", "sen2"])).toEqual(["eno1", "eno2"])
    expect(compatiblePhysicalLinkNames(INVENTORY, ["sen1", "missing"])).toEqual([])
  })

  it("does not invent advanced capabilities", () => {
    expect(capabilityLabel(INVENTORY.nodes[1].links[0])).toBe("Capability unknown")
    expect(capabilityLabel(INVENTORY.nodes[0].links[1])).toContain("SR-IOV 64 VFs")
    expect(capabilityLabel(INVENTORY.nodes[0].links[1])).toContain("RDMA mlx5_0")
  })

  it("normalizes speed and freshness", () => {
    expect(speedLabel(25000)).toBe("25 GbE")
    expect(speedLabel(null)).toBe("Unknown")
    expect(isInventoryStale(INVENTORY, Date.parse("2026-08-29T18:05:00.000Z"))).toBe(false)
    expect(isInventoryStale(INVENTORY, Date.parse("2026-08-29T18:11:00.000Z"))).toBe(true)
  })
})
