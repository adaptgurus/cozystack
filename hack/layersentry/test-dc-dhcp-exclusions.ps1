$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DcDhcpExclusions.psm1') -Force
& (Get-Module DcDhcpExclusions) {
    $script:excluded=@();$script:calls=@();$script:saves=0;$script:failAdd=$false;$script:effectBeforeFailure=$false
    $script:leases=@([ordered]@{address='10.10.10.14';clientId='00155d003909';state='Active'})
    function Get-DcDhcpExclusionPlan {
        [ordered]@{schema=1;host='TESTSER';scope='10.10.10.0';exclusions=@($script:excluded|Sort-Object);leases=$script:leases;
            reservations=@([ordered]@{address='10.10.10.11';clientId='reservation';type='Both'});attachedVmIds=@('sen-id','dr-id');status='PLAN_REVIEW_REQUIRED'}
    }
    function Add-DhcpServerv4ExclusionRange {
        param($ComputerName,$ScopeId,$StartRange,$EndRange,$ErrorAction)
        if($ComputerName -cne 'TESTSER' -or $ScopeId -cne '10.10.10.0' -or $StartRange -cne $EndRange -or $StartRange -cnotin @('10.10.10.14','10.10.10.20') -or $script:saves -lt 1){throw 'OUT_OF_SCOPE_OR_UNJOURNALED_ADD'}
        $script:calls+=@($StartRange)
        if(-not $script:failAdd -or $script:effectBeforeFailure){$script:excluded+=@($StartRange)}
        if($script:failAdd){throw 'FIXTURE_TRANSPORT_FAILURE'}
    }
    function New-TestDhcpJournal {[pscustomobject]@{schema=1;host='TESTSER';scope='10.10.10.0';baseline=(Get-DcDhcpExclusionPlan);intent14=$false;intent20=$false}}
    $persist={$script:saves++}
    $journal=New-TestDhcpJournal
    $before=$script:leases|ConvertTo-Json -Compress
    $result=Invoke-DcDhcpExclusions $journal $persist
    if(($script:calls -join ',') -cne '10.10.10.14,10.10.10.20' -or $result.status -cne 'EXCLUSIONS_RECONCILED_LEASES_PRESERVED' -or ($script:leases|ConvertTo-Json -Compress) -cne $before){throw 'EXCLUSION_OR_LEASE_RESULT_WRONG'}
    Invoke-DcDhcpExclusions $journal $persist|Out-Null
    if($script:calls.Count -ne 2){throw 'RECONCILED_ADD_REPLAYED'}
    foreach($effect in @($false,$true)){
        $script:excluded=@();$script:calls=@();$script:failAdd=$true;$script:effectBeforeFailure=$effect;$journal=New-TestDhcpJournal
        try{Invoke-DcDhcpExclusions $journal $persist|Out-Null}catch{if($_.Exception.Message -cne 'FIXTURE_TRANSPORT_FAILURE'){throw}}
        $script:failAdd=$false
        if($effect){
            Invoke-DcDhcpExclusions $journal $persist|Out-Null
            if(($script:calls -join ',') -cne '10.10.10.14,10.10.10.20'){throw 'UNCERTAIN_EFFECT_REPLAYED'}
        }else{
            $blocked=$false
            try{Invoke-DcDhcpExclusions $journal $persist|Out-Null}catch{if($_.Exception.Message -ceq 'UNCERTAIN_DHCP_EXCLUSION_NO_REPLAY'){$blocked=$true}else{throw}}
            if(-not $blocked -or $script:calls.Count -ne 1){throw 'UNCERTAIN_NO_EFFECT_REPLAYED'}
        }
    }
    'DC_DHCP_EXCLUSION_TESTS_PASS'
}
