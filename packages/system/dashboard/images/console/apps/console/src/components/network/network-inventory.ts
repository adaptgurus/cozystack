export type CapabilityEvidence = {
  supported: boolean | null
  source: string
  reason?: string
}

export type SriovEvidence = CapabilityEvidence & {
  totalVfs: number | null
  configuredVfs: number | null
}

export type RdmaEvidence = CapabilityEvidence & {
  devices: string[]
}

export type NetworkLink = {
  name: string
  index?: number | null
  type: string
  kind: string
  physical: boolean
  linkIndex?: number | null
  parent?: string | null
  masterIndex?: number | null
  master?: string | null
  linkUp?: boolean | null
  operationalState: string
  mac: string
  permanentMac?: string
  mtu?: number | null
  speedMbps?: number | null
  driver?: string
  driverVersion?: string
  firmwareVersion?: string
  pciId?: string
  vendor?: string
  port?: string
  duplex?: string
  vlanId?: number | null
  sriov: SriovEvidence
  rdma: RdmaEvidence
}

export type NetworkAddress = {
  address: string
  local?: string
  linkName: string
  linkIndex?: number | null
  family?: string
  scope?: string
}

export type NetworkRoute = {
  destination: string
  source?: string
  gateway: string
  outLinkName: string
  outLinkIndex?: number | null
  family?: string
  table?: number | null
  metric?: number | null
  protocol?: string
}

export type ManagementPath = {
  interface: string | null
  physicalInterfaces?: string[]
  addresses?: string[]
  gateway: string | null
  family?: string | null
  confidence: "high" | "medium" | "unknown"
  reason: string
}

export type NodeNetworkInventory = {
  name: string
  endpoint?: string
  collectedAt: string
  state: "ready" | "error" | string
  error?: string | null
  management: ManagementPath
  links: NetworkLink[]
  addresses: NetworkAddress[]
  routes: NetworkRoute[]
  resolvers: string[]
}

export type NetworkInventory = {
  schemaVersion: "network.layersentry.io/v1alpha1"
  generatedAt: string
  sourceCommit?: string
  sourceRun?: string
  source: string
  nodeCount: number
  readyNodeCount: number
  partial: boolean
  nodes: NodeNetworkInventory[]
}

export function parseNetworkInventory(raw: string | undefined): NetworkInventory | null {
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as NetworkInventory
    if (
      parsed?.schemaVersion !== "network.layersentry.io/v1alpha1" ||
      !Array.isArray(parsed.nodes) ||
      typeof parsed.generatedAt !== "string"
    ) {
      return null
    }
    return parsed
  } catch {
    return null
  }
}

export function inventoryAgeMs(inventory: NetworkInventory | null, now = Date.now()): number | null {
  if (!inventory) return null
  const generated = Date.parse(inventory.generatedAt)
  if (!Number.isFinite(generated)) return null
  return Math.max(0, now - generated)
}

export function isInventoryStale(inventory: NetworkInventory | null, now = Date.now(), staleAfterMs = 10 * 60_000): boolean {
  const age = inventoryAgeMs(inventory, now)
  return age === null || age > staleAfterMs
}

export function readyNodes(inventory: NetworkInventory | null): NodeNetworkInventory[] {
  return (inventory?.nodes ?? []).filter((node) => node.state === "ready")
}

export function physicalLinks(node: NodeNetworkInventory | undefined): NetworkLink[] {
  return (node?.links ?? []).filter((link) => link.physical)
}

export function compatiblePhysicalLinkNames(
  inventory: NetworkInventory | null,
  selectedNodes: string[],
): string[] {
  if (!inventory || selectedNodes.length === 0) return []
  const nodes = selectedNodes
    .map((name) => inventory.nodes.find((node) => node.name === name))
    .filter((node): node is NodeNetworkInventory => Boolean(node && node.state === "ready"))
  if (nodes.length !== selectedNodes.length || nodes.length === 0) return []

  const first = new Set(physicalLinks(nodes[0]).map((link) => link.name))
  for (const node of nodes.slice(1)) {
    const names = new Set(physicalLinks(node).map((link) => link.name))
    for (const name of [...first]) {
      if (!names.has(name)) first.delete(name)
    }
  }
  return [...first].sort((a, b) => a.localeCompare(b))
}

export function managementProtectedInterfaces(node: NodeNetworkInventory | undefined): string[] {
  if (!node) return []
  const protectedInterfaces = new Set<string>()
  if (node.management.interface) protectedInterfaces.add(node.management.interface)
  for (const name of node.management.physicalInterfaces ?? []) {
    if (name) protectedInterfaces.add(name)
  }
  return [...protectedInterfaces].sort((a, b) => a.localeCompare(b))
}

export function capabilityLabel(link: NetworkLink): string {
  const capabilities: string[] = []
  if (link.sriov.supported === true) capabilities.push(`SR-IOV ${link.sriov.totalVfs ?? "?"} VFs`)
  if (link.rdma.supported === true) capabilities.push(`RDMA ${link.rdma.devices.join(", ")}`)
  if (capabilities.length > 0) return capabilities.join(" · ")
  if (link.sriov.supported === null || link.rdma.supported === null) return "Capability unknown"
  return "Standard"
}

export function speedLabel(speedMbps: number | null | undefined): string {
  if (!speedMbps) return "Unknown"
  if (speedMbps >= 1000 && speedMbps % 1000 === 0) return `${speedMbps / 1000} GbE`
  return `${speedMbps} Mb/s`
}
