# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string]$BootstrapPath = (Join-Path $PSScriptRoot 'bootstrap-production.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $BootstrapPath)) { throw "Bootstrap not found: $BootstrapPath" }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $BootstrapPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }
    throw "PowerShell parser found $($errors.Count) error(s) in $BootstrapPath"
}

$text = Get-Content -Raw $BootstrapPath

function Assert-Contains([string]$Pattern,[string]$Message) {
    if ($text -notmatch $Pattern) { throw $Message }
}
function Assert-NotContains([string]$Pattern,[string]$Message) {
    if ($text -match $Pattern) { throw $Message }
}

Assert-Contains 'function\s+Get-LinstorText' 'Get-LinstorText helper is missing.'
Assert-Contains '\$allArgs\s*=\s*@\(' 'LINSTOR argument list is not assembled explicitly.'
Assert-Contains 'Assert-AuthenticatedDataDiskIdentity\s+-Node\s+\$node\s+-RequireBlank' 'Storage mutation lacks authenticated blank-disk revalidation.'
Assert-Contains "physical-storage','create-device-pool','zfs'" 'LINSTOR ZFS device-pool creation path is missing.'
Assert-Contains 'function\s+Get-LinstorSatellitePodForNode' 'Dynamic LINSTOR satellite discovery helper is missing.'
Assert-Contains '\.spec\.nodeName\s+-eq\s+\$NodeName' 'LINSTOR satellite discovery is not bound to the expected Kubernetes node.'
Assert-Contains 'StartsWith\("linstor-satellite\.\$NodeName-' 'LINSTOR satellite discovery does not tolerate rollout pod suffixes.'
Assert-Contains 'Get-LinstorSatellitePodForNode\s+-NodeName\s+\$k8sName' 'ZFS failmode verification does not use dynamic LINSTOR satellite discovery.'
Assert-NotContains '\$podName\s*=\s*"linstor-satellite\.\$k8sName"' 'Bootstrap still hard-codes a suffix-less LINSTOR satellite pod name.'
Assert-Contains ([regex]::Escape("'--patch-file' `$patchFile")) 'Root tenant patch does not use a file-safe kubectl transport.'
Assert-Contains 'Set-Content\s+-Path\s+\$patchFile\s+-Value\s+\$tenantPatch' 'Root tenant patch payload is not persisted before kubectl patch.'
Assert-NotContains "'--type=merge'\s+'-p'\s+'\{" 'Bootstrap still passes inline JSON patch text to a Windows native command.'
Assert-Contains 'refusing to bootstrap etcd again' 'Existing authenticated Talos cluster does not fail closed against duplicate etcd bootstrap.'
Assert-Contains 'Digest-pinned LayerSentry installer is required' 'Digest-pinned custom installer guard is missing.'
Assert-Contains 'packages\.cozystack\.io' 'Package CRD readiness gate is missing.'
Assert-Contains 'packagesources\.cozystack\.io' 'PackageSource CRD readiness gate is missing.'
Assert-Contains 'Cilium DaemonSet ready on all three nodes' 'Cilium readiness gate is missing.'
Assert-Contains 'three LINSTOR data storage pools' 'All-node LINSTOR storage-pool gate is missing.'
Assert-NotContains 'oci://ghcr\.io/cozystack/cozystack/cozy-installer' 'Bootstrap contains an upstream installer URI and can bypass custom provenance.'
Assert-NotContains "Invoke-External\s+\$Talm\s+'bootstrap'" 'Bootstrap still uses Talm for etcd bootstrap rather than authenticated talosctl.'

$lines = Get-Content $BootstrapPath
$mutationIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "create-device-pool','zfs'") { $mutationIndex = $i; break }
}
if ($mutationIndex -lt 0) { throw 'Storage mutation line was not found.' }

$windowStart = [Math]::Max(0, $mutationIndex - 14)
$window = ($lines[$windowStart..$mutationIndex] -join "`n")
$rechecks = ([regex]::Matches($window,'Assert-AuthenticatedDataDiskIdentity\s+-Node\s+\$node\s+-RequireBlank')).Count
if ($rechecks -lt 1) {
    throw 'No authenticated blank-disk check exists immediately before create-device-pool.'
}

Write-Host "Bootstrap static safety validation PASSED: $BootstrapPath"
