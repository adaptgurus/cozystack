import { describe, expect, it } from "vitest"
import { fireEvent, render, screen } from "@testing-library/react"
import { NetworkFabricPage, validateNetworkFabric } from "./NetworkFabricPage.tsx"

describe("NetworkFabricPage", () => {
  it("renders the GUI workflow and desired topology without YAML", () => {
    render(<NetworkFabricPage />)

    expect(screen.getByRole("heading", { name: "Network Fabric" })).toBeInTheDocument()
    expect(screen.getByText(/build host and vm networking without yaml/i)).toBeInTheDocument()
    expect(screen.getByText("Purpose")).toBeInTheDocument()
    expect(screen.getByText("Review")).toBeInTheDocument()
    expect(screen.queryByText(/machine:\s*network/i)).not.toBeInTheDocument()
  })

  it("walks from purpose into node selection", () => {
    render(<NetworkFabricPage />)

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
