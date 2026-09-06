param([ValidateSet('Plan','Apply')][string]$Mode='Plan', [string]$PlanReceiptPath='', [string]$PlanReceiptSha256='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DcGuestNetwork.psm1') -Force
Import-Module Hyper-V -ErrorAction Stop
$out=Join-Path $env:RUNNER_TEMP "layersentry-dc-guest-plan-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop | Out-Null
$report=[ordered]@{schema=1;target='10.10.10.14';mode=$Mode;sourceCommit=$env:GITHUB_SHA;runId=$env:GITHUB_RUN_ID;status='PENDING';networkMutationAttempted=$false}
$lock=$null
$apiKey=$env:CLOUDSTACK_API_KEY
$apiSecret=$env:CLOUDSTACK_SECRET_KEY
function Invoke-GuestPhase([string]$Phase) {
    $env:CLOUDSTACK_API_KEY=$apiKey
    $env:CLOUDSTACK_SECRET_KEY=$apiSecret
    & (Join-Path $PSScriptRoot 'invoke-dc-guest-network-ssh.ps1') -Mode $Phase
}
try {
    $before=Get-DcGuestNetworkSnapshot
    $report.hyperv=$before
    if ($Mode -eq 'Plan') {
        $report.guest=Invoke-GuestPhase 'Plan'
        $after=Get-DcGuestNetworkSnapshot
        if (($before | ConvertTo-Json -Depth 8 -Compress) -cne ($after | ConvertTo-Json -Depth 8 -Compress)) { throw 'HYPERV_CHANGED_DURING_PLAN' }
        $report.status=if($before.managementMacSpoofing -ceq 'On'){'PLAN_REVIEW_REQUIRED'}else{'PLAN_BLOCKED_MANAGEMENT_SPOOF_OFF'}
    } else {
        if ($PlanReceiptSha256 -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $PlanReceiptPath -PathType Leaf)) { throw 'REVIEWED_PLAN_RECEIPT_REQUIRED' }
        if ((Get-FileHash -LiteralPath $PlanReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $PlanReceiptSha256) { throw 'PLAN_RECEIPT_HASH_MISMATCH' }
        $plan=Get-Content -LiteralPath $PlanReceiptPath -Raw | ConvertFrom-Json
        if ($plan.schema -ne 1 -or $plan.target -cne '10.10.10.14' -or $plan.mode -cne 'Plan' -or $plan.status -cne 'PLAN_REVIEW_REQUIRED' -or $plan.networkMutationAttempted -ne $false -or $plan.hyperv.managementMacSpoofing -cne 'On' -or $plan.hyperv.guest -or $plan.guest.nicStatus -cne 'NOT_ADDED') { throw 'PLAN_RECEIPT_SCOPE_INVALID' }
        foreach($field in @('vmId','managementNicId','managementSwitchId','managementMac','managementMacSpoofing','guestSwitchId','gateway')) {
            if ([string]$before[$field] -ine [string]$plan.hyperv.$field) { throw 'CURRENT_HYPERV_DIFFERS_FROM_REVIEWED_PLAN' }
        }
        $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'ADMINISTRATOR_REQUIRED'}
        $root=Join-Path $env:ProgramData 'LayerSentry\dc-guest-network-r0'
        $ancestor=[IO.DirectoryInfo]$root
        while($ancestor){if($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'JOURNAL_REPARSE_POINT'};$ancestor=$ancestor.Parent}
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
        Set-Acl -LiteralPath $root -AclObject $acl
        foreach($entry in @(Get-ChildItem -LiteralPath $root -Force)){if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'JOURNAL_ENTRY_REPARSE_POINT'}}
        $lock=[IO.File]::Open((Join-Path $root 'host.lock'),'OpenOrCreate','ReadWrite','None')
        $journalPath=Join-Path $root 'journal.json'
        if(Test-Path -LiteralPath $journalPath){
            if((Get-Item -LiteralPath $journalPath).Length -gt 16384){throw 'JOURNAL_SIZE_LIMIT'}
            $journal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json
            if($journal.planSha256 -cne $PlanReceiptSha256){throw 'JOURNAL_PLAN_MISMATCH'}
        }else{
            if($before.guest){throw 'UNJOURNALED_GUEST_NIC'}
            # A fresh guest/API preflight must precede the first Hyper-V mutation.
            $null=Invoke-GuestPhase 'Plan'
            $journal=[pscustomobject]@{schema=1;vmId='29ba176b-b81a-4f47-8f51-ecec869f247f';guestMac='0229BA176B81';planSha256=$PlanReceiptSha256;guestId='';prepareIntent=$false;spoofIntent=$false;connectIntent=$false}
            Save-DcGuestJournal $journalPath $journal
        }
        $report.networkMutationAttempted=$true
        $persist={Save-DcGuestJournal $journalPath $journal}
        $report.prepared=Invoke-DcGuestNicPhase -Phase Prepare -Journal $journal -Persist $persist
        $report.bridge=Invoke-GuestPhase 'Bridge'
        $report.connected=Invoke-DcGuestNicPhase -Phase Connect -Journal $journal -Persist $persist
        $report.guest=Invoke-GuestPhase 'Label'
        $report.hyperv=Get-DcGuestNetworkSnapshot
        $report.status='GUEST_NETWORK_RECONCILED_NOT_ROUTING_VERIFIED'
    }
}catch{
    $report.status='BLOCKED'
    $reason=[string]$_.Exception.Message
    if($reason -cmatch '^[A-Z_]{1,100}$'){$report.reason=$reason}else{$report.reason='PRIVATE_OR_NATIVE_OPERATION_FAILED'}
    throw 'DC guest-network phase failed; review public evidence and durable intent before continuing.'
}finally{
    if($lock){$lock.Dispose()}
    $apiKey=$null;$apiSecret=$null
    Remove-Item Env:CLOUDSTACK_API_KEY,Env:CLOUDSTACK_SECRET_KEY -ErrorAction SilentlyContinue
    $report|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
