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

function Read-SysfsText {
  param([string]$Node, [string]$Path)
  $result = Invoke-TalosText -Node $Node -Arguments @('read', $Path) -AllowFailure
  if (-not $result.Ok) {
    return [pscustomobject]@{ Ok = $false; Value = $null }
  }
  $value = $result.Text.Trim()
  return [pscustomobject]@{ Ok = $true; Value = $value }
}

function Read-SysfsInteger {
  param([string]$Node, [string]$Path)
  $result = Read-SysfsText -Node $Node -Path $Path
  if (-not $result.Ok) {
    return [pscustomobject]@{ Ok = $false; Value = $null }
  }
  $value = [int64]0
  if ([int64]::TryParse([string]$result.Value, [ref]$value)) {
    return [pscustomobject]@{ Ok = $true; Value = $value }
  }
  return [pscustomobject]@{ Ok = $false; Value = $null }
}

function Convert-LinkState {
  param($Value)
  if ($Value -is [bool]) { return $Value }
  if ($null -eq $Value) { return $null }
  switch (([string]$Value).Trim().ToLowerInvariant()) {
    'up' { return $true }
    'true' { return $true }
    '1' { return $true }
    'down' { return $false }
    'false' { return $false }
    '0' { return $false }
    default { return $null }
  }
}

function Test-RdmaLink {
  param([string]$Node, [string]$Interface)
  $path = "/sys/class/net/$Interface/device/infiniband"
  $result = Invoke-TalosText -Node $Node -Arguments @('list', $path, '-d', '1') -AllowFailure
  if (-not $result.Ok) {
    return [ordered]@{
      supported = $null
      devices = @()
      source = 'sysfs:unavailable'
      reason = 'infiniband-sysfs-not-readable'
    }
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
    reason = $(if ($devices.Count -gt 0) { 'rdma-device-observed' } else { 'no-rdma-device-observed' })
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
  $sriov = [ordered]@{ supported = $null; totalVfs = $null; configuredVfs = $null; source = 'not-probed'; reason = 'not-physical' }
  $rdma = [ordered]@{ supported = $null; devices = @(); source = 'not-probed'; reason = 'not-physical' }

  $linkUp = Convert-LinkState (Get-PropertyValue $spec 'linkState')
  if ($null -eq $linkUp -and $name) {
    $carrier = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/carrier"
    if ($carrier.Ok) { $linkUp = ($carrier.Value -eq 1) }
  }

  $operationalState = [string](Get-PropertyValue $spec 'operationalState' '')
  if (-not $operationalState -and $name) {
    $operstate = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/operstate"
    if ($operstate.Ok) { $operationalState = [string]$operstate.Value }
  }
  if (-not $operationalState) { $operationalState = 'unknown' }

  $duplex = [string](Get-PropertyValue $spec 'duplex' '')
  if (-not $duplex -and $isPhysical) {
    $duplexProbe = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/duplex"
    if ($duplexProbe.Ok) { $duplex = [string]$duplexProbe.Value }
  }

  if ($null -eq $speed -and $isPhysical) {
    $speedProbe = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/speed"
    if ($speedProbe.Ok -and $speedProbe.Value -gt 0 -and $speedProbe.Value -lt 4294967295) {
      $speed = $speedProbe.Value
    }
  }

  if ($isPhysical) {
    $totalVfs = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/device/sriov_totalvfs"
    $configuredVfs = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/device/sriov_numvfs"
    if ($totalVfs.Ok) {
      $sriov.supported = ($totalVfs.Value -gt 0)
      $sriov.totalVfs = $totalVfs.Value
      $sriov.configuredVfs = $(if ($configuredVfs.Ok) { $configuredVfs.Value } else { $null })
      $sriov.source = 'sysfs:sriov_totalvfs'
      $sriov.reason = $(if ($totalVfs.Value -gt 0) { 'vf-capability-observed' } else { 'zero-total-vfs-observed' })
    } else {
      $sriov.supported = $null
      $sriov.source = 'sysfs:unavailable'
      $sriov.reason = 'sriov-sysfs-not-readable'
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
    parent = $null
    masterIndex = Get-PropertyValue $spec 'masterIndex'
    master = $null
    linkUp = $linkUp
    operationalState = $operationalState
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
    duplex = $duplex
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

function Get-RouteFamily {
  param($Route)
  $family = ([string]$Route.family).ToLowerInvariant()
  if ($family -match '6') { return 'ipv6' }
  if ($family -match '4') { return 'ipv4' }
  if ($Route.destination -eq '::/0' -or $Route.gateway -match ':') { return 'ipv6' }
  if ($Route.destination -eq '0.0.0.0/0' -or $Route.gateway -match '^\d+\.\d+\.\d+\.\d+$') { return 'ipv4' }
  return 'unknown'
}

function Get-EndpointFamily {
  param([string]$Endpoint)
  $address = $Endpoint.Trim().Trim('[', ']')
  $parsed = $null
  if ([System.Net.IPAddress]::TryParse($address, [ref]$parsed)) {
    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { return 'ipv4' }
    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return 'ipv6' }
  }
  return 'unknown'
}

function Get-PhysicalUnderlay {
  param([string]$Interface, [object[]]$Links)
  if (-not $Interface) { return @() }
  $byName = @{}
  foreach ($link in $Links) { if ($link.name) { $byName[$link.name] = $link } }
  $result = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

  function Visit-Link {
    param([string]$Name)
    if (-not $Name -or -not $visited.Add($Name)) { return }
    if (-not $byName.ContainsKey($Name)) { return }
    $current = $byName[$Name]
    if ($current.physical) {
      [void]$result.Add($current.name)
      return
    }
    if ($current.parent) { Visit-Link -Name $current.parent }
    foreach ($child in @($Links | Where-Object { $_.master -eq $Name })) {
      Visit-Link -Name $child.name
    }
  }

  Visit-Link -Name $Interface
  return @($result | Sort-Object)
}

function Resolve-ManagementPath {
  param([object[]]$Routes, [object[]]$Links, [object[]]$Addresses, [string]$Endpoint)
  $defaults = @($Routes | Where-Object {
    $_.destination -in @('', 'default', '0.0.0.0/0', '::/0') -and $_.outLinkName
  })
  if ($defaults.Count -eq 0) {
    return [ordered]@{ interface = $null; physicalInterfaces = @(); addresses = @(); gateway = $null; family = $null; confidence = 'unknown'; reason = 'no-default-route-observed' }
  }

  $endpointFamily = Get-EndpointFamily -Endpoint $Endpoint
  if ($endpointFamily -ne 'unknown') {
    $familyDefaults = @($defaults | Where-Object { (Get-RouteFamily $_) -eq $endpointFamily })
    if ($familyDefaults.Count -gt 0) { $defaults = $familyDefaults }
  }

  $minimum = ($defaults | ForEach-Object { if ($null -eq $_.metric) { 0 } else { [int64]$_.metric } } | Measure-Object -Minimum).Minimum
  $best = @($defaults | Where-Object { (if ($null -eq $_.metric) { 0 } else { [int64]$_.metric }) -eq $minimum })
  $interfaces = @($best | Select-Object -ExpandProperty outLinkName -Unique)
  if ($interfaces.Count -ne 1) {
    return [ordered]@{ interface = $null; physicalInterfaces = @(); addresses = @(); gateway = $null; family = $(if ($endpointFamily -ne 'unknown') { $endpointFamily } else { $null }); confidence = 'unknown'; reason = 'ambiguous-equal-priority-default-routes' }
  }

  $interface = $interfaces[0]
  $gateways = @($best | Select-Object -ExpandProperty gateway -Unique | Where-Object { $_ })
  $family = Get-RouteFamily $best[0]
  if ($family -eq 'unknown') { $family = $endpointFamily }
  if ($family -eq 'unknown') { $family = $null }
  $managementAddresses = @($Addresses | Where-Object { $_.linkName -eq $interface } | ForEach-Object { $_.address } | Where-Object { $_ } | Sort-Object -Unique)
  $physicalInterfaces = @(Get-PhysicalUnderlay -Interface $interface -Links $Links)
  $confidence = $(if ($physicalInterfaces.Count -gt 0) { 'high' } else { 'medium' })

  return [ordered]@{
    interface = $interface
    physicalInterfaces = $physicalInterfaces
    addresses = $managementAddresses
    gateway = $(if ($gateways.Count -eq 1) { $gateways[0] } else { $null })
    family = $family
    confidence = $confidence
    reason = $(if ($endpointFamily -ne 'unknown') { "lowest-priority-$endpointFamily-default-route" } else { 'lowest-priority-default-route' })
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
      if ($null -ne $link.linkIndex -and $indexToName.ContainsKey([string]$link.linkIndex)) {
        $link.parent = $indexToName[[string]$link.linkIndex]
      }
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
      management = Resolve-ManagementPath -Routes $routes -Links $links -Addresses $addresses -Endpoint $node
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
      management = [ordered]@{ interface = $null; physicalInterfaces = @(); addresses = @(); gateway = $null; family = $null; confidence = 'unknown'; reason = 'collection-failed' }
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
