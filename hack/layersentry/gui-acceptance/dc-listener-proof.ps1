param(
  [ValidateSet('dc','dr')][string]$Target='dc',
  [Parameter(Mandatory=$true)][ValidateRange(1,2147483647)][int]$SshProcessId,
  [Parameter(Mandatory=$true)][ValidateRange(1024,65535)][int]$LocalPort,
  [Parameter(Mandatory=$true)][long]$StartedAfterEpochMs,
  [switch]$ExpectAbsent
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
try {
  $targetHost=if($Target -ceq 'dc') {'10.10.10.14'} else {'10.10.10.20'}
  $listeners=@(Get-NetTCPConnection -ErrorAction Stop | Where-Object {$_.State -eq 'Listen' -and $_.LocalPort -eq $LocalPort})
  if($ExpectAbsent) {
    if($listeners.Count -ne 0) {throw 'Listener remains.'}
    @{schema=1;target=$Target;sshHost=$targetHost;listenerAbsent=$true;localLoopbackPort=$LocalPort}|ConvertTo-Json -Compress
    exit 0
  }
  $process=Get-Process -Id $SshProcessId -ErrorAction Stop
  $expected=Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
  $start=([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds()
  if($process.Path -ine $expected -or $start -lt ($StartedAfterEpochMs-1000) -or $start -gt ($StartedAfterEpochMs+15000)) {throw 'Process binding differs.'}
  if($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne '127.0.0.1' -or $listeners[0].OwningProcess -ne $SshProcessId) {throw 'Listener ownership differs.'}
  @{schema=1;target=$Target;sshHost=$targetHost;localLoopbackPort=$LocalPort;remoteLoopbackPort=8080;processId=$SshProcessId;processStartedAt=$start;listenerOwnerVerified=$true;processPathVerified=$true}|ConvertTo-Json -Compress
} catch {
  # Process inspection errors may include local state: emit a fixed public code only.
  [Console]::Error.WriteLine('SSH_LISTENER_PROOF_FAILED')
  exit 1
}
