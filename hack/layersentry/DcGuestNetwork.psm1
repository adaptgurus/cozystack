Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:VmId = '29ba176b-b81a-4f47-8f51-ecec869f247f'
$script:ManagementNic = 'Microsoft:29BA176B-B81A-4F47-8F51-ECEC869F247F\174A74C0-18CA-4B09-BC4C-8E9696DEAFE9'
$script:ManagementSwitch = 'bbfce11a-d2cf-428f-918b-cb4ccec961a5'
$script:GuestSwitch = '3bcf3eab-bc74-44c3-96b6-0064b636525a'
$script:GuestName = 'LayerSentry-DC-Guest-R0'
$script:GuestMac = '0229BA176B81'

function Get-DcGuestNetworkSnapshot {
    if ($env:COMPUTERNAME -ine 'TESTSER') { throw 'EXACT_HYPERV_HOST_REQUIRED' }
    $vm = @(Get-VM -Id ([guid]$script:VmId) -ErrorAction Stop)
    if ($vm.Count -ne 1 -or $vm[0].Name -cne 'sen' -or [string]$vm[0].State -cne 'Running' -or $vm[0].Generation -ne 2) { throw 'EXACT_RUNNING_GEN2_DC_REQUIRED' }
    $switch = @(Get-VMSwitch -Id ([guid]$script:GuestSwitch) -ErrorAction Stop)
    if ($switch.Count -ne 1 -or $switch[0].Name -cne 'LayerSentry-DR-Internal' -or [string]$switch[0].SwitchType -cne 'Internal') { throw 'EXACT_GUEST_SWITCH_REQUIRED' }
    $managementSwitch = Get-VMSwitch -Id ([guid]$script:ManagementSwitch) -ErrorAction Stop
    if ($managementSwitch.Name -cne 'Cozystack-NAT' -or [string]$managementSwitch.SwitchType -cne 'Internal') { throw 'MANAGEMENT_SWITCH_DRIFT' }
    $nics = @(Get-VMNetworkAdapter -VM $vm[0] -ErrorAction Stop)
    $management = @($nics | Where-Object { [string]$_.Id -ieq $script:ManagementNic })
    $guest = @($nics | Where-Object { $_.Name -ceq $script:GuestName })
    if ($management.Count -ne 1 -or $guest.Count -gt 1 -or $nics.Count -ne (1 + $guest.Count)) { throw 'DC_NIC_IDENTITY_OR_COUNT_CHANGED' }
    $mgmt = $management[0]
    if ([string]$mgmt.SwitchId -ine $script:ManagementSwitch -or $mgmt.MacAddress -ine '00155D00390A' -or $mgmt.Name -cne 'Network Adapter') { throw 'MANAGEMENT_NIC_DRIFT' }
    $managementVlan = @(Get-VMNetworkAdapterVlan -VMNetworkAdapter $mgmt -ErrorAction Stop)
    if ($managementVlan.Count -ne 1 -or [string]$managementVlan[0].OperationMode -cne 'Untagged') { throw 'MANAGEMENT_VLAN_DRIFT' }
    $spoof = [string]$mgmt.MacAddressSpoofing
    if ($spoof -cnotin @('On','Off')) { throw 'MANAGEMENT_SPOOF_STATE_UNKNOWN' }
    foreach ($nic in @(Get-VMNetworkAdapter -All -ErrorAction Stop)) {
        if ($nic.MacAddress -ieq $script:GuestMac -and ($guest.Count -ne 1 -or [string]$nic.Id -ine [string]$guest[0].Id)) { throw 'GUEST_MAC_COLLISION' }
        if ($nic.VMName -and [string]$nic.SwitchId -ieq $script:GuestSwitch -and ($guest.Count -ne 1 -or [string]$nic.Id -ine [string]$guest[0].Id)) { throw 'GUEST_SWITCH_ALREADY_USED' }
    }
    $address = @(Get-NetIPAddress -InterfaceAlias 'vEthernet (LayerSentry-DR-Internal)' -AddressFamily IPv4 -ErrorAction Stop)
    if ($address.Count -ne 1 -or $address[0].IPAddress -cne '10.10.20.1' -or $address[0].PrefixLength -ne 24) { throw 'GUEST_GATEWAY_DRIFT' }
    $guestProof = $null
    if ($guest.Count) {
        $g = $guest[0]
        if ($g.MacAddress -ine $script:GuestMac -or $g.DynamicMacAddressEnabled -ne $false -or
            ([string]$g.SwitchId -notin @('', '00000000-0000-0000-0000-000000000000', $script:GuestSwitch))) { throw 'GUEST_NIC_DRIFT' }
        $vlan = @(Get-VMNetworkAdapterVlan -VMNetworkAdapter $g -ErrorAction Stop)
        if ($vlan.Count -ne 1 -or [string]$vlan[0].OperationMode -cne 'Untagged') { throw 'GUEST_VLAN_DRIFT' }
        $guestProof = [ordered]@{ id=[string]$g.Id; mac=$script:GuestMac; switchId=[string]$g.SwitchId; spoof=[string]$g.MacAddressSpoofing }
    }
    return [ordered]@{ schema=1; vmId=$script:VmId; vmName='sen'; guest=$guestProof;
        managementNicId=[string]$mgmt.Id; managementSwitchId=[string]$mgmt.SwitchId; managementMac='00155D00390A';
        managementMacSpoofing=$spoof; managementNestedTraffic=$(if ($spoof -ceq 'On') {'ALLOWED_BY_HYPERV_SETTING'} else {'BLOCKED_MAC_SPOOF_OFF'});
        guestSwitchId=$script:GuestSwitch; gateway='10.10.20.1/24'; gatewayRouting='NOT_ESTABLISHED' }
}

function Save-DcGuestJournal([string]$Path, [object]$Journal) {
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Journal | ConvertTo-Json -Depth 10))
    $file = [IO.File]::Open($tmp, 'CreateNew', 'Write', 'None')
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, $null) } else { [IO.File]::Move($tmp, $Path) }
}

function Invoke-DcGuestNicPhase {
    param([ValidateSet('Prepare','Connect')][string]$Phase, [object]$Journal, [scriptblock]$Persist)
    $snapshot = Get-DcGuestNetworkSnapshot
    if ($snapshot.managementMacSpoofing -cne 'On') { throw 'MANAGEMENT_SPOOF_OFF_REQUIRES_SEPARATE_REVIEW' }
    if ($Journal.vmId -cne $script:VmId -or $Journal.guestMac -cne $script:GuestMac) { throw 'JOURNAL_BINDING_MISMATCH' }
    if ($snapshot.guest) {
        if (-not $Journal.prepareIntent) { throw 'UNJOURNALED_GUEST_NIC' }
        if ($Journal.guestId -and $Journal.guestId -ine $snapshot.guest.id) { throw 'GUEST_NIC_REPLACED' }
        $Journal.guestId = $snapshot.guest.id
        & $Persist
    } else {
        if ($Phase -ne 'Prepare' -or $Journal.prepareIntent) { throw 'UNCERTAIN_ADD_NO_REPLAY' }
        $Journal.prepareIntent = $true
        & $Persist
        # Deliberately disconnected until the guest has verified no-L3 profiles.
        Add-VMNetworkAdapter -VM (Get-VM -Id ([guid]$script:VmId)) -Name $script:GuestName -StaticMacAddress $script:GuestMac -ErrorAction Stop
        $snapshot = Get-DcGuestNetworkSnapshot
        if (-not $snapshot.guest) { throw 'ADDED_NIC_NOT_OBSERVED_NO_REPLAY' }
        $Journal.guestId = $snapshot.guest.id
        & $Persist
    }
    if ($Phase -eq 'Connect') {
        $g = @(Get-VMNetworkAdapter -VM (Get-VM -Id ([guid]$script:VmId)) | Where-Object { [string]$_.Id -ieq $Journal.guestId })
        if ($g.Count -ne 1) { throw 'OWNED_GUEST_NIC_MISSING' }
        if ($snapshot.guest.spoof -cne 'On') {
            if ($Journal.spoofIntent) { throw 'UNCERTAIN_SPOOF_NO_REPLAY' }
            $Journal.spoofIntent = $true
            & $Persist
            Set-VMNetworkAdapter -VMNetworkAdapter $g[0] -MacAddressSpoofing On -ErrorAction Stop
        }
        $snapshot = Get-DcGuestNetworkSnapshot
        if ($snapshot.guest.spoof -cne 'On') { throw 'GUEST_SPOOF_NOT_OBSERVED' }
        if ($snapshot.guest.switchId -ine $script:GuestSwitch) {
            if ($Journal.connectIntent) { throw 'UNCERTAIN_CONNECT_NO_REPLAY' }
            $Journal.connectIntent = $true
            & $Persist
            Connect-VMNetworkAdapter -VMNetworkAdapter $g[0] -VMSwitch (Get-VMSwitch -Id ([guid]$script:GuestSwitch)) -ErrorAction Stop
        }
    }
    $after = Get-DcGuestNetworkSnapshot
    if ($after.managementMacSpoofing -cne $snapshot.managementMacSpoofing) { throw 'MANAGEMENT_SPOOF_CHANGED' }
    if ($Phase -eq 'Connect' -and ($after.guest.switchId -ine $script:GuestSwitch -or $after.guest.spoof -cne 'On')) { throw 'GUEST_CONNECTION_NOT_VERIFIED' }
    return $after
}

Export-ModuleMember -Function Get-DcGuestNetworkSnapshot, Save-DcGuestJournal, Invoke-DcGuestNicPhase
