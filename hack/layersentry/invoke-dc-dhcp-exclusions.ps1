param([ValidateSet('Plan','Apply')][string]$Mode='Plan',[string]$PlanReceiptPath='', [string]$PlanReceiptSha256='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module Hyper-V -ErrorAction Stop
Import-Module DhcpServer -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'DcDhcpExclusions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DcGuestNetwork.psm1') -Force
$out=Join-Path $env:RUNNER_TEMP "layersentry-dc-dhcp-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
New-Item -ItemType Directory -Path $out -ErrorAction Stop|Out-Null
$report=[ordered]@{schema=1;host='TESTSER';mode=$Mode;runId=$env:GITHUB_RUN_ID;sourceCommit=$env:GITHUB_SHA;status='PENDING';exclusionMutationAttempted=$false}
$lock=$null
try{
    $current=Get-DcDhcpExclusionPlan
    if($Mode -ceq 'Plan'){$report.data=$current;$report.status='PLAN_REVIEW_REQUIRED'}else{
        if($PlanReceiptSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $PlanReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $PlanReceiptSha256){throw 'REVIEWED_DHCP_PLAN_HASH_REQUIRED'}
        $plan=Get-Content -LiteralPath $PlanReceiptPath -Raw|ConvertFrom-Json
        if($plan.schema -ne 1 -or $plan.host -cne 'TESTSER' -or $plan.mode -cne 'Plan' -or $plan.status -cne 'PLAN_REVIEW_REQUIRED' -or $plan.exclusionMutationAttempted -ne $false -or $plan.data.scope -cne '10.10.10.0' -or @($plan.data.exclusions).Count -ne 0){throw 'DHCP_PLAN_SCOPE_CHANGED'}
        $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'ADMINISTRATOR_REQUIRED'}
        $root=Join-Path $env:ProgramData 'LayerSentry\dc-dhcp-exclusions-r0'
        $ancestor=[IO.DirectoryInfo]$root
        while($ancestor){if($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'JOURNAL_REPARSE_POINT'};$ancestor=$ancestor.Parent}
        New-Item -ItemType Directory -Path $root -Force|Out-Null
        $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
        foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))}
        Set-Acl -LiteralPath $root -AclObject $acl
        foreach($entry in @(Get-ChildItem -LiteralPath $root -Force)){if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'JOURNAL_ENTRY_REPARSE_POINT'}}
        $lock=[IO.File]::Open((Join-Path $root 'host.lock'),'OpenOrCreate','ReadWrite','None')
        $path=Join-Path $root 'journal.json'
        if(Test-Path -LiteralPath $path){
            if((Get-Item -LiteralPath $path).Length -gt 65536){throw 'JOURNAL_SIZE_LIMIT'}
            $journal=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
            if($journal.planSha256 -cne $PlanReceiptSha256){throw 'DHCP_JOURNAL_PLAN_CHANGED'}
        }else{
            $journal=[pscustomobject]@{schema=1;host='TESTSER';scope='10.10.10.0';planSha256=$PlanReceiptSha256;baseline=$plan.data;intent14=$false;intent20=$false}
            Save-DcGuestJournal $path $journal
        }
        $report.exclusionMutationAttempted=$true
        $report.data=Invoke-DcDhcpExclusions -Journal $journal -Persist {Save-DcGuestJournal $path $journal}
        $report.status='EXCLUSIONS_RECONCILED_LEASES_PRESERVED'
    }
}catch{
    $report.status='BLOCKED';$reason=[string]$_.Exception.Message
    $report.reason=if($reason -cmatch '^[A-Z_]{1,100}$'){$reason}else{'PRIVATE_OR_NATIVE_OPERATION_FAILED'}
    $report.errorType=$_.Exception.GetType().FullName
    $report.sourceLine=$_.InvocationInfo.ScriptLineNumber
    throw 'DHCP exclusion phase failed; inspect intent and native inventory before continuing.'
}finally{
    if($lock){$lock.Dispose()}
    $report|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
