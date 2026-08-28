# SPDX-License-Identifier: Apache-2.0

[CmdletBinding()]
param(
    [string]$ReconcilePath = (Join-Path $PSScriptRoot 'reconcile-network-fabric-talosconfig.ps1')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ReconcilePath)) { throw "NetworkFabric Talos reconcile script not found: $ReconcilePath" }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $ReconcilePath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)" }
    throw "PowerShell parser found $($errors.Count) error(s) in $ReconcilePath"
}

$text = Get-Content -Raw $ReconcilePath

function Assert-Contains([string]$Pattern,[string]$Message) {
    if ($text -notmatch $Pattern) { throw $Message }
}
function Assert-NotContains([string]$Pattern,[string]$Message) {
    if ($text -match $Pattern) { throw $Message }
}

# Regexes containing PowerShell variable names intentionally use single-quoted
# strings so the test validates the literal source text rather than interpolating
# this test script's own variables.
Assert-Contains '\$Namespace\s*=\s*''cozy-network-fabric-controller''' 'NetworkFabric controller namespace is not fixed to the chart namespace.'
Assert-Contains '\$SecretName\s*=\s*''network-fabric-talosconfig''' 'Expected NetworkFabric Talos Secret name is missing.'
Assert-Contains '\$SecretKey\s*=\s*''talosconfig''' 'Expected NetworkFabric Talos Secret key is missing.'
Assert-Contains 'Join-Path\s+\$StateRoot\s+''talosconfig''' 'Reconcile path does not source the preserved local Talos configuration.'
Assert-Contains 'Talos client configuration missing; refusing' 'Missing Talos configuration does not fail closed.'
Assert-Contains 'Wait-Until\s+-TimeoutSeconds\s+\$NamespaceTimeoutSeconds' 'Namespace reconciliation does not use a bounded readiness wait.'
Assert-Contains '''create'',''secret'',''generic'',\$SecretName' 'Secret manifest is not generated with kubectl create secret generic.'
Assert-Contains '''--dry-run=client''' 'Secret generation is not client-side/dry-run before apply.'
Assert-Contains '\$manifestProbe\.Text\s*\|\s*&\s*\$KubectlPath\s+''apply''\s+''-f''\s+''-''' 'Secret payload is not applied through stdin.'
Assert-Contains 'Get-FileHash\s+-Algorithm\s+SHA256' 'Reconciled Secret is not compared with the preserved Talos configuration.'
Assert-Contains 'credential payload suppressed' 'Success logging does not explicitly enforce payload suppression.'
Assert-Contains 'HelmRelease\s+\$Namespace/\$ControllerName\s+Ready' 'NetworkFabric HelmRelease readiness wait is missing.'
Assert-Contains 'deployment\s+\$Namespace/\$ControllerName\s+fully available' 'NetworkFabric Deployment readiness wait is missing.'
Assert-Contains 'all NetworkFabric controller pods Ready' 'NetworkFabric pod readiness wait is missing.'
Assert-NotContains 'Write-Host\s+\$manifestProbe' 'Secret manifest can be printed to logs.'
Assert-NotContains 'Write-Output\s+\$manifestProbe' 'Secret manifest can be emitted to logs.'
Assert-NotContains 'Set-Content[^\r\n]+\$manifestProbe' 'Secret manifest can be written to a file.'
Assert-NotContains 'Out-File[^\r\n]+\$manifestProbe' 'Secret manifest can be written to a file.'
Assert-NotContains 'ConvertTo-Json[^\r\n]+Write-(Host|Output)' 'Secret JSON can be written to logs.'

Write-Host "NetworkFabric Talos credential static safety validation PASSED: $ReconcilePath"
