import { Link, Navigate, Route, Routes } from "react-router"
import { Section, Spinner } from "@cozystack/ui"
import { useAdminAccess } from "./sidebar-sections.tsx"
import { ClusterUsagePage } from "./ClusterUsagePage.tsx"
import { ClusterUsageResourcePage } from "./ClusterUsageResourcePage.tsx"
import { StorageClassUsagePage } from "./StorageClassUsagePage.tsx"
import { StoragePage } from "./StoragePage.tsx"
import { NodesPage } from "./NodesPage.tsx"
import { NetworkFabricPage } from "./NetworkFabricPage.tsx"
import { BackupClassListPage } from "./BackupClassListPage.tsx"
import { BackupClassCreatePage } from "./BackupClassCreatePage.tsx"
import { BackupClassDetailPage } from "./BackupClassDetailPage.tsx"
import { BackupClassEditPage } from "./BackupClassEditPage.tsx"
import { BackupClassAdminGuard } from "./BackupClassAdminGuard.tsx"
import { CapacityAdminGuard } from "./CapacityAdminGuard.tsx"

/**
 * Admin portal at /admin/*, hosting cluster-wide operator areas with
 * independent permissions. Capacity and Network Fabric use the cluster
 * operator access check (nodes/list); Backup Classes has its own permission.
 * Per-area guards close direct-URL access holes that sidebar hiding alone
 * cannot protect. While the review is in flight we show a spinner; a user with
 * neither area gets a 403 notice.
 */
export function AdminPage() {
  const { allowed, isLoading, canClusterUsage } = useAdminAccess()

  if (isLoading) {
    return (
      <div className="flex items-center gap-2 p-6 text-sm text-slate-500">
        <Spinner /> Loading…
      </div>
    )
  }

  if (!allowed) {
    return (
      <div className="p-6">
        <Section>
          <div className="px-2 py-4 text-sm text-slate-700">
            You do not have permission to access the Admin portal.{" "}
            <Link to="/console" className="text-blue-700 underline hover:text-blue-800">
              Back to console
            </Link>
            .
          </div>
        </Section>
      </div>
    )
  }

  return (
    <Routes>
      <Route
        index
        element={
          <Navigate
            to={canClusterUsage ? "capacity/cluster" : "backups/backupclasses"}
            replace
          />
        }
      />
      <Route element={<CapacityAdminGuard />}>
        <Route path="capacity/cluster" element={<ClusterUsagePage />} />
        <Route path="capacity/cluster/r/*" element={<ClusterUsageResourcePage />} />
        <Route path="capacity/cluster/sc/*" element={<StorageClassUsagePage />} />
        <Route path="capacity/storage" element={<StoragePage />} />
        <Route path="capacity/nodes" element={<NodesPage />} />
        <Route path="network/fabric" element={<NetworkFabricPage />} />
      </Route>
      <Route element={<BackupClassAdminGuard />}>
        <Route path="backups/backupclasses" element={<BackupClassListPage />} />
        <Route path="backups/backupclasses/create" element={<BackupClassCreatePage />} />
        <Route path="backups/backupclasses/:name" element={<BackupClassDetailPage />} />
        <Route path="backups/backupclasses/:name/edit" element={<BackupClassEditPage />} />
      </Route>
    </Routes>
  )
}
