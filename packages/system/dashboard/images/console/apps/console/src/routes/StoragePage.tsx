import { StorageBackendHealth } from "../components/storage/StorageBackendHealth.tsx"
import { StorageManagementOverview } from "../components/storage/StorageManagementOverview.tsx"

/**
 * Admin → Capacity → Storage.
 *
 * Cluster-wide operational storage management: physical disk certification,
 * StorageClasses/backends, PV/PVC health and CSI snapshot visibility. The page
 * is deliberately read-only while physical-device initialization remains
 * locked behind the server-side identity and existing-data safety gates.
 */
export function StoragePage() {
  return (
    <div className="space-y-6 p-6">
      <div>
        <h1 className="text-xl font-semibold text-slate-900">Storage Management</h1>
        <p className="mt-0.5 text-sm text-slate-500">
          Cluster storage inventory, backend health, claims, volumes and snapshots with fail-closed
          physical-disk safety.
        </p>
      </div>
      <StorageManagementOverview />
      <StorageBackendHealth />
    </div>
  )
}
