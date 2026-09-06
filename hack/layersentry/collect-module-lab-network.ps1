$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:COMPUTERNAME -cne 'TESTSER') { throw 'Exact LayerSentry lab host required.' }
Import-Module Hyper-V -ErrorAction Stop
$expected = @{
    'Cozystack-NAT' = 'bbfce11a-d2cf-428f-918b-cb4ccec961a5'
    'LayerSentry-DR-Internal' = '3bcf3eab-bc74-44c3-96b6-0064b636525a'
}
foreach ($name in $expected.Keys) {
    $switch = Get-VMSwitch -Name $name -ErrorAction Stop
    if ($switch.Id.ToString() -cne $expected[$name] -or $switch.SwitchType.ToString() -cne 'Internal') { throw 'Lab switch identity drift.' }
}
$out = Join-Path $env:RUNNER_TEMP "layersentry-module-lab-network-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$report = [ordered]@{
    schema = 1; status = 'PARTIAL'; mutationPerformed = $false
    host = $env:COMPUTERNAME; runnerCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID
    osVersion = [Environment]::OSVersion.Version.ToString()
    switches = @(Get-VMSwitch | Select-Object Name, Id, SwitchType)
    addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, InterfaceIndex, IPAddress, PrefixLength, AddressState)
    routes = @(Get-NetRoute -AddressFamily IPv4 | Select-Object InterfaceAlias, InterfaceIndex, DestinationPrefix, NextHop, RouteMetric, State)
    interfaces = @(Get-NetIPInterface -AddressFamily IPv4 | Select-Object InterfaceAlias, InterfaceIndex, Forwarding, ConnectionState, Dhcp, InterfaceMetric)
    nats = @(Get-NetNat -ErrorAction Stop | Select-Object Name, InternalIPInterfaceAddressPrefix, ExternalIPInterfaceAddressPrefix, Active, Store)
    mappings = @(Get-NetNatStaticMapping -ErrorAction Stop | Select-Object NatName, Protocol, ExternalIPAddress, ExternalPort, InternalIPAddress, InternalPort)
    natSetParameters = @((Get-Command Set-NetNat -ErrorAction Stop).Parameters.Keys | Sort-Object)
    vmNics = @(Get-VMNetworkAdapter -All | Select-Object VMId, VMName, Name, Id, SwitchId, MacAddress, MacAddressSpoofing)
    hns = @{ status = 'UNKNOWN'; reason = 'CMDLET_UNAVAILABLE' }
    guestRoutingVerified = $false; productionCertified = $false
}
if (Get-Command Get-HnsNetwork -ErrorAction SilentlyContinue) {
    try {
        $networks = @(Get-HnsNetwork -ErrorAction Stop)
        $report.hns = @{ status = 'OBSERVED'; networks = @($networks | ForEach-Object {
            [ordered]@{ id = $_.Id; name = $_.Name; type = $_.Type; subnets = @($_.Subnets | Select-Object AddressPrefix, GatewayAddress) }
        }) }
    } catch { $report.hns = @{ status = 'UNKNOWN'; reason = 'QUERY_FAILED' } }
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $out 'network.json') -Encoding UTF8
