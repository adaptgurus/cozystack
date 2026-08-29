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

type UnknownRecord = Record<string, unknown>

function isRecord(value: unknown): value is UnknownRecord {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0
}

function isOptionalString(value: unknown): boolean {
  return value === undefined || typeof value === "string"
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === "string"
}

function isNullableBoolean(value: unknown): value is boolean | null {
  return value === null || typeof value === "boolean"
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0
}

function isNullableNonNegativeInteger(value: unknown): value is number | null {
  return value === null || isNonNegativeInteger(value)
}

function isNullablePositiveNumber(value: unknown): value is number | null {
  return value === null || (typeof value === "number" && Number.isFinite(value) && value > 0)
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string")
}

function isParseableTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && Number.isFinite(Date.parse(value))
}

function isCapabilityEvidence(value: unknown): value is CapabilityEvidence {
  if (!isRecord(value)) return false
  return isNullableBoolean(value.supported) && isNonEmptyString(value.source) && isOptionalString(value.reason)
}

function isSriovEvidence(value: unknown): value is SriovEvidence {
  if (!isRecord(value) || !isCapabilityEvidence(value)) return false
  if (!isNullableNonNegativeInteger(value.totalVfs) || !isNullableNonNegativeInteger(value.configuredVfs)) return false
  if (value.totalVfs !== null && value.configuredVfs !== null && value.configuredVfs > value.totalVfs) return false
  if (value.supported === true && (value.totalVfs === null || value.totalVfs <= 0)) return false
  return true
}

function isRdmaEvidence(value: unknown): value is RdmaEvidence {
  if (!isRecord(value) || !isCapabilityEvidence(value) || !isStringArray(value.devices)) return false
  if (value.supported === true && value.devices.length === 0) return false
  return true
}

function isNetworkLink(value: unknown): value is NetworkLink {
  if (!isRecord(value)) return false
  if (!isNonEmptyString(value.name) || typeof value.type !== "string" || typeof value.kind !== "string") return false
  if (typeof value.physical !== "boolean" || typeof value.operationalState !== "string" || typeof value.mac !== "string") return false
  if (value.linkUp !== undefined && !isNullableBoolean(value.linkUp)) return false
  if (value.index !== undefined && !isNullableNonNegativeInteger(value.index)) return false
  if (value.linkIndex !== undefined && !isNullableNonNegativeInteger(value.linkIndex)) return false
  if (value.masterIndex !== undefined && !isNullableNonNegativeInteger(value.masterIndex)) return false
  if (value.vlanId !== undefined && !isNullableNonNegativeInteger(value.vlanId)) return false
  if (value.mtu !== undefined && !isNullablePositiveNumber(value.mtu)) return false
  if (value.speedMbps !== undefined && !isNullablePositiveNumber(value.speedMbps)) return false
  if (value.parent !== undefined && !isNullableString(value.parent)) return false
  if (value.master !== undefined && !isNullableString(value.master)) return false
  if (!isSriovEvidence(value.sriov) || !isRdmaEvidence(value.rdma)) return false
  return true
}

function isNetworkAddress(value: unknown): value is NetworkAddress {
  if (!isRecord(value)) return false
  if (typeof value.address !== "string" || typeof value.linkName !== "string") return false
  if (value.linkIndex !== undefined && !isNullableNonNegativeInteger(value.linkIndex)) return false
  return isOptionalString(value.local) && isOptionalString(value.family) && isOptionalString(value.scope)
}

function isNetworkRoute(value: unknown): value is NetworkRoute {
  if (!isRecord(value)) return false
  if (typeof value.destination !== "string" || typeof value.gateway !== "string" || typeof value.outLinkName !== "string") return false
  if (value.outLinkIndex !== undefined && !isNullableNonNegativeInteger(value.outLinkIndex)) return false
  if (value.table !== undefined && !isNullableNonNegativeInteger(value.table)) return false
  if (value.metric !== undefined && !isNullableNonNegativeInteger(value.metric)) return false
  return isOptionalString(value.source) && isOptionalString(value.family) && isOptionalString(value.protocol)
}

function isManagementPath(value: unknown): value is ManagementPath {
  if (!isRecord(value)) return false
  if (!isNullableString(value.interface) || !isNullableString(value.gateway)) return false
  if (value.physicalInterfaces !== undefined && !isStringArray(value.physicalInterfaces)) return false
  if (value.addresses !== undefined && !isStringArray(value.addresses)) return false
  if (value.family !== undefined && !isNullableString(value.family)) return false
  if (!["high", "medium", "unknown"].includes(String(value.confidence))) return false
  return typeof value.reason === "string"
}

function isNodeNetworkInventory(value: unknown): value is NodeNetworkInventory {
  if (!isRecord(value)) return false
  if (!isNonEmptyString(value.name) || !isParseableTimestamp(value.collectedAt) || !isNonEmptyString(value.state)) return false
  if (value.endpoint !== undefined && typeof value.endpoint !== "string") return false
  if (value.error !== undefined && !isNullableString(value.error)) return false
  if (!isManagementPath(value.management)) return false
  if (!Array.isArray(value.links) || !value.links.every(isNetworkLink)) return false
  if (!Array.isArray(value.addresses) || !value.addresses.every(isNetworkAddress)) return false
  if (!Array.isArray(value.routes) || !value.routes.every(isNetworkRoute)) return false
  if (!isStringArray(value.resolvers)) return false

  const links = value.links as NetworkLink[]
  const linkNames = new Set(links.map((link) => link.name))
  if (linkNames.size !== links.length) return false

  if (value.state === "ready") {
    for (const interfaceName of (value.management as ManagementPath).physicalInterfaces ?? []) {
      const link = links.find((candidate) => candidate.name === interfaceName)
      if (!link || !link.physical) return false
    }
  }
  return true
}

function isNetworkInventory(value: unknown): value is NetworkInventory {
  if (!isRecord(value)) return false
  if (value.schemaVersion !== "network.layersentry.io/v1alpha1") return false
  if (!isParseableTimestamp(value.generatedAt) || !isNonEmptyString(value.source)) return false
  if (!isNonNegativeInteger(value.nodeCount) || !isNonNegativeInteger(value.readyNodeCount)) return false
  if (typeof value.partial !== "boolean" || !Array.isArray(value.nodes) || !value.nodes.every(isNodeNetworkInventory)) return false
  if (value.sourceCommit !== undefined && typeof value.sourceCommit !== "string") return false
  if (value.sourceRun !== undefined && typeof value.sourceRun !== "string") return false

  const nodes = value.nodes as NodeNetworkInventory[]
  if (nodes.length !== value.nodeCount) return false
  if (new Set(nodes.map((node) => node.name)).size !== nodes.length) return false

  const actualReadyNodeCount = nodes.filter((node) => node.state === "ready").length
  if (actualReadyNodeCount !== value.readyNodeCount) return false
  if (value.partial !== (actualReadyNodeCount !== value.nodeCount)) return false
  return true
}

export function parseNetworkInventory(raw: string | undefined): NetworkInventory | null {
  if (!raw) return null
  try {
    const parsed: unknown = JSON.parse(raw)
    return isNetworkInventory(parsed) ? parsed : null
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
