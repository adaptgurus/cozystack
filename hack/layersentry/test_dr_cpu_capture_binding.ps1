$ErrorActionPreference='Stop'
$errors=$null;$tokens=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'hack/layersentry/invoke-dr-cpu-capture.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'parse failed'}
$definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-RetainedBoot'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$env:BOOT_RUN='123';$env:BOOT_RUNNER_SOURCE='a'*40;$env:BOOT_SOURCE='2b7f06773216d76c455be1ab32d483cebbd38804';$env:CAPTURE_SOURCE='8f94ee6e2ac1e360e39b71b8247e64b62187ef0d';$env:IMAGE_SHA256='b'*64
$id=[Guid]::NewGuid().ToString('D');$base="/var/lib/libvirt/images/layersentry-cpuqc-$id";$owned="$base/ownership.json"
$summary=@{status='LIVE_VERIFIED';target='10.10.10.20';runId='123';runnerCommit=$env:BOOT_RUNNER_SOURCE;bootSource=$env:BOOT_SOURCE;imageSha256=$env:IMAGE_SHA256;bootExitCode=0;ownershipManifest=$owned}
$result=@{status='LIVE_VERIFIED';scope='networkless Rocky CPU image boot and QGA';domainUuid=$id;sourceSha256=$env:IMAGE_SHA256;ownershipManifest=$owned;productionQualified=$false;rke2Started=$false}
$ownership=@{domainUuid=$id;domainName="layersentry-cpuqc-$id";diskPath="$base/runtime.qcow2";seedPath="$base/seed.iso";sourceSha256=$env:IMAGE_SHA256;retainForDrQualification=$true}
$cleanup=@{status='PENDING';reason='EXPLICITLY_RETAINED_FOR_DR_QUALIFICATION';domainUuid=$id;ownershipManifest=$owned}
$facts=@{selinux='Enforcing';hostPublicKeyExportVerified=$true;fixtureId=$id;qgaSelinuxContext='system_u:system_r:virt_qemu_ga_t:s0'}
if((Assert-RetainedBoot $summary $result $ownership $cleanup $facts) -cne $owned){throw 'valid binding failed'}
$cases=@(@($summary,'runnerCommit','c'*40),@($summary,'bootSource',('f'*40)),@($ownership,'retainForDrQualification',$false),@($ownership,'diskPath','/customer.qcow2'),@($facts,'selinux','Permissive'),@($facts,'hostPublicKeyExportVerified',$false),@($facts,'fixtureId',[Guid]::NewGuid().ToString('D')))
foreach($case in $cases){$object=$case[0];$name=$case[1];$previous=$object[$name];$object[$name]=$case[2];$refused=$false;try{Assert-RetainedBoot $summary $result $ownership $cleanup $facts|Out-Null}catch{$refused=$true};$object[$name]=$previous;if(-not $refused){throw "negative case accepted: $name"}}
'Boot evidence binding: valid case and seven negative cases passed'
