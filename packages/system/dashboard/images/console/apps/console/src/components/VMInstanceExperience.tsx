import { useMemo, useRef, useState } from "react"
import type { LucideIcon } from "lucide-react"
import {
  Check,
  ChevronLeft,
  ChevronRight,
  Cpu,
  HardDrive,
  KeyRound,
  ListChecks,
  Network,
  Server,
} from "lucide-react"
import { Button, Spinner, cn } from "@cozystack/ui"
import { SchemaForm, type SchemaFormHandle } from "./SchemaForm.tsx"

type VmSpec = Record<string, unknown>

type StepId = "basics" | "compute" | "storage" | "network" | "access" | "review"

interface VmStep {
  id: StepId
  label: string
  description: string
  fields: string[]
  icon: LucideIcon
}

const VM_STEPS: VmStep[] = [
  {
    id: "basics",
    label: "Basics",
    description: "Identity, operating system profile and lifecycle",
    fields: ["instanceProfile", "instanceType", "runStrategy"],
    icon: Server,
  },
  {
    id: "compute",
    label: "Compute",
    description: "CPU, memory and acceleration overrides",
    fields: ["resources", "cpuModel", "gpus"],
    icon: Cpu,
  },
  {
    id: "storage",
    label: "Storage",
    description: "Attach one or more virtual disks",
    fields: ["disks"],
    icon: HardDrive,
  },
  {
    id: "network",
    label: "Network",
    description: "Tenant networks and optional external access",
    fields: [
      "networks",
      "external",
      "externalMethod",
      "externalPorts",
      "externalAllowICMP",
    ],
    icon: Network,
  },
  {
    id: "access",
    label: "Access",
    description: "SSH keys and cloud-init customization",
    fields: ["sshKeys", "cloudInit", "cloudInitSeed"],
    icon: KeyRound,
  },
  {
    id: "review",
    label: "Review",
    description: "Confirm the effective VM configuration",
    fields: [],
    icon: ListChecks,
  },
]

const FIELD_LABELS: Record<string, string> = {
  instanceProfile: "Operating system profile",
  instanceType: "Instance type",
  runStrategy: "Run strategy",
  resources: "Compute resources",
  cpuModel: "CPU model",
  gpus: "GPU devices",
  disks: "Disks",
  networks: "Networks",
  subnets: "Legacy networks",
  external: "External access",
  externalMethod: "External access method",
  externalPorts: "External ports",
  externalAllowICMP: "External ICMP",
  sshKeys: "SSH keys",
  cloudInit: "Cloud-init",
  cloudInitSeed: "Cloud-init seed",
}

const FIELD_ORDER = Object.keys(FIELD_LABELS)
const DNS_SUBDOMAIN = /^[a-z0-9](?:[-.a-z0-9]*[a-z0-9])?$/

function asRecord(value: unknown): VmSpec {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as VmSpec)
    : {}
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function itemName(value: unknown): string {
  const item = asRecord(value)
  return typeof item.name === "string" ? item.name : ""
}

function sameValue(a: unknown, b: unknown): boolean {
  return JSON.stringify(a ?? null) === JSON.stringify(b ?? null)
}

export function getVmNameError(name: string): string | null {
  if (!name) return "Enter a VM name."
  if (name !== name.trim()) return "VM name cannot start or end with spaces."
  if (name.length > 253) return "VM name must be 253 characters or fewer."
  if (!DNS_SUBDOMAIN.test(name)) {
    return "Use lowercase letters, numbers, '-' or '.', and start and end with a letter or number."
  }
  return null
}

export function getChangedVmFields(initialSpec: unknown, currentSpec: unknown): string[] {
  const initial = asRecord(initialSpec)
  const current = asRecord(currentSpec)
  const keys = new Set([...Object.keys(initial), ...Object.keys(current)])
  const ordered = [
    ...FIELD_ORDER.filter((key) => keys.has(key)),
    ...[...keys].filter((key) => !FIELD_ORDER.includes(key)).sort(),
  ]
  return ordered.filter((key) => !sameValue(initial[key], current[key]))
}

interface VMInstanceExperienceProps {
  name: string
  onNameChange: (name: string) => void
  tenantNamespace?: string | null
  openAPISchema: string
  keysOrder?: string[][]
  spec: unknown
  onSpecChange: (spec: unknown) => void
  initialSpec?: unknown
  isEdit: boolean
  busy: boolean
  onSubmit: () => void | Promise<void>
}

export function VMInstanceExperience({
  name,
  onNameChange,
  tenantNamespace,
  openAPISchema,
  keysOrder,
  spec,
  onSpecChange,
  initialSpec,
  isEdit,
  busy,
  onSubmit,
}: VMInstanceExperienceProps) {
  const [activeStep, setActiveStep] = useState(0)
  const [furthestStep, setFurthestStep] = useState(isEdit ? VM_STEPS.length - 1 : 0)
  const [nameTouched, setNameTouched] = useState(false)
  const schemaFormRef = useRef<SchemaFormHandle>(null)

  const currentStep = VM_STEPS[activeStep]
  const isReview = currentStep.id === "review"
  const vmSpec = asRecord(spec)
  const persistedSpec = asRecord(initialSpec)
  const nameError = getVmNameError(name)
  const changedFields = useMemo(
    () => (isEdit ? getChangedVmFields(initialSpec, spec) : []),
    [initialSpec, isEdit, spec],
  )

  const visibleFields = useMemo(() => {
    const fields = [...currentStep.fields]
    if (
      currentStep.id === "network" &&
      (asArray(vmSpec.subnets).length > 0 || asArray(persistedSpec.subnets).length > 0)
    ) {
      fields.splice(1, 0, "subnets")
    }
    return fields
  }, [currentStep, persistedSpec.subnets, vmSpec.subnets])

  const disks = asArray(vmSpec.disks).map(itemName).filter(Boolean)
  const networks = asArray(vmSpec.networks).map(itemName).filter(Boolean)
  const legacyNetworks = asArray(vmSpec.subnets).map(itemName).filter(Boolean)
  const gpus = asArray(vmSpec.gpus).map(itemName).filter(Boolean)
  const sshKeyCount = asArray(vmSpec.sshKeys).filter(
    (key) => typeof key === "string" && key.trim().length > 0,
  ).length
  const resources = asRecord(vmSpec.resources)
  const external = vmSpec.external === true
  const externalPorts = asArray(vmSpec.externalPorts).filter(
    (port) => typeof port === "number" || typeof port === "string",
  )

  const validateCurrentStep = () => {
    if (currentStep.id === "basics") {
      setNameTouched(true)
      if (nameError) return false
    }
    if (isReview) return true
    return schemaFormRef.current?.validate() ?? true
  }

  const goForward = () => {
    if (!validateCurrentStep()) return
    const next = Math.min(activeStep + 1, VM_STEPS.length - 1)
    setFurthestStep((current) => Math.max(current, next))
    setActiveStep(next)
  }

  const selectStep = (index: number) => {
    if (!isEdit && index > furthestStep + 1) return
    if (index > activeStep && !validateCurrentStep()) return
    setFurthestStep((current) => Math.max(current, index))
    setActiveStep(index)
  }

  const submit = async () => {
    setNameTouched(true)
    if (nameError) {
      setActiveStep(0)
      return
    }
    if (schemaFormRef.current && !schemaFormRef.current.validate()) {
      setActiveStep(Math.min(activeStep, VM_STEPS.length - 2))
      return
    }
    await onSubmit()
  }

  return (
    <div className="mx-auto w-full max-w-[1500px] p-4 lg:p-6">
      <div className="grid gap-4 lg:grid-cols-[230px_minmax(0,1fr)] xl:grid-cols-[230px_minmax(0,1fr)_280px]">
        <aside className="rounded-xl border border-slate-200 bg-white p-2 shadow-sm lg:self-start lg:sticky lg:top-4">
          <div className="mb-2 px-2 pt-2">
            <p className="text-xs font-semibold uppercase tracking-wider text-slate-400">
              {isEdit ? "Edit workflow" : "Create workflow"}
            </p>
            <p className="mt-1 text-sm font-semibold text-slate-900">Virtual machine</p>
          </div>
          <nav className="flex gap-1 overflow-x-auto pb-1 lg:block lg:space-y-1 lg:overflow-visible">
            {VM_STEPS.map((step, index) => {
              const Icon = step.icon
              const active = index === activeStep
              const complete = index < activeStep || index <= furthestStep - 1
              const disabled = !isEdit && index > furthestStep + 1
              return (
                <button
                  key={step.id}
                  type="button"
                  disabled={disabled || busy}
                  onClick={() => selectStep(index)}
                  className={cn(
                    "group flex min-w-[150px] items-center gap-2 rounded-lg px-2.5 py-2 text-left transition-colors lg:w-full lg:min-w-0",
                    active
                      ? "bg-blue-50 text-blue-800"
                      : "text-slate-600 hover:bg-slate-50 hover:text-slate-900",
                    disabled && "cursor-not-allowed opacity-40",
                  )}
                >
                  <span
                    className={cn(
                      "flex size-7 shrink-0 items-center justify-center rounded-full border text-xs",
                      active
                        ? "border-blue-200 bg-white text-blue-700"
                        : complete
                          ? "border-emerald-200 bg-emerald-50 text-emerald-700"
                          : "border-slate-200 bg-white text-slate-500",
                    )}
                  >
                    {complete && !active ? <Check className="size-3.5" /> : <Icon className="size-3.5" />}
                  </span>
                  <span className="min-w-0">
                    <span className="block text-xs font-semibold">{step.label}</span>
                    <span className="hidden truncate text-[11px] text-slate-400 lg:block">
                      {step.description}
                    </span>
                  </span>
                </button>
              )
            })}
          </nav>
        </aside>

        <main className="min-w-0">
          <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm">
            <header className="border-b border-slate-100 px-5 py-4">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="text-xs font-medium text-blue-600">
                    Step {activeStep + 1} of {VM_STEPS.length}
                  </p>
                  <h2 className="mt-0.5 text-base font-semibold text-slate-900">
                    {currentStep.label}
                  </h2>
                  <p className="mt-0.5 text-xs text-slate-500">{currentStep.description}</p>
                </div>
                {isEdit && (
                  <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-[11px] font-medium text-slate-600">
                    Existing VM
                  </span>
                )}
              </div>
            </header>

            <div className="p-5">
              {currentStep.id === "basics" && (
                <div className="mb-5 rounded-lg border border-slate-200 bg-slate-50/60 p-4">
                  <div className="flex items-start justify-between gap-4">
                    <div className="min-w-0 flex-1">
                      <label className="mb-1.5 block text-xs font-semibold text-slate-700">
                        VM name <span className="text-red-500">*</span>
                      </label>
                      <input
                        type="text"
                        value={name}
                        onChange={(event) => onNameChange(event.target.value)}
                        onBlur={() => setNameTouched(true)}
                        disabled={isEdit || busy}
                        placeholder="web-01"
                        aria-invalid={!!(nameTouched && nameError)}
                        className={cn(
                          "w-full rounded-lg border bg-white px-3 py-2.5 text-sm text-slate-900 shadow-sm outline-none transition-shadow focus:ring-2 disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-500",
                          nameTouched && nameError
                            ? "border-red-300 focus:border-red-400 focus:ring-red-100"
                            : "border-slate-300 focus:border-blue-500 focus:ring-blue-500/15",
                        )}
                      />
                      {nameTouched && nameError ? (
                        <p className="mt-1.5 text-xs text-red-600">{nameError}</p>
                      ) : (
                        <p className="mt-1.5 text-xs text-slate-500">
                          Kubernetes-safe name used for the VM resource and related objects.
                        </p>
                      )}
                    </div>
                    {tenantNamespace && (
                      <div className="hidden shrink-0 text-right sm:block">
                        <p className="text-[11px] uppercase tracking-wide text-slate-400">Tenant namespace</p>
                        <code className="mt-1 block max-w-52 truncate text-xs text-slate-700">
                          {tenantNamespace}
                        </code>
                      </div>
                    )}
                  </div>
                  {isEdit && (
                    <p className="mt-3 rounded-md border border-blue-100 bg-blue-50 px-3 py-2 text-xs text-blue-700">
                      The VM name is immutable. Existing values are preserved unless you explicitly change an editable field.
                    </p>
                  )}
                </div>
              )}

              {!isReview && (
                <div className="rounded-lg border border-slate-100 bg-white">
                  <SchemaForm
                    ref={schemaFormRef}
                    openAPISchema={openAPISchema}
                    keysOrder={keysOrder}
                    formData={spec}
                    onChange={onSpecChange}
                    immutableMode={isEdit ? "enforce" : "off"}
                    visibleFields={visibleFields}
                    applyDefaults={!isEdit}
                  />
                </div>
              )}

              {isReview && (
                <div className="space-y-4">
                  <ReviewGrid
                    name={name}
                    spec={vmSpec}
                    disks={disks}
                    networks={[...networks, ...legacyNetworks]}
                    gpus={gpus}
                    sshKeyCount={sshKeyCount}
                    external={external}
                    externalPorts={externalPorts}
                  />

                  {isEdit && (
                    <div className="rounded-lg border border-slate-200 bg-slate-50 p-4">
                      <div className="flex items-center justify-between gap-3">
                        <div>
                          <h3 className="text-sm font-semibold text-slate-900">Pending changes</h3>
                          <p className="mt-0.5 text-xs text-slate-500">
                            Only configuration areas that differ from the VM you opened are shown.
                          </p>
                        </div>
                        <span className="rounded-full bg-white px-2.5 py-1 text-xs font-semibold text-slate-600 ring-1 ring-slate-200">
                          {changedFields.length}
                        </span>
                      </div>
                      {changedFields.length === 0 ? (
                        <p className="mt-3 text-xs text-slate-500">No configuration changes detected.</p>
                      ) : (
                        <div className="mt-3 flex flex-wrap gap-2">
                          {changedFields.map((field) => (
                            <span
                              key={field}
                              className="rounded-full border border-blue-200 bg-blue-50 px-2.5 py-1 text-xs font-medium text-blue-700"
                            >
                              {FIELD_LABELS[field] ?? field}
                            </span>
                          ))}
                        </div>
                      )}
                    </div>
                  )}

                  <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-xs text-amber-800">
                    Review the selected compute, storage and network settings before applying. Advanced users can switch to YAML from the page header without losing the current form state.
                  </div>
                </div>
              )}

              {/* Keep the schema form mounted on Review so defaults, dynamic
                  options and validation state remain stable across the wizard. */}
              {isReview && (
                <div className="hidden" aria-hidden="true">
                  <SchemaForm
                    ref={schemaFormRef}
                    openAPISchema={openAPISchema}
                    keysOrder={keysOrder}
                    formData={spec}
                    onChange={onSpecChange}
                    immutableMode={isEdit ? "enforce" : "off"}
                    visibleFields={[]}
                    applyDefaults={!isEdit}
                  />
                </div>
              )}
            </div>

            <footer className="flex items-center justify-between border-t border-slate-100 bg-slate-50/70 px-5 py-3.5">
              <Button
                variant="outline"
                size="sm"
                onClick={() => setActiveStep((step) => Math.max(0, step - 1))}
                disabled={activeStep === 0 || busy}
              >
                <ChevronLeft className="size-4" /> Back
              </Button>

              <div className="flex items-center gap-2">
                {!isReview ? (
                  <Button variant="primary" size="sm" onClick={goForward} disabled={busy}>
                    Continue <ChevronRight className="size-4" />
                  </Button>
                ) : (
                  <Button variant="primary" size="sm" onClick={submit} disabled={busy}>
                    {busy && <Spinner className="text-white" />}
                    {isEdit ? "Save changes" : "Create virtual machine"}
                  </Button>
                )}
              </div>
            </footer>
          </section>
        </main>

        <aside className="hidden xl:block">
          <div className="sticky top-4 space-y-3">
            <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
              <p className="text-xs font-semibold uppercase tracking-wider text-slate-400">Live summary</p>
              <h3 className="mt-1 truncate text-sm font-semibold text-slate-900">{name || "New virtual machine"}</h3>
              <dl className="mt-3 space-y-2 text-xs">
                <SummaryRow label="Profile" value={textValue(vmSpec.instanceProfile, "Default")} />
                <SummaryRow label="Type" value={textValue(vmSpec.instanceType, "Default")} />
                <SummaryRow label="CPU" value={textValue(resources.cpu, "From type")} />
                <SummaryRow label="Memory" value={textValue(resources.memory, "From type")} />
                <SummaryRow label="Disks" value={String(disks.length)} />
                <SummaryRow label="Networks" value={String(networks.length + legacyNetworks.length)} />
                <SummaryRow label="GPUs" value={String(gpus.length)} />
                <SummaryRow label="External" value={external ? "Enabled" : "Disabled"} />
              </dl>
            </div>
            <div className="rounded-xl border border-blue-100 bg-blue-50 p-4 text-xs text-blue-800">
              <p className="font-semibold">Safe edit behavior</p>
              <p className="mt-1 leading-5 text-blue-700">
                Locked fields remain read-only and the edit form does not inject create-time defaults into an existing VM.
              </p>
            </div>
          </div>
        </aside>
      </div>
    </div>
  )
}

function textValue(value: unknown, fallback: string): string {
  if (typeof value === "string" || typeof value === "number") return String(value)
  return fallback
}

function SummaryRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <dt className="text-slate-500">{label}</dt>
      <dd className="max-w-40 truncate text-right font-medium text-slate-800">{value}</dd>
    </div>
  )
}

interface ReviewGridProps {
  name: string
  spec: VmSpec
  disks: string[]
  networks: string[]
  gpus: string[]
  sshKeyCount: number
  external: boolean
  externalPorts: unknown[]
}

function ReviewGrid({
  name,
  spec,
  disks,
  networks,
  gpus,
  sshKeyCount,
  external,
  externalPorts,
}: ReviewGridProps) {
  const resources = asRecord(spec.resources)
  const cards = [
    {
      title: "Identity & lifecycle",
      rows: [
        ["Name", name || "—"],
        ["OS profile", textValue(spec.instanceProfile, "Default")],
        ["Instance type", textValue(spec.instanceType, "Default")],
        ["Run strategy", textValue(spec.runStrategy, "Always")],
      ],
    },
    {
      title: "Compute",
      rows: [
        ["CPU", textValue(resources.cpu, "From instance type")],
        ["Memory", textValue(resources.memory, "From instance type")],
        ["Sockets", textValue(resources.sockets, "Default")],
        ["GPUs", gpus.length ? gpus.join(", ") : "None"],
      ],
    },
    {
      title: "Storage & network",
      rows: [
        ["Disks", disks.length ? disks.join(", ") : "None"],
        ["Networks", networks.length ? networks.join(", ") : "Pod network only"],
        ["External access", external ? "Enabled" : "Disabled"],
        ["External ports", external && externalPorts.length ? externalPorts.join(", ") : "—"],
      ],
    },
    {
      title: "Access & initialization",
      rows: [
        ["SSH keys", String(sshKeyCount)],
        ["Cloud-init", typeof spec.cloudInit === "string" && spec.cloudInit.trim() ? "Configured" : "Not configured"],
        ["Cloud-init seed", typeof spec.cloudInitSeed === "string" && spec.cloudInitSeed ? "Configured" : "Automatic"],
        ["CPU model", textValue(spec.cpuModel, "Default")],
      ],
    },
  ]

  return (
    <div className="grid gap-3 md:grid-cols-2">
      {cards.map((card) => (
        <div key={card.title} className="rounded-lg border border-slate-200 bg-white p-4">
          <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-500">{card.title}</h3>
          <dl className="mt-3 space-y-2">
            {card.rows.map(([label, value]) => (
              <div key={label} className="flex items-start justify-between gap-4 text-xs">
                <dt className="shrink-0 text-slate-500">{label}</dt>
                <dd className="min-w-0 break-words text-right font-medium text-slate-800">{value}</dd>
              </div>
            ))}
          </dl>
        </div>
      ))}
    </div>
  )
}
