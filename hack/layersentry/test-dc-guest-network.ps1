$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$env:COMPUTERNAME='TESTSER'
Import-Module (Join-Path $PSScriptRoot 'DcGuestNetwork.psm1') -Force
$module=Get-Module DcGuestNetwork
& $module {
    $script:testGuest=$null
    $script:testSpoof='On'
    $script:saves=0
    $script:mutations=0
    $script:rejectAdd=$false
    function Get-VM { param($Id,$ErrorAction) [pscustomobject]@{Id=$Id;Name='sen';State='Running';Generation=2} }
    function Get-VMSwitch { param($Id,$ErrorAction) [pscustomobject]@{Id=$Id;Name=$(if([string]$Id -ieq $script:GuestSwitch){'LayerSentry-DR-Internal'}else{'Cozystack-NAT'});SwitchType='Internal'} }
    function Get-VMNetworkAdapter {
        param($VM,[switch]$All,$ErrorAction)
        [pscustomobject]@{Id=$script:ManagementNic;Name='Network Adapter';VMName='sen';MacAddress='00155D00390A';SwitchId=$script:ManagementSwitch;MacAddressSpoofing=$script:testSpoof}
        if($script:testGuest){$script:testGuest}
    }
    function Get-VMNetworkAdapterVlan { param($VMNetworkAdapter,$ErrorAction) [pscustomobject]@{OperationMode='Untagged'} }
    function Get-NetIPAddress { param($InterfaceAlias,$AddressFamily,$ErrorAction) [pscustomobject]@{IPAddress='10.10.20.1';PrefixLength=24} }
    function Add-VMNetworkAdapter {
        param($VM,$Name,$StaticMacAddress,$ErrorAction)
        if($script:saves -lt 1){throw 'INTENT_NOT_DURABLE'}
        $script:mutations++
        if($script:rejectAdd){throw 'FIXTURE_ADD_TIMEOUT'}
        $script:testGuest=[pscustomobject]@{Id='Microsoft:29BA176B-B81A-4F47-8F51-ECEC869F247F\D59248DC-25A2-5590-8332-2F9DF8F5621A';Name=$Name;VMName='sen';MacAddress=$StaticMacAddress;DynamicMacAddressEnabled=$false;SwitchId='';MacAddressSpoofing='Off'}
    }
    function Set-VMNetworkAdapter {
        param($VMNetworkAdapter,$MacAddressSpoofing,$ErrorAction)
        if($VMNetworkAdapter.Id -ieq $script:ManagementNic){throw 'MANAGEMENT_MUTATION'}
        $script:mutations++;$script:testGuest.MacAddressSpoofing=$MacAddressSpoofing
    }
    function Connect-VMNetworkAdapter {
        param($VMNetworkAdapter,$VMSwitch,$ErrorAction)
        if($VMNetworkAdapter.Id -ieq $script:ManagementNic){throw 'MANAGEMENT_MUTATION'}
        $script:mutations++;$script:testGuest.SwitchId=[string]$VMSwitch.Id
    }
    function New-TestJournal { [pscustomobject]@{vmId=$script:VmId;guestMac=$script:GuestMac;guestId='';prepareIntent=$false;spoofIntent=$false;connectIntent=$false} }
    $persist={$script:saves++}
    $j=New-TestJournal
    $snapshot=Get-DcGuestNetworkSnapshot
    if($snapshot.guest -or $snapshot.managementMacSpoofing -cne 'On' -or $script:mutations){throw 'PLAN_MUTATED'}
    $script:testSpoof='Off'
    $blocked=$false
    try{Invoke-DcGuestNicPhase Prepare $j $persist|Out-Null}catch{if($_.Exception.Message -ceq 'MANAGEMENT_SPOOF_OFF_REQUIRES_SEPARATE_REVIEW'){$blocked=$true}else{throw}}
    if(-not $blocked -or $script:mutations){throw 'DISABLED_MANAGEMENT_SPOOF_WAS_IGNORED'}
    $script:testSpoof='On'
    $s=Invoke-DcGuestNicPhase Prepare $j $persist
    if($s.guest.switchId -or -not $j.prepareIntent -or -not $j.guestId){throw 'PREPARE_NOT_DISCONNECTED_OR_UNJOURNALED'}
    $s=Invoke-DcGuestNicPhase Connect $j $persist
    if($s.guest.switchId -ine $script:GuestSwitch -or $s.guest.spoof -cne 'On' -or $s.managementMacSpoofing -cne 'On'){throw 'CONNECT_NOT_RECONCILED'}
    $count=$script:mutations
    Invoke-DcGuestNicPhase Prepare $j $persist|Out-Null
    Invoke-DcGuestNicPhase Connect $j $persist|Out-Null
    if($script:mutations -ne $count){throw 'RECONCILED_ACTION_REPLAYED'}
    $script:testGuest=$null;$script:rejectAdd=$true;$j=New-TestJournal
    try{Invoke-DcGuestNicPhase Prepare $j $persist|Out-Null}catch{if($_.Exception.Message -cne 'FIXTURE_ADD_TIMEOUT'){throw}}
    $count=$script:mutations
    $blocked=$false
    try{Invoke-DcGuestNicPhase Prepare $j $persist|Out-Null}catch{if($_.Exception.Message -ceq 'UNCERTAIN_ADD_NO_REPLAY'){$blocked=$true}else{throw}}
    if(-not $blocked -or $count -ne $script:mutations){throw 'UNCERTAIN_ADD_REPLAYED'}
    'DC_GUEST_NETWORK_TESTS_PASS'
}
