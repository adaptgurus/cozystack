# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'ensure-default-image-certification.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ScriptPath)) { throw "Certification image setup script not found: $ScriptPath" }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }
    throw "PowerShell parser found $($errors.Count) error(s) in $ScriptPath"
}

$text = Get-Content -Raw $ScriptPath

function Assert-Contains([string]$Pattern,[string]$Message) {
    if ($text -notmatch $Pattern) { throw $Message }
}
function Assert-NotContains([string]$Pattern,[string]$Message) {
    if ($text -match $Pattern) { throw $Message }
}

Assert-Contains "PackageName\s*=\s*'cozystack\.vm-default-images'" 'Product vm-default-images Package is not used.'
Assert-Contains "PackageSourceName\s*=\s*'cozystack\.vm-default-images'" 'Product vm-default-images PackageSource prerequisite is not enforced.'
Assert-Contains "StorageClass\s*=\s*'replicated'" 'Certification image is not pinned to replicated storage.'
Assert-Contains "ImageName\s*=\s*'ubuntu-24\.04'" 'Certification fixture does not use the bounded Ubuntu 24.04 catalog image.'
Assert-Contains 'cloud-images\.ubuntu\.com/noble/current/noble-server-cloudimg-amd64\.img' 'Certification fixture is not using the product Ubuntu 24.04 source.'
Assert-Contains "storage:\s+20Gi" 'Certification image size is not capacity-bounded to 20Gi.'
Assert-Contains 'layersentry\.io/hci-certification-default-image' 'Certification ownership annotation is missing.'
Assert-Contains 'refusing to overwrite it' 'Administrator-managed image packages are not protected from fixture overwrite.'
Assert-Contains 'linstor\.csi\.linbit\.com' 'Replicated StorageClass provisioner identity is not checked.'
Assert-Contains 'DataVolume Succeeded' 'Certification setup does not wait for the CDI DataVolume to finish importing.'
Assert-Contains 'PVC Bound on replicated storage' 'Certification setup does not gate on the final Bound replicated PVC.'
Assert-Contains 'helmrelease\.helm\.toolkit\.fluxcd\.io.*\$ReleaseNamespace.*\$ReleaseName' 'Certification setup does not gate on the vm-default-images HelmRelease.'
Assert-NotContains "kubectl\s+delete|Invoke-Kubectl\s+'delete'" 'Certification image setup contains a destructive kubectl delete path.'
Assert-NotContains '16 images|320Gi' 'Certification setup appears to provision the full capacity-unsafe image catalog.'
Assert-NotContains 'kind:\s+VirtualMachine\b|kind:\s+VirtualMachineInstance\b' 'Certification image setup bypasses the product Package with raw KubeVirt objects.'

$sourceCheck = $text.IndexOf('PackageSource is not Ready')
$packageApply = $text.IndexOf("Invoke-Kubectl 'apply' '-f' `$tempFile")
$packageReady = $text.IndexOf('Package Ready')
$dvReady = $text.IndexOf('DataVolume Succeeded')
$pvcReady = $text.IndexOf('PVC Bound on replicated storage')
if ($sourceCheck -lt 0 -or $packageApply -le $sourceCheck) {
    throw 'Product PackageSource readiness is not checked before fixture mutation.'
}
if ($packageReady -le $packageApply -or $dvReady -le $packageReady -or $pvcReady -le $dvReady) {
    throw 'Package -> DataVolume -> PVC convergence ordering is not fail-closed.'
}

Write-Host "Default image certification static validation PASSED: $ScriptPath"
