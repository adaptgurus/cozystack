Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-DcDhcpExclusionPlan {
    if($env:COMPUTERNAME -ine 'TESTSER'){throw 'EXACT_HYPERV_HOST_REQUIRED'}
    $switch=Get-VMSwitch -Id ([guid]'bbfce11a-d2cf-428f-918b-cb4ccec961a5') -ErrorAction Stop
    if($switch.Name -cne 'Cozystack-NAT' -or [string]$switch.SwitchType -cne 'Internal'){throw 'NAT_SWITCH_CHANGED'}
    $expected=@{'29ba176b-b81a-4f47-8f51-ecec869f247f'=@('sen','00155D00390A');'61fef4dc-44dc-43ad-a2a0-f923912a01d7'=@('layersentry-dr-rocky9','00155D00390B')}
    $attached=@()
    foreach($vm in @(Get-VM -ErrorAction Stop)){
        foreach($nic in @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop|Where-Object{[string]$_.SwitchId -ieq [string]$switch.Id})){
            $id=[string]$vm.Id
            if(-not $expected.ContainsKey($id) -or $vm.Name -cne $expected[$id][0] -or $nic.MacAddress -ine $expected[$id][1]){throw 'NAT_VM_IDENTITY_CHANGED'}
            $attached+=$id
        }
    }
    if($attached.Count -ne 2 -or @($attached|Sort-Object -Unique).Count -ne 2){throw 'NAT_VM_COUNT_CHANGED'}
    $hostAddresses=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Where-Object IPAddress -like '10.10.10.*')
    if($hostAddresses.Count -ne 1 -or $hostAddresses[0].IPAddress -cne '10.10.10.1' -or $hostAddresses[0].PrefixLength -ne 24){throw 'NAT_HOST_ADDRESS_CHANGED'}
    $scope=@(Get-DhcpServerv4Scope -ComputerName TESTSER -ScopeId 10.10.10.0 -ErrorAction Stop)
    if($scope.Count -ne 1 -or [string]$scope[0].ScopeId -cne '10.10.10.0' -or [string]$scope[0].StartRange -cne '10.10.10.10' -or [string]$scope[0].EndRange -cne '10.10.10.250' -or [string]$scope[0].SubnetMask -cne '255.255.255.0' -or [string]$scope[0].State -cne 'Active'){throw 'DHCP_SCOPE_CHANGED'}
    $exclusions=@()
    foreach($row in @(Get-DhcpServerv4ExclusionRange -ComputerName TESTSER -ScopeId 10.10.10.0 -ErrorAction Stop)){
        $start=[string]$row.StartRange;$end=[string]$row.EndRange
        if($start -cne $end -or $start -cnotin @('10.10.10.14','10.10.10.20')){throw 'UNRECONCILED_DHCP_EXCLUSION'}
        $exclusions+=$start
    }
    if(@($exclusions|Sort-Object -Unique).Count -ne $exclusions.Count){throw 'DUPLICATE_EXCLUSION'}
    $reservations=@(Get-DhcpServerv4Reservation -ComputerName TESTSER -ScopeId 10.10.10.0 -ErrorAction Stop|ForEach-Object{[ordered]@{address=[string]$_.IPAddress;clientId=[string]$_.ClientId;type=[string]$_.Type}}|Sort-Object address)
    if(@($reservations|Where-Object{$_.address -in @('10.10.10.14','10.10.10.20')}).Count){throw 'RESERVATION_OVERRIDES_PROPOSED_EXCLUSION'}
    $leases=@(Get-DhcpServerv4Lease -ComputerName TESTSER -ScopeId 10.10.10.0 -AllLeases -ErrorAction Stop|ForEach-Object{[ordered]@{address=[string]$_.IPAddress;clientId=[string]$_.ClientId;state=[string]$_.AddressState}}|Sort-Object address)
    return [ordered]@{schema=1;host='TESTSER';scope='10.10.10.0';start='10.10.10.10';end='10.10.10.250';status='PLAN_REVIEW_REQUIRED';
        exclusions=@($exclusions|Sort-Object);reservations=$reservations;leases=$leases;attachedVmIds=@($attached|Sort-Object);
        operations=@([ordered]@{command='Add-DhcpServerv4ExclusionRange';start='10.10.10.14';end='10.10.10.14'},[ordered]@{command='Add-DhcpServerv4ExclusionRange';start='10.10.10.20';end='10.10.10.20'});
        leaseRevocationPerformed=$false;scopeChangePerformed=$false;podRangeChangePerformed=$false}
}

function Get-DcDhcpStableBaselineField {
    param([object[]]$Rows,[ValidateSet('reservations','leases','attachedVmIds')][string]$Field)
    $canonical=@(foreach($row in $Rows){
        if($Field -ceq 'attachedVmIds'){[string]$row}else{
            $kind=if($Field -ceq 'leases'){$row.state}else{$row.type}
            # JSON strings preserve field boundaries; sorting ignores native enumeration order only.
            @([string]$row.address,[string]$row.clientId,[string]$kind)|ConvertTo-Json -Compress
        }
    })
    return (@($canonical|Sort-Object) -join "`n")
}

function Invoke-DcDhcpExclusions {
    param([object]$Journal,[scriptblock]$Persist)
    if($Journal.schema -ne 1 -or $Journal.host -cne 'TESTSER' -or $Journal.scope -cne '10.10.10.0'){throw 'DHCP_JOURNAL_BINDING_CHANGED'}
    $before=Get-DcDhcpExclusionPlan
    foreach($field in @('reservations','leases','attachedVmIds')){
        if((Get-DcDhcpStableBaselineField $before[$field] $field) -cne (Get-DcDhcpStableBaselineField $Journal.baseline.$field $field)){throw 'DHCP_BASELINE_CHANGED'}
    }
    foreach($item in @(@('10.10.10.14','intent14'),@('10.10.10.20','intent20'))){
        $address=$item[0];$intent=$item[1]
        $current=Get-DcDhcpExclusionPlan
        foreach($field in @('reservations','leases','attachedVmIds')){
            if((Get-DcDhcpStableBaselineField $current[$field] $field) -cne (Get-DcDhcpStableBaselineField $Journal.baseline.$field $field)){throw 'DHCP_BASELINE_CHANGED_BEFORE_EXCLUSION'}
        }
        if($address -in $current.exclusions){
            if(-not $Journal.$intent){throw 'UNJOURNALED_EXCLUSION'}
            continue
        }
        if($Journal.$intent){throw 'UNCERTAIN_DHCP_EXCLUSION_NO_REPLAY'}
        $Journal.$intent=$true
        & $Persist
        # Never changes scope endpoints or deletes reservations/leases.
        Add-DhcpServerv4ExclusionRange -ComputerName TESTSER -ScopeId 10.10.10.0 -StartRange $address -EndRange $address -ErrorAction Stop
        $after=Get-DcDhcpExclusionPlan
        if($address -notin $after.exclusions){throw 'EXCLUSION_NOT_OBSERVED_NO_REPLAY'}
        foreach($field in @('reservations','leases','attachedVmIds')){
            if((Get-DcDhcpStableBaselineField $after[$field] $field) -cne (Get-DcDhcpStableBaselineField $Journal.baseline.$field $field)){throw 'DHCP_BASELINE_CHANGED_AFTER_EXCLUSION'}
        }
    }
    $after=Get-DcDhcpExclusionPlan
    if($after.exclusions.Count -ne 2){throw 'EXCLUSIONS_INCOMPLETE'}
    $after.status='EXCLUSIONS_RECONCILED_LEASES_PRESERVED'
    return $after
}

Export-ModuleMember -Function Get-DcDhcpExclusionPlan,Invoke-DcDhcpExclusions
