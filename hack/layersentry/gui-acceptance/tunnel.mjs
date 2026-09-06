import { sshEnvironment, openOwnedSshTunnel } from './owned-tunnel.mjs'
import { requireThat } from './contract.mjs'

// Only the trusted wrapper supplies these protected file paths. No password,
// agent forwarding, shell command or arbitrary forwarding destination is used.
export function tunnelArguments (binding, port) {
  requireThat(binding?.target === 'dr' && binding.host === '10.10.10.20' && /^[a-z_][a-z0-9_-]{0,31}$/.test(binding.user), 'SSH_TARGET_BINDING_REQUIRED')
  requireThat(typeof binding.keyFile === 'string' && typeof binding.knownHostsFile === 'string', 'SSH_TRUST_FILES_REQUIRED')
  requireThat(Number.isInteger(port) && port >= 1024 && port <= 65535, 'INVALID_LOOPBACK_PORT')
  return ['-F', 'NUL', '-N', '-T', '-i', binding.keyFile,
    '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', `UserKnownHostsFile=${binding.knownHostsFile}`, '-o', 'GlobalKnownHostsFile=NUL',
    '-o', 'UpdateHostKeys=no', '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no',
    '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
    '-L', `127.0.0.1:${port}:127.0.0.1:8080`, `${binding.user}@${binding.host}`]
}

export async function openDrTunnel (binding) {
  tunnelArguments(binding, 1024)
  const env = sshEnvironment()
  return openOwnedSshTunnel(binding, port => tunnelArguments(binding, port), env)
}
