Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DrNetworkRequest {
    param([object]$Request)
    $fields = @('requestId','host','vmId','vmName','nicId','currentSwitchId','ownerRequestSha256','switchName','subnet','gateway')
    if (@($Request.PSObject.Properties.Name).Count -ne $fields.Count) { throw 'Invalid request fields.' }
    foreach ($field in $fields) { if ($Request.PSObject.Properties.Name -notcontains $field -or $Request.$field -isnot [string] -or -not $Request.$field) { throw 'Invalid request field.' } }
    if ($Request.requestId -cnotmatch '^[a-z0-9][a-z0-9-]{5,63}$' -or $Request.host -cnotmatch '^[A-Za-z0-9-]{1,63}$') { throw 'Invalid request identity.' }
    foreach ($field in @('vmId','currentSwitchId')) { if ($Request.$field -cnotmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Invalid resource ID.' } }
    if ($Request.nicId.Length -gt 200 -or $Request.nicId -cnotmatch '^[A-Za-z0-9{}_.:\\-]+$') { throw 'Invalid NIC ID.' }
    if ($Request.vmName -cne 'layersentry-dr-rocky9' -or $Request.switchName -cne 'LayerSentry-DR-Internal' -or $Request.subnet -cne '10.10.20.0/24' -or $Request.gateway -cne '10.10.20.1') { throw 'Request is outside the approved DR network profile.' }
    if ($Request.ownerRequestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid owner request digest.' }
}

function ConvertTo-UInt32Address([string]$Address) {
    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes(); [array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-CidrOverlap([string]$Left, [string]$Right) {
    $a=$Left.Split('/'); $b=$Right.Split('/'); $ap=[int]$a[1]; $bp=[int]$b[1]
    if ($ap -lt 1 -or $ap -gt 32 -or $bp -lt 1 -or $bp -gt 32) { throw 'Invalid IPv4 prefix.' }
    $av=ConvertTo-UInt32Address $a[0]; $bv=ConvertTo-UInt32Address $b[0]
    $bits=[math]::Min($ap,$bp); [uint32]$mask=if($bits -eq 0){0}else{[uint32]::MaxValue -shl (32-$bits)}
    return (($av -band $mask) -eq ($bv -band $mask))
}

function Get-OwnedDrVm([object]$Request) {
    $vm=Get-VM -Id ([guid]$Request.vmId) -ErrorAction Stop
    if ($vm.Name -cne $Request.vmName -or $vm.Notes -cne "LayerSentry two-vm-lab $($Request.ownerRequestSha256.ToUpperInvariant())") { throw 'DR VM ownership mismatch.' }
    $nic=@(Get-VMNetworkAdapter -VM $vm)
    if ($nic.Count -ne 1 -or [string]$nic[0].Id -cne $Request.nicId) { throw 'DR NIC ownership mismatch.' }
    return [pscustomobject]@{ VM=$vm; NIC=$nic[0] }
}

function Get-DrNetworkPreflight([object]$Request, [string]$RequestHash) {
    Assert-DrNetworkRequest $Request
    if ($env:COMPUTERNAME -ine $Request.host -or (Get-Service vmms).Status -ne 'Running') { throw 'Wrong host or VMMS unavailable.' }
    $owned=Get-OwnedDrVm $Request
    if ([string]$owned.VM.State -notin @('Off','Running')) { throw 'DR VM is not stable.' }
    $target=@(Get-VMSwitch -Name $Request.switchName -ErrorAction SilentlyContinue)
    if ($target.Count -gt 1 -or ($target.Count -eq 1 -and [string]$target[0].SwitchType -cne 'Internal')) { throw 'Target switch name collision.' }
    if ($target.Count -eq 1 -and [string]$target[0].Notes -cne "LayerSentry DR network $RequestHash") { throw 'Target switch ownership mismatch.' }
    $desiredAlias="vEthernet ($($Request.switchName))"
    if ([string]$owned.NIC.SwitchId -cne $Request.currentSwitchId -and ($target.Count -ne 1 -or [string]$owned.NIC.SwitchId -cne [string]$target[0].Id)) { throw 'DR NIC is not on its recorded original or owned target switch.' }
    foreach($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        if ([string]$ip.InterfaceAlias -ceq $desiredAlias -and [string]$ip.IPAddress -ceq $Request.gateway -and [int]$ip.PrefixLength -eq 24) { continue }
        if (Test-CidrOverlap "$($ip.IPAddress)/$($ip.PrefixLength)" $Request.subnet) { throw 'DR subnet overlaps a host interface prefix.' }
    }
    foreach($nat in @(Get-NetNat -ErrorAction SilentlyContinue)) { if (Test-CidrOverlap ([string]$nat.InternalIPInterfaceAddressPrefix) $Request.subnet) { throw 'DR subnet overlaps WinNAT.' } }
    # A default route overlaps every CIDR and is intentionally excluded; connected/specific routes are authoritative here.
    foreach($route in @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -ne '0.0.0.0/0')) {
        # New-NetIPAddress creates both connected and host-local routes on this exact owned interface.
        if ([string]$route.InterfaceAlias -ieq $desiredAlias) { continue }
        if (Test-CidrOverlap ([string]$route.DestinationPrefix) $Request.subnet) { throw 'DR subnet overlaps a host route.' }
    }
    # Hyper-V formats adapter IDs differently between -VM and -All; VM names remain unique.
    # Get-OwnedDrVm above already binds the exact VM and NIC before this occupancy check.
    $attached=@(Get-VMNetworkAdapter -All | Where-Object { [string]$_.SwitchName -ceq $Request.switchName -and [string]$_.VMName -ine $Request.vmName })
    if ($attached.Count) { throw 'Target switch is used by another VM.' }
    $state=if($target.Count -eq 0){'ReadyToCreate'}elseif([string]$owned.NIC.SwitchId -ceq [string]$target[0].Id){'Applied'}else{'ReadyToConnect'}
    [ordered]@{status='DESIGN_DEFINED'; state=$state; vmId=[string]$owned.VM.Id; nicId=[string]$owned.NIC.Id; originalSwitchId=[string]$owned.NIC.SwitchId; switchId=$(if($target.Count){[string]$target[0].Id}else{''}); mutationAttempted=$false}
}

Export-ModuleMember -Function Assert-DrNetworkRequest,Test-CidrOverlap,Get-OwnedDrVm,Get-DrNetworkPreflight
