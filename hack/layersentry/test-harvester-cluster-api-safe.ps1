[CmdletBinding()]
param(
    [string]$ClusterUrl = 'https://10.10.10.10',
    [string]$CredentialPath = 'C:\ProgramData\LayerSentry\bootstrap-credentials.json',
    [string]$OutputDirectory = (Join-Path $env:RUNNER_TEMP 'layersentry-harvester-api-validation')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The underlying validator intentionally writes a complete evidence document in
# its finally block even when authentication or an API call fails. Define every
# optional result in this parent scope so PowerShell strict mode cannot mask the
# original diagnostic before a child-scope assignment occurs.
$versionResponse = $null
$nodesResponse = $null
$podsResponse = $null
$deploymentsResponse = $null
$storageClassesResponse = $null
$kubevirtResponse = $null
$virtHandlersResponse = $null
$longhornNodesResponse = $null
$harvesterSettingsResponse = $null
$nodes = $null
$pods = $null
$deployments = $null
$storageClasses = $null
$kubevirts = $null
$virtHandlers = $null
$longhornNodes = $null
$safeSettings = $null
$unhealthyDeployments = $null
$unhealthyPods = $null
$criticalUnhealthyPods = $null
$readyNodeCount = $null
$kubevirtAvailable = $null
$readyVirtHandlerCount = $null
$readyLonghornNodeCount = $null
$schedulableLonghornNodeCount = $null

$validator = Join-Path $PSScriptRoot 'test-harvester-cluster-api.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Underlying Harvester API validator is missing: $validator"
}

& $validator `
    -ClusterUrl $ClusterUrl `
    -CredentialPath $CredentialPath `
    -OutputDirectory $OutputDirectory
