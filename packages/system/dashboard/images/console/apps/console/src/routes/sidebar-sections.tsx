import { useMemo } from "react"
import {
  Archive,
  Cloud,
  Database,
  Gauge,
  Globe,
  HardDrive,
  Info,
  LayoutGrid,
  Layers,
  Network,
  Server,
  ToyBrick,
  Users,
  type LucideIcon,
} from "lucide-react"
import type { SidebarSection } from "@cozystack/ui"
import { useBackupClassAdminAccess } from "../hooks/useBackupClassAdminAccess.ts"
import { useClusterUsageAccess } from "../hooks/useClusterUsageAccess.ts"
import { useApplicationDefinitions, groupByCategory } from "../lib/app-definitions.ts"
import { humanizeKind } from "../lib/humanize.ts"
import {
  lucideIcon,
  simpleIconComponent,
  simpleIconSlug,
} from "../lib/sidebar-icons.tsx"
import type { ComponentType } from "react"

const MARKETPLACE_CATEGORIES = ["IaaS", "PaaS", "NaaS"]
const CATEGORY_ICON: Record<string, LucideIcon> = {
  IaaS: Cloud,
  PaaS: Database,
  NaaS: Network,
}

/**
 * Marketplace sidebar: a flat list of filters — "All applications" followed
 * by the three categories. Category links rely on pathname-based matching
 * (`/marketplace/c/<category>`) so NavLink correctly highlights the active
 * entry; see MarketplaceList for the counterpart.
 */
export function useMarketplaceSidebarSections(): SidebarSection[] {
  const { data } = useApplicationDefinitions()
  const grouped = useMemo(() => groupByCategory(data), [data])

  return useMemo<SidebarSection[]>(() => {
    const available = grouped
      .map((g) => g.category)
      .filter((c) => MARKETPLACE_CATEGORIES.includes(c))
    const ordered = MARKETPLACE_CATEGORIES.filter((c) => available.includes(c))

    return [
      {
        title: "Marketplace",
        items: [
          { label: "Marketplace", to: "/marketplace", end: true, icon: LayoutGrid },
          ...ordered.map((category) => ({
            label: category,
            to: `/marketplace/c/${encodeURIComponent(category)}`,
            icon: CATEGORY_ICON[category] ?? LayoutGrid,
          })),
        ],
      },
    ]
  }, [grouped])
}

/**
 * Console sidebar: every non-module, non-Tenant ApplicationDefinition in the
 * cluster as a separate entry grouped by IaaS / PaaS / NaaS, plus a fixed
 * Administration section (Info, Modules, External IPs, Tenants).
 */
export function useConsoleSidebarSections(): SidebarSection[] {
  const { data } = useApplicationDefinitions()
  const grouped = useMemo(() => groupByCategory(data), [data])

  return useMemo<SidebarSection[]>(() => {
    const sorted = [...grouped]
      .filter(({ category }) => MARKETPLACE_CATEGORIES.includes(category))
      .sort(
        (a, b) =>
          MARKETPLACE_CATEGORIES.indexOf(a.category) -
          MARKETPLACE_CATEGORIES.indexOf(b.category),
      )

    const categorySections: SidebarSection[] = sorted.map(({ category, items }) => ({
      title: category,
      items: items.map((ad) => {
        const kind = ad.spec?.application.kind ?? ad.metadata.name
        const plural = ad.spec?.application.plural ?? ad.metadata.name
        const slug = simpleIconSlug(kind)
        const lucide = lucideIcon(kind)
        const icon: ComponentType<{ className?: string }> | LucideIcon =
          slug ? simpleIconComponent(slug) : (lucide ?? Layers)
        return {
          label: humanizeKind(kind),
          to: `/console/${plural}`,
          icon,
        }
      }),
    }))

    const backupsSection: SidebarSection = {
      title: "Backups",
      items: [
        { label: "Plans", to: "/console/backups/plans", icon: Archive },
        { label: "Backup Jobs", to: "/console/backups/backupjobs", icon: Archive },
        { label: "Backups", to: "/console/backups/backups", icon: Archive },
        { label: "Restore Jobs", to: "/console/backups/restorejobs", icon: Archive },
      ],
    }

    const administrationSection: SidebarSection = {
      title: "Administration",
      items: [
        { label: "Info", to: "/console/info", icon: Info },
        { label: "Modules", to: "/console/modules", icon: ToyBrick },
        { label: "External IPs", to: "/console/external-ips", icon: Globe },
        { label: "Tenants", to: "/console/tenants", icon: Users },
      ],
    }

    return [...categorySections, backupsSection, administrationSection]
  }, [grouped])
}

/**
 * Access check for the Admin portal. The portal hosts cluster-wide operator
 * areas with independent permissions. Capacity and Network Fabric use the
 * cluster operator check (proxied by nodes/list); Backup Classes requires
 * backupclasses/update. A user sees the portal if they can use at least one.
 */
export function useAdminAccess(): {
  allowed: boolean
  isLoading: boolean
  canClusterUsage: boolean
  canBackupClasses: boolean
} {
  const clusterUsage = useClusterUsageAccess()
  const backupClasses = useBackupClassAdminAccess()
  const canClusterUsage = clusterUsage.allowed
  const canBackupClasses = backupClasses.allowed
  return {
    isLoading: clusterUsage.isLoading || backupClasses.isLoading,
    allowed: canClusterUsage || canBackupClasses,
    canClusterUsage,
    canBackupClasses,
  }
}

/** Boolean convenience wrapper around {@link useAdminAccess} for nav gating. */
export function useCanSeeAdmin(): boolean {
  return useAdminAccess().allowed
}

/**
 * Admin sidebar: cluster-wide operator areas. Network Fabric is intentionally
 * a first-class area rather than hiding host networking under Capacity.
 */
export function useAdminSidebarSections(): SidebarSection[] {
  const { canClusterUsage, canBackupClasses } = useAdminAccess()
  return useMemo<SidebarSection[]>(() => {
    const sections: SidebarSection[] = []
    if (canClusterUsage) {
      sections.push({
        title: "Capacity",
        items: [
          { label: "Cluster", to: "/admin/capacity/cluster", icon: Gauge },
          { label: "Nodes", to: "/admin/capacity/nodes", icon: Server },
          { label: "Storage", to: "/admin/capacity/storage", icon: HardDrive },
        ],
      })
      sections.push({
        title: "Network",
        items: [
          { label: "Network Fabric", to: "/admin/network/fabric", icon: Network },
        ],
      })
    }
    if (canBackupClasses) {
      sections.push({
        title: "Backups",
        items: [
          { label: "Backup Classes", to: "/admin/backups/backupclasses", icon: Archive },
        ],
      })
    }
    return sections
  }, [canClusterUsage, canBackupClasses])
}
