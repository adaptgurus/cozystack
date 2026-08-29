import { useMemo, useState } from "react"
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  CircleDot,
  Network,
  RotateCcw,
  Server,
  ShieldCheck,
  Waypoints,
} from "lucide-react"
import { Section } from "@cozystack/ui"

type Purpose = "VM / Tenant" | "Management" | "Storage" | "Migration" | "Backup" | "Kubernetes" | "Custom"
type BondMode = "802.3ad" | "active-backup"
type IpMode = "none" | "dhcp" | "static"

type FormState = {
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

const STEPS = ["Purpose", "Nodes", "Uplinks", "Bond & Bridge", "VLAN & IP", "VM Network", "Validate", "Review"] as const
const NODE_OPTIONS = ["sen1", "sen2", "sen3"]
const NIC_OPTIONS = ["eno1", "eno2", "eno3", "eno4"]

const INITIAL: FormState = {
  name: "production-web",
  purpose: "VM / Tenant",
  nodes: ["sen1", "sen2", "sen3"],
  nic1: "eno2",
  nic2: "eno3",
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

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-slate-800">{label}</span>
      {children}
      {hint && <span className="mt-1 block text-xs text-slate-500">{hint}</span>}
    </label>
  )
}

const inputClass = "w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100"

function StepButton({ index, current, label, onClick }: { index: number; current: number; label: string; onClick: () => void }) {
  const complete = index < current
  const active = index === current
  return (
    <button type="button" onClick={onClick} className="flex min-w-24 flex-1 items-center gap-2 text-left">
      <span className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold ${active ? "bg-blue-600 text-white" : complete ? "bg-emerald-100 text-emerald-700" : "bg-slate-100 text-slate-500"}`}>
        {complete ? <CheckCircle2 className="h-4 w-4" /> : index + 1}
      </span>
      <span className={`hidden text-xs xl:block ${active ? "font-semibold text-blue-700" : "text-slate-600"}`}>{label}</span>
    </button>
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

function Topology({ form }: { form: FormState }) {
  const parent = form.bondEnabled ? form.bondName || "bond" : form.nic1 || "uplink"
  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50 p-4">
      <div className="mb-4 flex items-center gap-2 text-sm font-semibold text-slate-800"><Waypoints className="h-4 w-4" /> Desired topology</div>
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <div className="rounded-md border bg-white px-3 py-2 font-medium">{form.nic1 || "NIC"}</div>
        {form.bondEnabled && <div className="rounded-md border bg-white px-3 py-2 font-medium">{form.nic2 || "NIC"}</div>}
        <ArrowRight className="h-4 w-4 text-slate-400" />
        {form.bondEnabled && <><div className="rounded-md border border-blue-200 bg-blue-50 px-3 py-2 font-medium text-blue-800">{parent}<div className="font-normal">{form.bondMode}</div></div><ArrowRight className="h-4 w-4 text-slate-400" /></>}
        <div className="rounded-md border border-indigo-200 bg-indigo-50 px-3 py-2 font-medium text-indigo-800">{form.bridgeName || "bridge"}</div>
        <ArrowRight className="h-4 w-4 text-slate-400" />
        <div className="rounded-md border border-violet-200 bg-violet-50 px-3 py-2 font-medium text-violet-800">VLAN {form.vlanId || "—"}</div>
        {form.purpose === "VM / Tenant" && <><ArrowRight className="h-4 w-4 text-slate-400" /><div className="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 font-medium text-emerald-800">{form.vmNetworkName || "VM Network"}</div></>}
      </div>
    </div>
  )
}

function StatusPill({ ok, children }: { ok: boolean; children: React.ReactNode }) {
  return <span className={`inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium ${ok ? "bg-emerald-50 text-emerald-700" : "bg-amber-50 text-amber-700"}`}>{ok ? <CheckCircle2 className="h-3.5 w-3.5" /> : <AlertTriangle className="h-3.5 w-3.5" />}{children}</span>
}

export function NetworkFabricPage() {
  const [form, setForm] = useState<FormState>(INITIAL)
  const [step, setStep] = useState(0)
  const [applyStarted, setApplyStarted] = useState(false)
  const errors = useMemo(() => validateNetworkFabric(form), [form])
  const canContinue = errors.length === 0 || step < 6

  const patch = <K extends keyof FormState>(key: K, value: FormState[K]) => setForm((old) => ({ ...old, [key]: value }))
  const toggleNode = (node: string) => patch("nodes", form.nodes.includes(node) ? form.nodes.filter((n) => n !== node) : [...form.nodes, node])

  return (
    <div className="space-y-5 p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2"><Network className="h-6 w-6 text-blue-600" /><h1 className="text-2xl font-semibold text-slate-900">Network Fabric</h1></div>
          <p className="mt-1 max-w-3xl text-sm text-slate-600">Build host and VM networking without YAML. LayerSentry validates dependencies, protects management connectivity, previews the desired topology, and stages changes node by node.</p>
        </div>
        <div className="flex gap-2">
          <StatusPill ok>Declarative</StatusPill><StatusPill ok>Management protected</StatusPill>
        </div>
      </div>

      <Section>
        <div className="overflow-x-auto px-2 py-4"><div className="flex min-w-[900px] items-center gap-2">{STEPS.map((label, index) => <StepButton key={label} index={index} current={step} label={label} onClick={() => setStep(index)} />)}</div></div>
      </Section>

      <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_390px]">
        <Section>
          <div className="p-5">
            {step === 0 && <div className="space-y-5"><h2 className="text-lg font-semibold">1. Network purpose</h2><div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{(["VM / Tenant", "Management", "Storage", "Migration", "Backup", "Kubernetes", "Custom"] as Purpose[]).map((purpose) => <button type="button" key={purpose} onClick={() => patch("purpose", purpose)} className={`rounded-lg border p-4 text-left ${form.purpose === purpose ? "border-blue-500 bg-blue-50 ring-2 ring-blue-100" : "border-slate-200 hover:border-slate-300"}`}><CircleDot className="mb-2 h-4 w-4" /><div className="font-medium">{purpose}</div><div className="mt-1 text-xs text-slate-500">{purpose === "VM / Tenant" ? "Guest VLAN-backed network" : purpose === "Management" ? "Protected node management path" : `${purpose} traffic fabric`}</div></button>)}</div><Field label="Fabric name"><input className={inputClass} value={form.name} onChange={(e) => patch("name", e.target.value)} /></Field></div>}

            {step === 1 && <div className="space-y-5"><h2 className="text-lg font-semibold">2. Select nodes</h2><p className="text-sm text-slate-600">Choose where this desired network topology should exist. Capability checks are performed before apply.</p><div className="grid gap-3 sm:grid-cols-3">{NODE_OPTIONS.map((node) => <button key={node} type="button" onClick={() => toggleNode(node)} className={`rounded-lg border p-4 text-left ${form.nodes.includes(node) ? "border-blue-500 bg-blue-50" : "border-slate-200"}`}><Server className="mb-2 h-5 w-5" /><div className="font-medium">{node}</div><div className="mt-1 text-xs text-slate-500">4 NICs · link inventory ready</div></button>)}</div>{form.purpose === "Management" && <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800"><AlertTriangle className="mr-2 inline h-4 w-4" />Management fabrics are always applied one node at a time with connectivity verification.</div>}</div>}

            {step === 2 && <div className="space-y-5"><h2 className="text-lg font-semibold">3. Physical uplinks</h2><div className="grid gap-4 md:grid-cols-2"><Field label="Primary NIC"><select className={inputClass} value={form.nic1} onChange={(e) => patch("nic1", e.target.value)}>{NIC_OPTIONS.map((n) => <option key={n}>{n}</option>)}</select></Field><Field label="Secondary NIC"><select className={inputClass} value={form.nic2} onChange={(e) => patch("nic2", e.target.value)}>{NIC_OPTIONS.map((n) => <option key={n}>{n}</option>)}</select></Field></div><div className="overflow-hidden rounded-lg border"><table className="w-full text-sm"><thead className="bg-slate-50 text-left text-xs text-slate-500"><tr><th className="p-3">NIC</th><th className="p-3">Link</th><th className="p-3">Speed</th><th className="p-3">MTU</th><th className="p-3">Capability</th></tr></thead><tbody>{NIC_OPTIONS.map((nic, i) => <tr key={nic} className="border-t"><td className="p-3 font-medium">{nic}</td><td className="p-3 text-emerald-700">Up</td><td className="p-3">{i < 2 ? "10 GbE" : "25 GbE"}</td><td className="p-3">1500</td><td className="p-3">{i >= 2 ? "SR-IOV · RDMA" : "Standard"}</td></tr>)}</tbody></table></div></div>}

            {step === 3 && <div className="space-y-5"><h2 className="text-lg font-semibold">4. Bond and bridge</h2><label className="flex items-center gap-3 rounded-lg border p-4"><input type="checkbox" checked={form.bondEnabled} onChange={(e) => patch("bondEnabled", e.target.checked)} /><div><div className="font-medium">Create bond</div><div className="text-xs text-slate-500">Use multiple physical uplinks for resilience and bandwidth.</div></div></label>{form.bondEnabled && <div className="grid gap-4 md:grid-cols-2"><Field label="Bond name"><input className={inputClass} value={form.bondName} onChange={(e) => patch("bondName", e.target.value)} /></Field><Field label="Bond mode"><select className={inputClass} value={form.bondMode} onChange={(e) => patch("bondMode", e.target.value as BondMode)}><option value="802.3ad">LACP / 802.3ad</option><option value="active-backup">Active / Backup</option></select></Field></div>}<div className="grid gap-4 md:grid-cols-2"><Field label="Linux bridge"><input className={inputClass} value={form.bridgeName} onChange={(e) => patch("bridgeName", e.target.value)} /></Field><Field label="MTU"><input className={inputClass} inputMode="numeric" value={form.mtu} onChange={(e) => patch("mtu", e.target.value)} /></Field></div><Topology form={form} /></div>}

            {step === 4 && <div className="space-y-5"><h2 className="text-lg font-semibold">5. VLAN and host IP</h2><div className="grid gap-4 md:grid-cols-2"><Field label="VLAN ID" hint="Valid range: 1–4094"><input className={inputClass} inputMode="numeric" value={form.vlanId} onChange={(e) => patch("vlanId", e.target.value)} /></Field><Field label="IP configuration"><select className={inputClass} value={form.ipMode} onChange={(e) => patch("ipMode", e.target.value as IpMode)}><option value="none">No host IP</option><option value="dhcp">DHCP</option><option value="static">Static</option></select></Field></div>{form.ipMode === "static" && <div className="grid gap-4 md:grid-cols-3"><Field label="Address / CIDR"><input className={inputClass} placeholder="10.20.120.11/24" value={form.address} onChange={(e) => patch("address", e.target.value)} /></Field><Field label="Gateway"><input className={inputClass} placeholder="10.20.120.1" value={form.gateway} onChange={(e) => patch("gateway", e.target.value)} /></Field><Field label="DNS"><input className={inputClass} placeholder="10.20.1.10, 10.20.1.11" value={form.dns} onChange={(e) => patch("dns", e.target.value)} /></Field></div>}<Topology form={form} /></div>}

            {step === 5 && <div className="space-y-5"><h2 className="text-lg font-semibold">6. VM network</h2>{form.purpose === "VM / Tenant" ? <><Field label="Friendly VM network name" hint="This is the name users select from the VM creation dropdown."><input className={inputClass} value={form.vmNetworkName} onChange={(e) => patch("vmNetworkName", e.target.value)} /></Field><div className="rounded-lg border bg-slate-50 p-4"><div className="text-sm font-medium">VM attachment experience</div><div className="mt-3 rounded-md border bg-white px-3 py-2 text-sm">Network: <strong>{form.vmNetworkName || "VM Network"}</strong> · VLAN {form.vlanId} · {form.bridgeName}</div></div></> : <div className="rounded-lg border bg-slate-50 p-4 text-sm text-slate-600">This fabric purpose does not require a guest VM network. Host networking will still be created and reconciled.</div>}<Topology form={form} /></div>}

            {step === 6 && <div className="space-y-5"><h2 className="text-lg font-semibold">7. Preflight validation</h2><div className="grid gap-2">{[
              ["VLAN range", Number(form.vlanId) >= 1 && Number(form.vlanId) <= 4094],
              ["NIC ownership", form.nic1 !== form.nic2 || !form.bondEnabled],
              ["Bond member compatibility", !form.bondEnabled || Boolean(form.nic1 && form.nic2)],
              ["MTU consistency", Number(form.mtu) >= 1280 && Number(form.mtu) <= 9216],
              ["Bridge dependency", Boolean(form.bridgeName)],
              ["Management path protection", form.purpose !== "Management" || form.nodes.length === 1],
              ["VM network mapping", form.purpose !== "VM / Tenant" || Boolean(form.vmNetworkName)],
              ["Declarative schema", errors.length === 0],
            ].map(([label, ok]) => <div key={String(label)} className="flex items-center justify-between rounded-md border px-3 py-2 text-sm"><span>{String(label)}</span><StatusPill ok={Boolean(ok)}>{ok ? "Pass" : "Action required"}</StatusPill></div>)}</div>{errors.length > 0 && <div className="rounded-md border border-amber-200 bg-amber-50 p-4"><div className="font-medium text-amber-900">Resolve before apply</div><ul className="mt-2 list-disc pl-5 text-sm text-amber-800">{errors.map((error) => <li key={error}>{error}</li>)}</ul></div>}</div>}

            {step === 7 && <div className="space-y-5"><h2 className="text-lg font-semibold">8. Review and safe apply</h2><Topology form={form} /><div className="grid gap-3 md:grid-cols-2"><div className="rounded-lg border p-4"><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Create</div><ul className="mt-2 space-y-1 text-sm"><li>+ {form.bondEnabled ? form.bondName : "direct uplink"}</li><li>+ {form.bridgeName}</li><li>+ VLAN {form.vlanId}</li>{form.purpose === "VM / Tenant" && <li>+ VM network {form.vmNetworkName}</li>}</ul></div><div className="rounded-lg border p-4"><div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Scope</div><div className="mt-2 text-sm">Nodes: {form.nodes.join(", ") || "none"}</div><div className="mt-1 text-sm">Purpose: {form.purpose}</div><div className="mt-1 text-sm">Risk: {form.purpose === "Management" ? "High — protected staged apply" : "Medium"}</div></div></div><div className="rounded-lg border border-blue-200 bg-blue-50 p-4"><div className="flex items-center gap-2 font-medium text-blue-900"><ShieldCheck className="h-4 w-4" /> Safe apply sequence</div><div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-blue-800"><span>Validate</span><ArrowRight className="h-3 w-3" /><span>Generate desired state</span><ArrowRight className="h-3 w-3" /><span>Apply node 1</span><ArrowRight className="h-3 w-3" /><span>Verify connectivity</span><ArrowRight className="h-3 w-3" /><span>Next node</span><ArrowRight className="h-3 w-3" /><span>Final reconcile</span></div></div>{applyStarted && <div className="rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800"><Activity className="mr-2 inline h-4 w-4" />Workflow prepared. Backend reconciliation must confirm each node before advancing; failed management health checks trigger rollback to the previous known-good state.</div>}</div>}
          </div>
        </Section>

        <div className="space-y-5">
          <Section><div className="p-4"><div className="mb-3 flex items-center gap-2 font-semibold"><ShieldCheck className="h-4 w-4 text-emerald-600" /> Safety policy</div><ul className="space-y-2 text-xs text-slate-600"><li>• No arbitrary host shell execution</li><li>• Duplicate VLAN and NIC membership checks</li><li>• MTU and dependency validation</li><li>• Management route protection</li><li>• Capability-gated advanced networking</li><li>• Node-by-node staged reconciliation</li><li>• Previous-known-good rollback point</li></ul></div></Section>
          <Section><div className="p-4"><div className="mb-3 font-semibold">Current draft</div><dl className="grid grid-cols-[120px_1fr] gap-y-2 text-xs"><dt className="text-slate-500">Purpose</dt><dd>{form.purpose}</dd><dt className="text-slate-500">Nodes</dt><dd>{form.nodes.join(", ") || "—"}</dd><dt className="text-slate-500">Uplink</dt><dd>{form.bondEnabled ? `${form.nic1} + ${form.nic2}` : form.nic1}</dd><dt className="text-slate-500">Bridge</dt><dd>{form.bridgeName || "—"}</dd><dt className="text-slate-500">VLAN</dt><dd>{form.vlanId || "—"}</dd><dt className="text-slate-500">MTU</dt><dd>{form.mtu || "—"}</dd><dt className="text-slate-500">VM Network</dt><dd>{form.purpose === "VM / Tenant" ? form.vmNetworkName : "N/A"}</dd></dl></div></Section>
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border bg-white p-3 shadow-sm">
        <button type="button" onClick={() => { setForm(INITIAL); setStep(0); setApplyStarted(false) }} className="inline-flex items-center gap-2 rounded-md border px-3 py-2 text-sm hover:bg-slate-50"><RotateCcw className="h-4 w-4" /> Reset</button>
        <div className="flex gap-2"><button type="button" disabled={step === 0} onClick={() => setStep((s) => Math.max(0, s - 1))} className="rounded-md border px-4 py-2 text-sm disabled:opacity-40">Back</button>{step < STEPS.length - 1 ? <button type="button" disabled={!canContinue} onClick={() => setStep((s) => Math.min(STEPS.length - 1, s + 1))} className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white disabled:bg-slate-300">Continue</button> : <button type="button" disabled={errors.length > 0} onClick={() => setApplyStarted(true)} className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white disabled:bg-slate-300">Prepare Safe Apply</button>}</div>
      </div>
    </div>
  )
}
