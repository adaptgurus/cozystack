import crypto from 'node:crypto'
import { readProtectedBytes, requireThat } from './contract.mjs'
import { openOwnedSshTunnel, validateListenerProof } from './owned-tunnel.mjs'

export const DC_FINGERPRINT = 'SHA256:ibF5v8VUj3Iawmgn/czLeJK7zUAM2kIqIJdzV04uFPw'
export const ASKPASS = '@echo off\r\npowershell.exe -NoProfile -NonInteractive -Command "[Console]::Write([Environment]::GetEnvironmentVariable(\'ROCKY_PASSWORD\'))"\r\n'

export function verifyDcHostKey (raw) {
  const lines = raw.trim().split(/\r?\n/)
  requireThat(lines.length === 1 && /^10\.10\.10\.14 ssh-ed25519 [A-Za-z0-9+/]+={0,2}$/.test(lines[0]), 'DC_HOST_KEY_SCOPE_INVALID')
  const blob = Buffer.from(lines[0].split(' ')[2], 'base64')
  requireThat(blob.length === 51 && blob.readUInt32BE(0) === 11 && blob.subarray(4, 15).toString() === 'ssh-ed25519' && blob.readUInt32BE(15) === 32, 'DC_HOST_KEY_FORMAT_INVALID')
  const fingerprint = 'SHA256:' + crypto.createHash('sha256').update(blob).digest('base64').replace(/=+$/, '')
  requireThat(fingerprint === DC_FINGERPRINT, 'DC_HOST_KEY_FINGERPRINT_MISMATCH')
  return fingerprint
}

export function dcTunnelArguments (binding, port) {
  requireThat(binding?.target === 'dc' && binding.host === '10.10.10.14' && binding.user === 'root', 'DC_SSH_TARGET_REQUIRED')
  requireThat(Number.isInteger(port) && port >= 1024 && port <= 65535, 'INVALID_LOOPBACK_PORT')
  requireThat(typeof binding.knownHostsFile === 'string' && typeof binding.askPassFile === 'string' && typeof binding.passwordFile === 'string', 'DC_TRUST_FILES_REQUIRED')
  return ['-F', 'NUL', '-N', '-T', '-o', 'BatchMode=no', '-o', 'PreferredAuthentications=password',
    '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1', '-o', 'StrictHostKeyChecking=yes',
    '-o', `UserKnownHostsFile=${binding.knownHostsFile}`, '-o', 'GlobalKnownHostsFile=NUL', '-o', 'UpdateHostKeys=no',
    '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no', '-o', 'ExitOnForwardFailure=yes',
    '-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
    '-L', `127.0.0.1:${port}:127.0.0.1:8080`, 'root@10.10.10.14']
}

export function validateDcListenerProof (proof, pid, port, started) {
  return validateListenerProof(proof, { target: 'dc', host: '10.10.10.14' }, pid, port, started)
}

export async function openDcTunnel (binding) {
  requireThat(process.platform === 'win32' && process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'DC_WINDOWS_TRUSTED_WRAPPER_REQUIRED')
  dcTunnelArguments(binding, 1024)
  verifyDcHostKey(readProtectedBytes(binding.knownHostsFile).toString('utf8'))
  requireThat(readProtectedBytes(binding.askPassFile).toString('utf8') === ASKPASS, 'DC_ASKPASS_HELPER_MISMATCH')
  const secret = JSON.parse(readProtectedBytes(binding.passwordFile).toString('utf8'))
  requireThat(typeof secret.password === 'string' && secret.password.length > 0 && secret.password.length <= 4096 && !/[\r\n\0]/.test(secret.password), 'DC_PASSWORD_PREREQUISITE_MISSING')
  const env = Object.fromEntries(['SystemRoot', 'WINDIR', 'PATH', 'TEMP', 'TMP', 'COMSPEC'].filter(k => process.env[k]).map(k => [k, process.env[k]]))
  Object.assign(env, { SSH_ASKPASS: binding.askPassFile, SSH_ASKPASS_REQUIRE: 'force', DISPLAY: 'layersentry-noninteractive', ROCKY_PASSWORD: secret.password })
  try {
    const tunnel = await openOwnedSshTunnel(binding, port => dcTunnelArguments(binding, port), env)
    tunnel.proof.hostKeyFingerprint = DC_FINGERPRINT
    return tunnel
  } finally { delete env.ROCKY_PASSWORD; secret.password = null }
}
