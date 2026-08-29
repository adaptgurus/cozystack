import { useEffect, useMemo, useState } from "react"
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  CircleDot,
  Network,
  RefreshCw,
  RotateCcw,
  Server,
  ShieldCheck,
  Waypoints,
} from "lucide-react"
import { K8sApiError, useK8sGet, type K8sResource } from "@cozystack/k8s-client"
import { Section } from "@cozystack/ui"
import {
  capabilityLabel,
  compatiblePhysicalLinkNames,
  isInventoryStale,
  parseNetworkInventory,
  physicalLinks,
  readyNodes,
  speedLabel,
  type NetworkInventory,
  type NodeNetworkInventory,
} from "../components/network/network-inventory.ts"

type Purpose = "VM / Tenant" | "Management" | "Storage" | "Migration" | "Backup" | "Kubernetes" | "Custom"
type BondMode = "802.3ad" | "active-backup"
type IpMode = "none" | "dhcp" | "static"

export type FormState = {
  name: string
  purpose: Purpose
  nodes: string[]
  nic1: string
  nic2: string
  bondEnabled: boolean
  bondName: string
  bondMode: BondMode
  bridgeName: string
  vlanId: string
  mtu: string
  ipMode: IpMode
  address: string
  gateway: string
  dns: string
  vmNetworkName: string
}

type NetworkInventoryConfigMap = K8sResource & {
  data?: Record<string, string>
}

const STEPS = ["Purpose", "Nodes", "Uplinks", "Bond & Bridge", "VLAN & IP", "VM Network", "Validate", "Review"] as const
const INVENTORY_REF = {
  apiGroup: "",
  apiVersion: "v1",
  plural: "configmaps",
  namespace: "cozy-system",
  name: "layersentry-network-inventory",
}

const INITIAL: FormState = {
  name: "production-web",
  purpose: "VM / Tenant",
  nodes: [],
  nic1: "",
  nic2: "",
  bondEnabled: true,
  bondName: "bond0",
  bondMode: "802.3ad",
  bridgeName: "br-vm",
  vlanId: "120",
  mtu: "1500",
  ipMode: "none",
  address: "",
  gateway: "",
  dns: "",
  vmNetworkName: "Production-Web",
}

const inputClass = "w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100 disabled:bg-slate-100 disabled:text-slate-500"

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-slate-800">{label}</span>
      {children}
      {hint ? <span className="mt-1 block text-xs text-slate-500">{hint}</span> : null}
    </label>
  )
}

function StepButton({ index, current, label, onClick }: { index: number; current: number; label: string; onClick: () => void }) {
  const complete = index < current
  const active = index === current
  return (
    <button type="button" onClick={onClick} className="flex min-w-24 flex-1 items-center gap-2 text-left" aria-label={`${label} step`}>
      <span className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${active ? "bg-blue-600 text-white" : complete ? "bg-emerald-100 text-emerald-700" : "bg-slate-100 text-slate-500"}`}>
        {complete ? <CheckCircle2 className="h-4 w-4" /> : index + 1}
      </span>
      <span className={`hidden text-xs xl:block ${active ? "font-semibold text-blue-700" : "text-slate-600"}`}>{label}</span>
    </button>
  )
}

function StatusPill({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return <span className={`inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium ${ok ? "bg-emerald-50 text-emerald-700" : "bg-amber-50 text-amber-800"}`}>{ok ? <CheckCircle2 className="h-3.5 w-3.5" /> : <AlertTriangle className="h-3.5 w-3.5" />}{children}</span>
}

function Topology({ form }: { form: FormState }) {
  const parent = form.bondEnabled ? form.bondName || "bond" : form.nic1 || "uplink"
  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50 p-4">
      <div className="mb-4 flex items-center gap-2 text-sm font-semibold text-slate-800"><Waypoints className="h-4 w-4" /> Desired topology</div>
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <div className="rounded-md border bg-white px-3 py-2 font-medium">{form.nic1 || "NIC"}</div>
        {form.bondEnabled ? <div className="rounded-md border bg-white px-3 py-2 font-medium">{form.nic2 || "NIC"}</div> : null}
        <ArrowRight className="h-4 w-4 text-slate-400" />
        {form.bondEnabled ? <><div className="rounded-md border border-blue-200 bg-blue-50 px-3 py-2 font-medium text-blue-800">{parent}<div className="font-normal">{form.bondMode}</div></div><ArrowRight className="h-4 w-4 text-slate-400" /></> : null}
        <div className="rounded-md border border-indigo-200 bg-indigo-50 px-3 py-2 font-medium text-indigo-800">{form.bridgeName || "bridge"}</div>
        <ArrowRight className="h-4 w-4 text-slate-400" />
        <div className="rounded-md border border-violet-200 bg-violet-50 px-3 py-2 font-medium text-violet-800">VLAN {form.vlanId || "—"}</div>
        {form.purpose === "VM / Tenant" ? <><ArrowRight className="h-4 w-4 text-slate-400" /><div className="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 font-medium text-emerald-800">{form.vmNetworkName || "VM Network"}</div></> : null}
      </div>
    </div>
  )
}

export function validateNetworkFabric(form: FormState): string[] {
  const errors: string[] = []
  const vlan = Number(form.vlanId)
  const mtu = Number(form.mtu)
  if (!form.name.trim()) errors.push("Fabric name is required")
  if (form.nodes.length === 0) errors.push("Select at least one node")
  if (!form.nic1) errors.push("Primary uplink is required")
  if (form.bondEnabled && !form.nic2) errors.push("A second NIC is required for bonding")
  if (form.bondEnabled && form.nic1 === form.nic2) errors.push("Bond members must use different NICs")
  if (form.bondEnabled && !form.bondName.trim()) errors.push("Bond name is required")
  if (!form.bridgeName.trim()) errors.push("Bridge name is required")
  if (!Number.isInteger(vlan) || vlan < 1 || vlan > 4094) errors.push("VLAN ID must be between 1 and 4094")
  if (!Number.isInteger(mtu) || mtu < 1280 || mtu > 9216) errors.push("MTU must be between 1280 and 9216")
  if (form.ipMode === "static" && !form.address.includes("/")) errors.push("Static address must use CIDR notation")
  if (form.purpose === "Management" && form.nodes.length > 1) errors.push("Management changes must be staged one node at a time")
  if (form.purpose === "VM / Tenant" && !form.vmNetworkName.trim()) errors.push("VM network name is required")
  return errors
}

function runtimeValidation(form: FormState, inventory: NetworkInventory | null, stale: boolean): string[] {
  const errors: string[] = []
  if (!inventory) {
    errors.push("Live Talos network inventory is required before apply")
    return errors
  }
  if (stale) errors.push("Talos network inventory is stale; refresh before apply")
  if (inventory.partial) errors.push("Talos network inventory is partial; resolve failed node discovery before apply")

  const compatible = new Set(compatiblePhysicalLinkNames(inventory, form.nodes))
  if (form.nodes.length > 0 && compatible.size === 0) errors.push("Selected nodes have no common physical uplink")
  if (form.nic1 && !compatible.has(form.nic1)) errors.push(`Primary uplink ${form.nic1} is not present on every selected node`)
  if (form.bondEnabled && form.nic2 && !compatible.has(form.nic2)) errors.push(`Secondary uplink ${form.nic2} is not present on every selected node`)

  for (const nodeName of form.nodes) {
    const node = inventory.nodes.find((candidate) => candidate.name === nodeName)
    if (!node || node.state !== "ready") {
      errors.push(`Node ${nodeName} does not have ready Talos inventory`)
      continue
    }
    for (const nic of [form.nic1, ...(form.bondEnabled ? [form.nic2] : [])].filter(Boolean)) {
      const link = node.links.find((candidate) => candidate.name === nic)
      if (!link?.physical) errors.push(`${nodeName}/${nic} is not a verified physical NIC`)
      else if (link.linkUp === false) errors.push(`${nodeName}/${nic} link is down`)
    }
  }
  return [...new Set(errors)]
}

function NodeCard({ node, selected, onClick }: { node: NodeNetworkInventory; selected: boolean; onClick: () => void }) {
  const nics = physicalLinks(node)
  const mgmt = node.management.interface || "unknown"
  return (
    <button type="button" onClick={onClick} className={`rounded-lg border p-4 text-left ${selected ? "border-blue-500 bg-blue-50" : "border-slate-200 hover:border-slate-300"}`}>
      <div className="flex items-start justify-between gap-2"><Server className="h-5 w-5" /><StatusPill ok={node.state === "ready"}>{node.state}</StatusPill></div>
      <div className="mt-2 font-medium">{node.name}</div>
      <div className="mt-1 text-xs text-slate-500">{nics.length} physical NIC{nics.length === 1 ? "" : "s"} · management {mgmt}</div>
    </button>
  )
}

export function NetworkFabricPage() {
  const [form, setForm] = useState<FormState>(INITIAL)
  const [step, setStep] = useState(0)
  const [planPrepared, setPlanPrepared] = useState(false)
  const inventoryQuery = useK8sGet<NetworkInventoryConfigMap>(INVENTORY_REF, { retry: false, refetchOnWindowFocus: false })
  const inventory = useMemo(() => parseNetworkInventory(inventoryQuery.data?.data?.["inventory.json"]), [inventoryQuery.data])
  const stale = isInventoryStale(inventory)
  const nodeOptions = useMemo(() => readyNodes(inventory), [inventory])
  const nicOptions = useMemo(() => compatiblePhysicalLinkNames(inventory, form.nodes), [inventory, form.nodes])
  const formErrors = useMemo(() => validateNetworkFabric(form), [form])
  const liveErrors = useMemo(() => runtimeValidation(form, inventory, stale), [form, inventory, stale])
  const errors = useMemo(() => [...formErrors, ...liveErrors], [formErrors, liveErrors])
  const inventoryForbidden = inventoryQuery.error instanceof K8sApiError && inventoryQuery.error.status === 403

  useEffect(() => {
    if (form.nodes.length === 0 && nodeOptions.length > 0) {
      setForm((old) => ({ ...old, nodes: nodeOptions.map((node) => node.name) }))
    }
  }, [form.nodes.length, nodeOptions])

  useEffect(() => {
    setForm((old) => {
      const nic1 = nicOptions.includes(old.nic1) ? old.nic1 : (nicOptions[0] ?? "")
      const nic2Candidate = nicOptions.find((nic) => nic !== nic1) ?? ""
      const nic2 = nicOptions.includes(old.nic2) && old.nic2 !== nic1 ? old.nic2 : nic2Candidate
      if (nic1 === old.nic1 && nic2 === old.nic2) return old
      return { ...old, nic1, nic2 }
    })
  }, [nicOptions])

  const patch = <K extends keyof FormState>(key: K, value: FormState[K]) => setForm((old) => ({ ...old, [key]: value }))
  const toggleNode = (node: string) => patch("nodes", form.nodes.includes(node) ? form.nodes.filter((name) => name !== node) : [...form.nodes, node])
  const canContinue = step < 6 || errors.length === 0

  const inventoryState = inventoryQuery.isLoading
    ? "Loading Talos inventory"
    : inventoryForbidden
      ? "Inventory access denied"
      : !inventory
        ? "Inventory unavailable"
        : inventory.partial
          ? `Partial ${inventory.readyNodeCount}/${inventory.nodeCount}`
          : stale
            ? "Inventory stale"
            : `Live ${inventory.readyNodeCount}/${inventory.nodeCount}`

  const selectedNodes = form.nodes
    .map((name) => inventory?.nodes.find((node) => node.name === name))
    .filter((node): node is NodeNetworkInventory => Boolean(node))
  const selectedLinks = selectedNodes.flatMap((node) => physicalLinks(node).map((link) => ({ node, link })))

  return (
    <div className="space-y-5 p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2"><Network className="h-6 w-6 text-blue-600" /><h1 className="text-2xl font-semibold text-slate-900">Network Fabric</h1></div>
          <p className="mt-1 max-w-3xl text-sm text-slate-600">Build host and VM networking without YAML. LayerSentry validates dependencies against live Talos state, protects management connectivity, previews the desired topology, and stages changes node by node.</p>
        </div>
        <div className="flex flex-wrap gap-2"><StatusPill ok>Declarative</StatusPill><StatusPill ok={!stale && Boolean(inventory)}>{inventoryState}</StatusPill></div>
      </div>

      <Section>
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 px-4 py-3">
          <div>
            <div className="text-sm font-semibold text-slate-900">Talos host discovery</div>
            <div className="mt-0.5 text-xs text-slate-500">LinkStatus, AddressStatus, RouteStatus and ResolverStatus; hardware capability evidence is collected server-side. Talos credentials never enter the browser payload.</div>
          </div>
          <button type="button" onClick={() => void inventoryQuery.refetch()} className="inline-flex items-center gap-2 rounded-md border border-slate-300 bg-white px-3 py-2 text-xs font-medium text-slate-700 hover:bg-slate-50"><RefreshCw className="h-3.5 w-3.5" />Refresh inventory</button>
        </div>
        {inventoryForbidden ? <div className="px-4 py-3 text-sm text-red-700">Dashboard RBAC does not permit reading the network inventory.</div> : null}
        {!inventoryQuery.isLoading && !inventory && !inventoryForbidden ? <div className="px-4 py-3 text-sm text-amber-800">No valid `layersentry-network-inventory` payload is available. Apply is locked; no simulated NIC data is substituted.</div> : null}
        {inventory?.partial ? <div className="px-4 py-3 text-sm text-amber-800">Discovery is partial. Failed nodes remain unavailable for fabric changes until live inventory succeeds.</div> : null}
      </Section>

      <Section>
        <div className="overflow-x-auto px-2 py-4"><div className="flex min-w-[900px] items-center gap-2">{STEPS.map((label, index) => <StepButton key={label} index={index} current={step} label={label} onClick={() => setStep(index)} />)}</div></div>
      </Section>

      <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_390px]">
        <Section>
          <div className="p-5">
            {step === 0 ? <div className="space-y-5"><h2 className="text-lg font-semibold">1. Network purpose</h2><div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{(["VM / Tenant", "Management", "Storage", "Migration", "Backup", "Kubernetes", "Custom"] as Purpose[]).map((purpose) => <button type="button" key={purpose} onClick={() => patch("purpose", purpose)} className={`rounded-lg border p-4 text-left ${form.purpose === purpose ? "border-blue-500 bg-blue-50 ring-2 ring-blue-100" : "border-slate-200 hover:border-slate-300"}`}><CircleDot className="mb-2 h-4 w-4" /><div className="font-medium">{purpose}</div><div className="mt-1 text-xs text-slate-500">{purpose === "VM / Tenant" ? "Guest VLAN-backed network" : purpose === "Management" ? "Protected Talos management path" : `${purpose} traffic fabric`}</div></button>)}</div><Field label="Fabric name"><input className={inputClass} value={form.name} onChange={(event) => patch("name", event.target.value)} /></Field></div> : null}

            {step === 1 ? <div className="space-y-5"><h2 className="text-lg font-semibold">2. Select nodes</h2><p className="text-sm text-slate-600">Only nodes with successful live Talos discovery are selectable. The GUI does not synthesize absent nodes.</p>{nodeOptions.length > 0 ? <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{nodeOptions.map((node) => <NodeCard key={node.name} node={node} selected={form.nodes.includes(node.name)} onClick={() => toggleNode(node.name)} />)}</div> : <div className="rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">No ready Talos node inventory is available.</div>}{form.purpose === "Management" ? <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800"><AlertTriangle className="mr-2 inline h-4 w-4" />Management fabrics are applied one node at a time using Talos try-mode and post-change connectivity verification.</div> : null}</div> : null}

            {step === 2 ? <div className="space-y-5"><h2 className="text-lg font-semibold">3. Physical uplinks</h2><p className="text-sm text-slate-600">NIC choices are the physical-interface intersection across every selected node. A NIC missing from one node cannot be selected for a shared fabric.</p><div className="grid gap-4 md:grid-cols-2"><Field label="Primary NIC"><select className={inputClass} value={form.nic1} onChange={(event) => patch("nic1", event.target.value)} disabled={nicOptions.length === 0}><option value="">Select discovered NIC</option>{nicOptions.map((name) => <option key={name} value={name}>{name}</option>)}</select></Field><Field label="Secondary NIC"><select className={inputClass} value={form.nic2} onChange={(event) => patch("nic2", event.target.value)} disabled={!form.bondEnabled || nicOptions.length < 2}><option value="">Select discovered NIC</option>{nicOptions.filter((name) => name !== form.nic1).map((name) => <option key={name} value={name}>{name}</option>)}</select></Field></div><div className="overflow-x-auto rounded-lg border"><table className="w-full min-w-[820px] text-sm"><thead className="bg-slate-50 text-left text-xs text-slate-500"><tr><th className="p-3">Node</th><th className="p-3">NIC</th><th className="p-3">MAC</th><th className="p-3">Link</th><th className="p-3">Speed</th><th className="p-3">MTU</th><th className="p-3">Capability evidence</th><th className="p-3">Role</th></tr></thead><tbody>{selectedLinks.map(({ node, link }) => <tr key={`${node.name}-${link.name}`} className="border-t"><td className="p-3 font-medium">{node.name}</td><td className="p-3 font-medium">{link.name}</td><td className="p-3 font-mono text-xs">{link.mac || "Unknown"}</td><td className={`p-3 ${link.linkUp ? "text-emerald-700" : "text-red-700"}`}>{link.linkUp === true ? "Up" : link.linkUp === false ? "Down" : "Unknown"}</td><td className="p-3">{speedLabel(link.speedMbps)}</td><td className="p-3">{link.mtu ?? "Unknown"}</td><td className="p-3 text-xs">{capabilityLabel(link)}</td><td className="p-3 text-xs">{node.management.interface === link.name ? <StatusPill ok={node.management.confidence === "high"}>Management</StatusPill> : "Data"}</td></tr>)}</tbody></table></div></div> : null}

            {step === 3 ? <div className="space-y-5"><h2 className="text-lg font-semibold">4. Bond and bridge</h2><label className="flex items-center gap-3 rounded-lg border p-4"><input type="checkbox" checked={form.bondEnabled} onChange={(event) => patch("bondEnabled", event.target.checked)} /><div><div className="font-medium">Create bond</div><div className="text-xs text-slate-500">Use multiple discovered physical uplinks for resilience and bandwidth.</div></div></label>{form.bondEnabled ? <div className="grid gap-4 md:grid-cols-2"><Field label="Bond name"><input className={inputClass} value={form.bondName} onChange={(event) => patch("bondName", event.target.value)} /></Field><Field label="Bond mode"><select className={inputClass} value={form.bondMode} onChange={(event) => patch("bondMode", event.target.value as BondMode)}><option value="802.3ad">LACP / 802.3ad</option><option value="active-backup">Active / Backup</option></select></Field></div> : null}<div className="grid gap-4 md:grid-cols-2"><Field label="Linux bridge"><input className={inputClass} value={form.bridgeName} onChange={(event) => patch("bridgeName", event.target.value)} /></Field><Field label="MTU"><input className={inputClass} inputMode="numeric" value={form.mtu} onChange={(event) => patch("mtu", event.target.value)} /></Field></div><Topology form={form} /></div> : null}

            {step === 4 ? <div className="space-y-5"><h2 className="text-lg font-semibold">5. VLAN and host IP</h2><div className="grid gap-4 md:grid-cols-2"><Field label="VLAN ID" hint="Valid range: 1–4094"><input className={inputClass} inputMode="numeric" value={form.vlanId} onChange={(event) => patch("vlanId", event.target.value)} /></Field><Field label="IP configuration"><select className={inputClass} value={form.ipMode} onChange={(event) => patch("ipMode", event.target.value as IpMode)}><option value="none">No host IP</option><option value="dhcp">DHCP</option><option value="static">Static</option></select></Field></div>{form.ipMode === "static" ? <div className="grid gap-4 md:grid-cols-3"><Field label="Address / CIDR"><input className={inputClass} placeholder="10.20.120.11/24" value={form.address} onChange={(event) => patch("address", event.target.value)} /></Field><Field label="Gateway"><input className={inputClass} placeholder="10.20.120.1" value={form.gateway} onChange={(event) => patch("gateway", event.target.value)} /></Field><Field label="DNS"><input className={inputClass} placeholder="10.20.1.53" value={form.dns} onChange={(event) => patch("dns", event.target.value)} /></Field></div> : null}<div className="rounded-md border border-blue-200 bg-blue-50 p-3 text-sm text-blue-900">Default-route changes are treated as management-impacting operations and require Talos try-mode plus reconnection verification.</div></div> : null}

            {step === 5 ? <div className="space-y-5"><h2 className="text-lg font-semibold">6. VM network</h2>{form.purpose === "VM / Tenant" ? <Field label="VM network name" hint="Published to the virtualization layer after the host fabric validates."><input className={inputClass} value={form.vmNetworkName} onChange={(event) => patch("vmNetworkName", event.target.value)} /></Field> : <div className="rounded-md border bg-slate-50 p-4 text-sm text-slate-600">This fabric purpose does not require a VM network object.</div>}<Topology form={form} /></div> : null}

            {step === 6 ? <div className="space-y-5"><h2 className="text-lg font-semibold">7. Validate</h2>{errors.length === 0 ? <div className="rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800"><CheckCircle2 className="mr-2 inline h-4 w-4" />Desired topology is consistent with the current live Talos inventory. Apply remains a separate server-side operation.</div> : <div className="rounded-lg border border-red-200 bg-red-50 p-4"><div className="mb-2 text-sm font-semibold text-red-800">Resolve these blockers</div><ul className="list-disc space-y-1 pl-5 text-sm text-red-700">{errors.map((error) => <li key={error}>{error}</li>)}</ul></div>}<div className="grid gap-3 md:grid-cols-2"><div className="rounded-lg border p-4"><div className="font-medium">Management route protection</div><div className="mt-1 text-xs text-slate-500">Default route is discovered from RouteStatus, not guessed from interface naming.</div></div><div className="rounded-lg border p-4"><div className="font-medium">Capability evidence</div><div className="mt-1 text-xs text-slate-500">Speed, SR-IOV and RDMA are shown only when Talos/sysfs evidence exists.</div></div></div></div> : null}

            {step === 7 ? <div className="space-y-5"><h2 className="text-lg font-semibold">8. Review safe apply plan</h2><Topology form={form} /><div className="grid gap-3 md:grid-cols-2"><div className="rounded-lg border p-4 text-sm"><div className="font-medium">Targets</div><div className="mt-1 text-slate-600">{form.nodes.join(", ") || "None"}</div></div><div className="rounded-lg border p-4 text-sm"><div className="font-medium">Observed uplinks</div><div className="mt-1 text-slate-600">{form.nic1 || "—"}{form.bondEnabled ? ` + ${form.nic2 || "—"}` : ""}</div></div></div>{planPrepared ? <div className="rounded-md border border-blue-200 bg-blue-50 p-4 text-sm text-blue-900"><CheckCircle2 className="mr-2 inline h-4 w-4" />Safe-apply plan prepared from current inventory. No host configuration has been changed from this browser action. A server-side reconciler must submit the reviewed Talos machine-config patch using try-mode, reconnect, verify Kubernetes/Talos health, then commit or roll back.</div> : null}<button type="button" disabled={errors.length > 0} onClick={() => setPlanPrepared(true)} className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:bg-slate-300"><ShieldCheck className="h-4 w-4" />Prepare Safe Apply</button></div> : null}
          </div>
          <div className="flex items-center justify-between border-t border-slate-200 px-5 py-4"><button type="button" onClick={() => step === 0 ? setForm(INITIAL) : setStep((value) => Math.max(0, value - 1))} className="inline-flex items-center gap-2 rounded-md border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700"><RotateCcw className="h-4 w-4" />{step === 0 ? "Reset" : "Back"}</button>{step < STEPS.length - 1 ? <button type="button" disabled={!canContinue} onClick={() => setStep((value) => Math.min(STEPS.length - 1, value + 1))} className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white disabled:bg-slate-300">Continue<ArrowRight className="h-4 w-4" /></button> : null}</div>
        </Section>

        <div className="space-y-5">
          <Section><div className="p-4"><div className="flex items-center gap-2 font-semibold text-slate-900"><Activity className="h-4 w-4" />Live fabric evidence</div><div className="mt-3 space-y-2 text-xs text-slate-600"><div className="flex justify-between gap-3"><span>Inventory</span><span className="font-medium text-slate-800">{inventoryState}</span></div><div className="flex justify-between gap-3"><span>Selected nodes</span><span className="font-medium text-slate-800">{form.nodes.length}</span></div><div className="flex justify-between gap-3"><span>Common physical NICs</span><span className="font-medium text-slate-800">{nicOptions.length}</span></div><div className="flex justify-between gap-3"><span>Management protection</span><span className="font-medium text-slate-800">RouteStatus + try-mode</span></div></div></div></Section>
          <Section><div className="p-4"><div className="flex items-center gap-2 font-semibold text-slate-900"><ShieldCheck className="h-4 w-4" />Safety boundary</div><ul className="mt-3 list-disc space-y-2 pl-5 text-xs text-slate-600"><li>Browser receives normalized inventory only; Talos credentials stay on the server/runner.</li><li>No arbitrary host shell execution is exposed.</li><li>Absent or stale evidence blocks apply instead of falling back to mock data.</li><li>Management changes are single-node staged and must use Talos automatic rollback semantics.</li><li>SR-IOV/RDMA support is evidence-backed; unknown is displayed as unknown.</li></ul></div></Section>
        </div>
      </div>
    </div>
  )
}
