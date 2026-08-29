param(
  [Parameter(Mandatory = $true)][string]$Talosctl,
  [Parameter(Mandatory = $true)][string]$Talosconfig,
  [Parameter(Mandatory = $true)][string[]]$Nodes,
  [Parameter(Mandatory = $true)][string]$Output,
  [string]$SourceCommit = $env:GITHUB_SHA,
  [string]$SourceRun = $env:GITHUB_RUN_ID
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PropertyValue {
  param($Object, [string]$Name, $Default = $null)
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $Default }
  return $property.Value
}

function Invoke-TalosText {
  param([string]$Node, [string[]]$Arguments, [switch]$AllowFailure)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $text = (& $Talosctl --talosconfig $Talosconfig -n $Node -e $Node @Arguments 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previous
  }
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "talosctl failed for node $Node: $($Arguments -join ' '): $text"
  }
  return [pscustomobject]@{ Ok = ($exitCode -eq 0); Text = $text }
}

function Invoke-TalosJson {
  param([string]$Node, [string]$Resource)
  $result = Invoke-TalosText -Node $Node -Arguments @('get', $Resource, '-o', 'json')
  if (-not $result.Text) { return @() }
  try {
    return @($result.Text | ConvertFrom-Json)
  } catch {
    throw "invalid JSON returned by talosctl get $Resource on $Node"
  }
}

function Read-SysfsInteger {
  param([string]$Node, [string]$Path)
  $result = Invoke-TalosText -Node $Node -Arguments @('read', $Path) -AllowFailure
  if (-not $result.Ok) { return $null }
  $value = 0
  if ([int]::TryParse($result.Text.Trim(), [ref]$value)) { return $value }
  return $null
}

function Test-RdmaLink {
  param([string]$Node, [string]$Interface)
  $path = "/sys/class/net/$Interface/device/infiniband"
  $result = Invoke-TalosText -Node $Node -Arguments @('list', $path, '-d', '1') -AllowFailure
  if (-not $result.Ok) {
    return [ordered]@{ supported = $false; devices = @(); source = 'sysfs:not-present' }
  }
  $devices = @()
  foreach ($line in ($result.Text -split "`r?`n")) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed -match '^(NODE|TYPE|NAME|MODE|SIZE|MODIFIED)\b') { continue }
    $match = [regex]::Match($trimmed, 'infiniband[\\/]+([^\\/\s]+)')
    if ($match.Success) { $devices += $match.Groups[1].Value }
  }
  $devices = @($devices | Sort-Object -Unique)
  return [ordered]@{
    supported = ($devices.Count -gt 0)
    devices = $devices
    source = $(if ($devices.Count -gt 0) { 'sysfs:infiniband' } else { 'sysfs:empty' })
  }
}

function Normalize-Link {
  param([string]$Node, $Resource)
  $metadata = Get-PropertyValue $Resource 'metadata'
  $spec = Get-PropertyValue $Resource 'spec'
  $name = [string](Get-PropertyValue $metadata 'id' '')
  $kind = [string](Get-PropertyValue $spec 'kind' '')
  $driver = [string](Get-PropertyValue $spec 'driver' '')
  $speed = Get-PropertyValue $spec 'speedMbit'
  if ($null -eq $speed) { $speed = Get-PropertyValue $spec 'speedMegabits' }
  if ($null -ne $speed) {
    $speedNumber = [int64]$speed
    if ($speedNumber -le 0 -or $speedNumber -ge 4294967295) { $speed = $null }
    else { $speed = $speedNumber }
  }

  $isPhysical = [string]::IsNullOrWhiteSpace($kind) -and -not [string]::IsNullOrWhiteSpace($driver) -and $name -ne 'lo'
  $sriov = [ordered]@{ supported = $null; totalVfs = $null; configuredVfs = $null; source = 'not-probed' }
  $rdma = [ordered]@{ supported = $null; devices = @(); source = 'not-probed' }
  if ($isPhysical) {
    $totalVfs = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/device/sriov_totalvfs"
    $configuredVfs = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/device/sriov_numvfs"
    if ($null -ne $totalVfs) {
      $sriov.supported = ($totalVfs -gt 0)
      $sriov.totalVfs = $totalVfs
      $sriov.configuredVfs = $configuredVfs
      $sriov.source = 'sysfs:sriov_totalvfs'
    } else {
      $sriov.supported = $false
      $sriov.source = 'sysfs:not-present'
    }
    $rdma = Test-RdmaLink -Node $Node -Interface $name
  }

  $vlan = Get-PropertyValue $spec 'vlan'
  $vlanId = Get-PropertyValue $vlan 'vid'
  if ($null -eq $vlanId) { $vlanId = Get-PropertyValue $vlan 'id' }

  return [ordered]@{
    name = $name
    index = Get-PropertyValue $spec 'index'
    type = [string](Get-PropertyValue $spec 'type' 'unknown')
    kind = $(if ($kind) { $kind } elseif ($isPhysical) { 'physical' } else { 'unknown' })
    physical = $isPhysical
    linkIndex = Get-PropertyValue $spec 'linkIndex'
    masterIndex = Get-PropertyValue $spec 'masterIndex'
    master = $null
    linkUp = Get-PropertyValue $spec 'linkState'
    operationalState = [string](Get-PropertyValue $spec 'operationalState' 'unknown')
    mac = [string](Get-PropertyValue $spec 'hardwareAddr' '')
    permanentMac = [string](Get-PropertyValue $spec 'permanentAddr' '')
    mtu = Get-PropertyValue $spec 'mtu'
    speedMbps = $speed
    driver = $driver
    driverVersion = [string](Get-PropertyValue $spec 'driverVersion' '')
    firmwareVersion = [string](Get-PropertyValue $spec 'firmwareVersion' '')
    pciId = [string](Get-PropertyValue $spec 'pciid' '')
    vendor = [string](Get-PropertyValue $spec 'vendor' '')
    port = [string](Get-PropertyValue $spec 'port' '')
    duplex = [string](Get-PropertyValue $spec 'duplex' '')
    vlanId = $vlanId
    sriov = $sriov
    rdma = $rdma
  }
}

function Normalize-Address {
  param($Resource)
  $spec = Get-PropertyValue $Resource 'spec'
  return [ordered]@{
    address = [string](Get-PropertyValue $spec 'address' '')
    local = [string](Get-PropertyValue $spec 'local' '')
    linkName = [string](Get-PropertyValue $spec 'linkName' '')
    linkIndex = Get-PropertyValue $spec 'linkIndex'
    family = [string](Get-PropertyValue $spec 'family' '')
    scope = [string](Get-PropertyValue $spec 'scope' '')
  }
}

function Normalize-Route {
  param($Resource)
  $spec = Get-PropertyValue $Resource 'spec'
  $metric = Get-PropertyValue $spec 'metric'
  if ($null -eq $metric) { $metric = Get-PropertyValue $spec 'priority' 0 }
  return [ordered]@{
    destination = [string](Get-PropertyValue $spec 'dst' '')
    source = [string](Get-PropertyValue $spec 'src' '')
    gateway = [string](Get-PropertyValue $spec 'gateway' '')
    outLinkName = [string](Get-PropertyValue $spec 'outLinkName' '')
    outLinkIndex = Get-PropertyValue $spec 'outLinkIndex'
    family = [string](Get-PropertyValue $spec 'family' '')
    table = Get-PropertyValue $spec 'table'
    metric = $metric
    protocol = [string](Get-PropertyValue $spec 'protocol' '')
  }
}

function Resolve-ManagementPath {
  param([object[]]$Routes)
  $defaults = @($Routes | Where-Object {
    $_.destination -in @('', 'default', '0.0.0.0/0', '::/0') -and $_.outLinkName
  })
  if ($defaults.Count -eq 0) {
    return [ordered]@{ interface = $null; gateway = $null; confidence = 'unknown'; reason = 'no-default-route-observed' }
  }
  $minimum = ($defaults | ForEach-Object { if ($null -eq $_.metric) { 0 } else { [int64]$_.metric } } | Measure-Object -Minimum).Minimum
  $best = @($defaults | Where-Object { (if ($null -eq $_.metric) { 0 } else { [int64]$_.metric }) -eq $minimum })
  $interfaces = @($best | Select-Object -ExpandProperty outLinkName -Unique)
  if ($interfaces.Count -ne 1) {
    return [ordered]@{ interface = $null; gateway = $null; confidence = 'unknown'; reason = 'ambiguous-equal-priority-default-routes' }
  }
  $gateways = @($best | Select-Object -ExpandProperty gateway -Unique | Where-Object { $_ })
  return [ordered]@{
    interface = $interfaces[0]
    gateway = $(if ($gateways.Count -eq 1) { $gateways[0] } else { $null })
    confidence = 'high'
    reason = 'lowest-priority-default-route'
  }
}

$inventoryNodes = @()
foreach ($node in $Nodes) {
  $node = $node.Trim()
  if (-not $node) { continue }
  Write-Host "Collecting Talos network resources from $node"
  try {
    $linksRaw = @(Invoke-TalosJson -Node $node -Resource 'links')
    $addressesRaw = @(Invoke-TalosJson -Node $node -Resource 'addresses')
    $routesRaw = @(Invoke-TalosJson -Node $node -Resource 'routes')
    $resolversRaw = @(Invoke-TalosJson -Node $node -Resource 'resolvers')
    $nodeNameRaw = @(Invoke-TalosJson -Node $node -Resource 'nodename')

    $links = @($linksRaw | ForEach-Object { Normalize-Link -Node $node -Resource $_ })
    $indexToName = @{}
    foreach ($link in $links) {
      if ($null -ne $link.index) { $indexToName[[string]$link.index] = $link.name }
    }
    foreach ($link in $links) {
      if ($null -ne $link.masterIndex -and $indexToName.ContainsKey([string]$link.masterIndex)) {
        $link.master = $indexToName[[string]$link.masterIndex]
      }
    }

    $addresses = @($addressesRaw | ForEach-Object { Normalize-Address $_ })
    $routes = @($routesRaw | ForEach-Object { Normalize-Route $_ })
    $resolverValues = @()
    foreach ($resolver in $resolversRaw) {
      $spec = Get-PropertyValue $resolver 'spec'
      foreach ($key in @('dnsServers', 'resolvers')) {
        $values = Get-PropertyValue $spec $key
        if ($null -ne $values) { $resolverValues += @($values) }
      }
    }
    $resolverValues = @($resolverValues | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)

    $name = $node
    if ($nodeNameRaw.Count -gt 0) {
      $spec = Get-PropertyValue $nodeNameRaw[0] 'spec'
      foreach ($key in @('nodename', 'hostname', 'name')) {
        $candidate = [string](Get-PropertyValue $spec $key '')
        if ($candidate) { $name = $candidate; break }
      }
    }

    $inventoryNodes += [ordered]@{
      name = $name
      endpoint = $node
      collectedAt = [DateTime]::UtcNow.ToString('o')
      state = 'ready'
      error = $null
      management = Resolve-ManagementPath -Routes $routes
      links = $links
      addresses = $addresses
      routes = $routes
      resolvers = $resolverValues
    }
  } catch {
    $inventoryNodes += [ordered]@{
      name = $node
      endpoint = $node
      collectedAt = [DateTime]::UtcNow.ToString('o')
      state = 'error'
      error = $_.Exception.Message
      management = [ordered]@{ interface = $null; gateway = $null; confidence = 'unknown'; reason = 'collection-failed' }
      links = @()
      addresses = @()
      routes = @()
      resolvers = @()
    }
  }
}

$readyCount = @($inventoryNodes | Where-Object { $_.state -eq 'ready' }).Count
$report = [ordered]@{
  schemaVersion = 'network.layersentry.io/v1alpha1'
  generatedAt = [DateTime]::UtcNow.ToString('o')
  sourceCommit = $SourceCommit
  sourceRun = $SourceRun
  source = 'talos-resource-api+sysfs'
  nodeCount = $inventoryNodes.Count
  readyNodeCount = $readyCount
  partial = ($readyCount -ne $inventoryNodes.Count)
  nodes = $inventoryNodes
}

$json = $report | ConvertTo-Json -Depth 20
if ($json -match 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|client-key-data|talosconfig') {
  throw 'refusing to publish inventory containing credential material'
}
$parent = Split-Path -Parent $Output
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText($Output, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "NETWORK_INVENTORY nodes=$($inventoryNodes.Count) ready=$readyCount partial=$($report.partial) output=$Output"
