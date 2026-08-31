import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react"
import { useK8sList } from "@cozystack/k8s-client"
import type { TenantNamespace } from "@cozystack/types"
import { SELECTED_TENANT_KEY, TENANT_NAMESPACE_PREFIX } from "./constants.ts"

interface TenantContextValue {
  /**
   * Flat list of every TenantNamespace the current user can access, ordered by
   * display name (the namespace prefix stripped). Tenant selection must not
   * change this list: selectedTenant only chooses the namespace targeted by
   * application operations.
   */
  tenants: TenantNamespace[]
  /** Display name (namespace minus the `tenant-` prefix). */
  selectedTenant: string | null
  selectTenant: (name: string) => void
  /** Namespace of the selected tenant — `tenant-<name>`. */
  tenantNamespace: string | null
  isLoading: boolean
  error: unknown
}

const TenantContext = createContext<TenantContextValue | null>(null)

function displayName(ns: TenantNamespace): string {
  const name = ns.metadata.name
  return name.startsWith(TENANT_NAMESPACE_PREFIX)
    ? name.slice(TENANT_NAMESPACE_PREFIX.length)
    : name
}

export function TenantProvider({ children }: { children: ReactNode }) {
  const [selectedTenant, setSelectedTenant] = useState<string | null>(() => {
    if (typeof window === "undefined") return null
    return window.localStorage.getItem(SELECTED_TENANT_KEY)
  })

  const ns = selectedTenant ? `${TENANT_NAMESPACE_PREFIX}${selectedTenant}` : null

  // TenantNamespace is cluster-scoped. Always list the full set visible to the
  // current user. Filtering this request by selectedTenant makes a leaf tenant
  // disappear immediately after it is selected (for example root -> layersentry
  // -> no children), which incorrectly drives the UI into "No tenants found".
  const list = useK8sList<TenantNamespace>({
    apiGroup: "core.cozystack.io",
    apiVersion: "v1alpha1",
    plural: "tenantnamespaces",
  })

  const tenants = useMemo<TenantNamespace[]>(() => {
    return (list.data?.items ?? [])
      .slice()
      .sort((a, b) => displayName(a).localeCompare(displayName(b)))
  }, [list.data])

  useEffect(() => {
    if (!tenants.length) return
    if (selectedTenant && tenants.some((t) => displayName(t) === selectedTenant)) return
    const fallback =
      tenants.find((t) => displayName(t) === "root") ?? tenants[0]
    const fallbackName = displayName(fallback)
    setSelectedTenant(fallbackName)
    try {
      window.localStorage.setItem(SELECTED_TENANT_KEY, fallbackName)
    } catch {
      // ignore storage quota / private-mode failures
    }
  }, [tenants, selectedTenant])

  const selectTenant = (name: string) => {
    setSelectedTenant(name)
    try {
      window.localStorage.setItem(SELECTED_TENANT_KEY, name)
    } catch {
      // ignore storage quota / private-mode failures
    }
  }

  const value: TenantContextValue = {
    tenants,
    selectedTenant,
    selectTenant,
    tenantNamespace: list.isLoading ? null : ns,
    isLoading: list.isLoading,
    error: list.error,
  }

  return <TenantContext.Provider value={value}>{children}</TenantContext.Provider>
}

export function useTenantContext(): TenantContextValue {
  const ctx = useContext(TenantContext)
  if (!ctx) throw new Error("useTenantContext must be used inside TenantProvider")
  return ctx
}

/**
 * Pull the display name of a TenantNamespace (no `tenant-` prefix).
 */
export function tenantDisplayName(ns: TenantNamespace): string {
  return displayName(ns)
}
