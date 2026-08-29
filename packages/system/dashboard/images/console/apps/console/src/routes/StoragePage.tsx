import { StorageBackendHealth } from "../components/storage/StorageBackendHealth.tsx"
import { StorageLogicalManagement } from "../components/storage/StorageLogicalManagement.tsx"
import { StorageManagementOverview } from "../components/storage/StorageManagementOverview.tsx"

/**
 * Admin → Capacity → Storage.
 *
 * Physical-device discovery and initialization remain fail-closed and read-only.
 * Logical Kubernetes storage resources are administered through permission-gated
 * StorageClass, PVC and VolumeSnapshot controls below.
 */
export function StoragePage() {
  return (
    <div className="space-y-6 p-6">
      <div>
        <h1 className="text-xl font-semibold text-slate-900">Storage Management</h1>
        <p className="mt-0.5 text-sm text-slate-500">
          Physical-disk safety, backend health and permission-gated logical storage lifecycle management.
        </p>
      </div>
      <StorageManagementOverview />
      <StorageBackendHealth />
      <StorageLogicalManagement />
    </div>
  )
}
