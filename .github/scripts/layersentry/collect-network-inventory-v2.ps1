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

function Get-FirstPropertyValue {
  param($Object, [string[]]$Names, $Default = $null)
  foreach ($name in $Names) {
    $value = Get-PropertyValue $Object $name
    if ($null -ne $value -and [string]$value -ne '') { return $value }
  }
  return $Default
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
  try { return @($result.Text | ConvertFrom-Json) }
  catch { throw "invalid JSON returned by talosctl get $Resource on $Node" }
}

function Read-SysfsText {
  param([string]$Node, [string]$Path)
  $result = Invoke-TalosText -Node $Node -Arguments @('read', $Path) -AllowFailure
  if (-not $result.Ok) { return [pscustomobject]@{ Ok = $false; Value = $null } }
  return [pscustomobject]@{ Ok = $true; Value = $result.Text.Trim() }
}

function Read-SysfsInteger {
  param([string]$Node, [string]$Path)
  $result = Read-SysfsText -Node $Node -Path $Path
  if (-not $result.Ok) { return [pscustomobject]@{ Ok = $false; Value = $null } }
  $value = [int64]0
  if ([int64]::TryParse([string]$result.Value, [ref]$value)) {
    return [pscustomobject]@{ Ok = $true; Value = $value }
  }
  return [pscustomobject]@{ Ok = $false; Value = $null }
}

function Convert-KeyValueText {
  param([string]$Text)
  $result = @{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^([^=]+)=(.*)$') { $result[$matches[1]] = $matches[2] }
  }
  return $result
}

function Get-DirectoryNames {
  param([string]$Node, [string]$Path, [string]$Pattern)
  $result = Invoke-TalosText -Node $Node -Arguments @('list', $Path, '-d', '1') -AllowFailure
  if (-not $result.Ok) { return [pscustomobject]@{ Ok = $false; Names = @() } }
  $names = @()
  foreach ($line in ($result.Text -split "`r?`n")) {
    $match = [regex]::Match($line, $Pattern)
    if ($match.Success) { $names += $match.Groups[1].Value }
  }
  return [pscustomobject]@{ Ok = $true; Names = @($names | Sort-Object -Unique) }
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

function Get-RdmaEvidence {
  param([string]$Node, [string]$Interface)
  $probe = Get-DirectoryNames -Node $Node -Path "/sys/class/net/$Interface/device/infiniband" -Pattern 'infiniband[\\/]+([^\\/\s]+)'
  if (-not $probe.Ok) {
    return [ordered]@{ supported = $null; devices = @(); source = 'sysfs:unavailable'; reason = 'infiniband-sysfs-not-readable' }
  }
  return [ordered]@{
    supported = ($probe.Names.Count -gt 0)
    devices = $probe.Names
    source = $(if ($probe.Names.Count -gt 0) { 'sysfs:infiniband' } else { 'sysfs:empty' })
    reason = $(if ($probe.Names.Count -gt 0) { 'rdma-device-observed' } else { 'no-rdma-device-observed' })
  }
}

function Get-QueueEvidence {
  param([string]$Node, [string]$Interface)
  $result = Invoke-TalosText -Node $Node -Arguments @('list', "/sys/class/net/$Interface/queues", '-d', '1') -AllowFailure
  if (-not $result.Ok) { return [ordered]@{ rx = $null; tx = $null; source = 'sysfs:unavailable' } }
  $rx = [System.Collections.Generic.HashSet[string]]::new()
  $tx = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($line in ($result.Text -split "`r?`n")) {
    $m = [regex]::Match($line, 'queues[\\/]+(rx|tx)-(\d+)')
    if (-not $m.Success) { continue }
    if ($m.Groups[1].Value -eq 'rx') { [void]$rx.Add($m.Groups[2].Value) }
    else { [void]$tx.Add($m.Groups[2].Value) }
  }
  return [ordered]@{ rx = $rx.Count; tx = $tx.Count; source = 'sysfs:net-queues' }
}

function Normalize-Link {
  param([string]$Node, $Resource)
  $metadata = Get-PropertyValue $Resource 'metadata'
  $spec = Get-PropertyValue $Resource 'spec'
  $name = [string](Get-FirstPropertyValue $metadata @('id', 'name') '')
  $kind = [string](Get-PropertyValue $spec 'kind' '')
  $driver = [string](Get-PropertyValue $spec 'driver' '')

  $deviceUevent = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/device/uevent"
  $deviceFacts = $(if ($deviceUevent.Ok) { Convert-KeyValueText $deviceUevent.Value } else { @{} })
  if (-not $driver -and $deviceFacts.ContainsKey('DRIVER')) { $driver = [string]$deviceFacts['DRIVER'] }
  $physicalSource = $(if ($deviceUevent.Ok) { 'sysfs:device-uevent' } elseif (-not [string]::IsNullOrWhiteSpace($driver) -and [string]::IsNullOrWhiteSpace($kind)) { 'talos:linkstatus-driver' } else { 'unproven' })
  $isPhysical = $name -ne 'lo' -and $physicalSource -ne 'unproven'

  $speed = Get-FirstPropertyValue $spec @('speedMbit', 'speedMegabits')
  if ($null -ne $speed) {
    $speedNumber = [int64]$speed
    $speed = $(if ($speedNumber -gt 0 -and $speedNumber -lt 4294967295) { $speedNumber } else { $null })
  }
  if ($null -eq $speed -and $isPhysical) {
    $speedProbe = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/speed"
    if ($speedProbe.Ok -and $speedProbe.Value -gt 0 -and $speedProbe.Value -lt 4294967295) { $speed = $speedProbe.Value }
  }

  $linkUp = Convert-LinkState (Get-FirstPropertyValue $spec @('linkState', 'carrierState'))
  if ($null -eq $linkUp -and $name) {
    $carrier = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/carrier"
    if ($carrier.Ok) { $linkUp = ($carrier.Value -eq 1) }
  }

  $operationalState = [string](Get-FirstPropertyValue $spec @('operationalState', 'operState') '')
  if (-not $operationalState) {
    $probe = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/operstate"
    if ($probe.Ok) { $operationalState = [string]$probe.Value }
  }
  if (-not $operationalState) { $operationalState = 'unknown' }

  $duplex = [string](Get-PropertyValue $spec 'duplex' '')
  if (-not $duplex -and $isPhysical) {
    $probe = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/duplex"
    if ($probe.Ok) { $duplex = [string]$probe.Value }
  }

  $sriov = [ordered]@{ supported = $null; totalVfs = $null; configuredVfs = $null; source = 'not-probed'; reason = 'not-physical' }
  $rdma = [ordered]@{ supported = $null; devices = @(); source = 'not-probed'; reason = 'not-physical' }
  $queues = [ordered]@{ rx = $null; tx = $null; source = 'not-probed' }
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
      $sriov.source = 'sysfs:unavailable'
      $sriov.reason = 'sriov-sysfs-not-readable'
    }
    $rdma = Get-RdmaEvidence -Node $Node -Interface $name
    $queues = Get-QueueEvidence -Node $Node -Interface $name
  }

  $numa = Read-SysfsInteger -Node $Node -Path "/sys/class/net/$name/device/numa_node"
  $vendorId = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/device/vendor"
  $deviceId = Read-SysfsText -Node $Node -Path "/sys/class/net/$name/device/device"
  $vlan = Get-PropertyValue $spec 'vlan'

  return [ordered]@{
    name = $name
    index = Get-PropertyValue $spec 'index'
    type = [string](Get-PropertyValue $spec 'type' 'unknown')
    kind = $(if ($kind) { $kind } elseif ($isPhysical) { 'physical' } else { 'unknown' })
    physical = $isPhysical
    physicalEvidence = $physicalSource
    linkIndex = Get-PropertyValue $spec 'linkIndex'
    parent = $null
    masterIndex = Get-PropertyValue $spec 'masterIndex'
    master = $null
    members = @()
    bondMode = $null
    bridgeStpState = $null
    linkUp = $linkUp
    operationalState = $operationalState
    mac = [string](Get-FirstPropertyValue $spec @('hardwareAddr', 'hardwareAddress') '')
    permanentMac = [string](Get-FirstPropertyValue $spec @('permanentAddr', 'permanentHardwareAddr') '')
    mtu = Get-PropertyValue $spec 'mtu'
    speedMbps = $speed
    driver = $driver
    driverVersion = [string](Get-PropertyValue $spec 'driverVersion' '')
    firmwareVersion = [string](Get-PropertyValue $spec 'firmwareVersion' '')
    pciId = [string](Get-FirstPropertyValue $spec @('pciid', 'pciId') $(if ($deviceFacts.ContainsKey('PCI_SLOT_NAME')) { $deviceFacts['PCI_SLOT_NAME'] } else { '' }))
    vendor = [string](Get-PropertyValue $spec 'vendor' '')
    vendorId = $(if ($vendorId.Ok) { [string]$vendorId.Value } else { $null })
    deviceId = $(if ($deviceId.Ok) { [string]$deviceId.Value } else { $null })
    numaNode = $(if ($numa.Ok -and $numa.Value -ge 0) { $numa.Value } else { $null })
    rxQueues = $queues.rx
    txQueues = $queues.tx
    port = [string](Get-PropertyValue $spec 'port' '')
    duplex = $duplex
    vlanId = Get-FirstPropertyValue $vlan @('vid', 'id')
    sriov = $sriov
    rdma = $rdma
  }
}

function Normalize-Address {
  param($Resource)
  $spec = Get-PropertyValue $Resource 'spec'
  return [ordered]@{
    address = [string](Get-FirstPropertyValue $spec @('address', 'cidr') '')
    local = [string](Get-PropertyValue $spec 'local' '')
    linkName = [string](Get-FirstPropertyValue $spec @('linkName', 'interface') '')
    linkIndex = Get-PropertyValue $spec 'linkIndex'
    family = [string](Get-PropertyValue $spec 'family' '')
    scope = [string](Get-PropertyValue $spec 'scope' '')
  }
}

function Normalize-Route {
  param($Resource)
  $spec = Get-PropertyValue $Resource 'spec'
  $metric = Get-FirstPropertyValue $spec @('metric', 'priority') 0
  return [ordered]@{
    destination = [string](Get-FirstPropertyValue $spec @('dst', 'destination') '')
    source = [string](Get-FirstPropertyValue $spec @('src', 'source') '')
    gateway = [string](Get-PropertyValue $spec 'gateway' '')
    outLinkName = [string](Get-FirstPropertyValue $spec @('outLinkName', 'interface') '')
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
    if (-not $Name -or -not $visited.Add($Name) -or -not $byName.ContainsKey($Name)) { return }
    $current = $byName[$Name]
    if ($current.physical) { [void]$result.Add($current.name); return }
    if ($current.parent) { Visit-Link -Name $current.parent }
    foreach ($child in @($Links | Where-Object { $_.master -eq $Name })) { Visit-Link -Name $child.name }
  }
  Visit-Link -Name $Interface
  return @($result | Sort-Object)
}

function Resolve-ManagementPath {
  param([object[]]$Routes, [object[]]$Links, [object[]]$Addresses, [string]$Endpoint)
  $defaults = @($Routes | Where-Object { $_.destination -in @('', 'default', '0.0.0.0/0', '::/0') -and $_.outLinkName })
  if ($defaults.Count -eq 0) {
    return [ordered]@{ interface = $null; physicalInterfaces = @(); addresses = @(); gateway = $null; family = $null; confidence = 'unknown'; reason = 'no-default-route-observed' }
  }
  $endpointFamily = Get-EndpointFamily -Endpoint $Endpoint
  if ($endpointFamily -ne 'unknown') {
    $sameFamily = @($defaults | Where-Object { (Get-RouteFamily $_) -eq $endpointFamily })
    if ($sameFamily.Count -gt 0) { $defaults = $sameFamily }
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
  return [ordered]@{
    interface = $interface
    physicalInterfaces = $physicalInterfaces
    addresses = $managementAddresses
    gateway = $(if ($gateways.Count -eq 1) { $gateways[0] } else { $null })
    family = $family
    confidence = $(if ($physicalInterfaces.Count -gt 0) { 'high' } else { 'medium' })
    reason = $(if ($endpointFamily -ne 'unknown') { "lowest-priority-$endpointFamily-default-route" } else { 'lowest-priority-default-route' })
  }
}

$inventoryNodes = @()
foreach ($nodeValue in $Nodes) {
  $node = $nodeValue.Trim()
  if (-not $node) { continue }
  Write-Host "Collecting custom Talos network inventory from $node"
  try {
    $links = @(Invoke-TalosJson -Node $node -Resource 'links' | ForEach-Object { Normalize-Link -Node $node -Resource $_ })
    $addresses = @(Invoke-TalosJson -Node $node -Resource 'addresses' | ForEach-Object { Normalize-Address $_ })
    $routes = @(Invoke-TalosJson -Node $node -Resource 'routes' | ForEach-Object { Normalize-Route $_ })
    $resolversRaw = @(Invoke-TalosJson -Node $node -Resource 'resolvers')
    $nodeNameRaw = @(Invoke-TalosJson -Node $node -Resource 'nodename')

    $indexToName = @{}
    foreach ($link in $links) { if ($null -ne $link.index) { $indexToName[[string]$link.index] = $link.name } }
    foreach ($link in $links) {
      if ($null -ne $link.linkIndex -and $indexToName.ContainsKey([string]$link.linkIndex)) { $link.parent = $indexToName[[string]$link.linkIndex] }
      if ($null -ne $link.masterIndex -and $indexToName.ContainsKey([string]$link.masterIndex)) { $link.master = $indexToName[[string]$link.masterIndex] }
    }
    foreach ($link in $links) {
      $link.members = @($links | Where-Object { $_.master -eq $link.name } | ForEach-Object { $_.name } | Sort-Object -Unique)
      $bondMode = Read-SysfsText -Node $node -Path "/sys/class/net/$($link.name)/bonding/mode"
      if ($bondMode.Ok) { $link.bondMode = [string]$bondMode.Value; if ($link.kind -eq 'unknown') { $link.kind = 'bond' } }
      $bridgeStp = Read-SysfsText -Node $node -Path "/sys/class/net/$($link.name)/bridge/stp_state"
      if ($bridgeStp.Ok) { $link.bridgeStpState = [string]$bridgeStp.Value; if ($link.kind -eq 'unknown') { $link.kind = 'bridge' } }
    }

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
      $candidate = [string](Get-FirstPropertyValue $spec @('nodename', 'hostname', 'name') '')
      if ($candidate) { $name = $candidate }
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
      links = @(); addresses = @(); routes = @(); resolvers = @()
    }
  }
}

$readyCount = @($inventoryNodes | Where-Object { $_.state -eq 'ready' }).Count
$report = [ordered]@{
  schemaVersion = 'network.layersentry.io/v1alpha1'
  collectorVersion = 2
  generatedAt = [DateTime]::UtcNow.ToString('o')
  sourceCommit = $SourceCommit
  sourceRun = $SourceRun
  source = 'talos-resource-api+custom-talos-sysfs-v2'
  nodeCount = $inventoryNodes.Count
  readyNodeCount = $readyCount
  partial = ($readyCount -ne $inventoryNodes.Count)
  nodes = $inventoryNodes
}

$json = $report | ConvertTo-Json -Depth 24
if ($json -match 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|client-key-data|talosconfig') { throw 'refusing to publish inventory containing credential material' }
$parent = Split-Path -Parent $Output
if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText($Output, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "NETWORK_INVENTORY_V2 nodes=$($inventoryNodes.Count) ready=$readyCount partial=$($report.partial) output=$Output"
