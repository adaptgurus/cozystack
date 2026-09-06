import crypto from 'node:crypto'
import net from 'node:net'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { readProtectedBytes, requireThat } from './contract.mjs'

export const DC_FINGERPRINT = 'SHA256:ibF5v8VUj3Iawmgn/czLeJK7zUAM2kIqIJdzV04uFPw'
export const ASKPASS = '@echo off\r\npowershell.exe -NoProfile -NonInteractive -Command "[Console]::Write([Environment]::GetEnvironmentVariable(\'ROCKY_PASSWORD\'))"\r\n'
const exec = promisify(execFile)
const directory = path.dirname(fileURLToPath(import.meta.url))

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
  requireThat(proof?.schema === 1 && proof.target === 'dc' && proof.sshHost === '10.10.10.14' && proof.remoteLoopbackPort === 8080 &&
    proof.processId === pid && proof.localLoopbackPort === port && proof.listenerOwnerVerified === true && proof.processPathVerified === true &&
    Number.isSafeInteger(proof.processStartedAt) && proof.processStartedAt >= started - 1000 && proof.processStartedAt <= started + 15000, 'DC_LISTENER_OWNER_MISMATCH')
  return proof
}

export async function openDcTunnel (binding) {
  requireThat(process.platform === 'win32' && process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'DC_WINDOWS_TRUSTED_WRAPPER_REQUIRED')
  dcTunnelArguments(binding, 1024)
  verifyDcHostKey(readProtectedBytes(binding.knownHostsFile).toString('utf8'))
  requireThat(readProtectedBytes(binding.askPassFile).toString('utf8') === ASKPASS, 'DC_ASKPASS_HELPER_MISMATCH')
  const secret = JSON.parse(readProtectedBytes(binding.passwordFile).toString('utf8'))
  requireThat(typeof secret.password === 'string' && secret.password.length > 0 && secret.password.length <= 4096 && !/[\r\n\0]/.test(secret.password), 'DC_PASSWORD_PREREQUISITE_MISSING')
  const port = await new Promise((resolve, reject) => {
    const reservation = net.createServer()
    reservation.once('error', () => reject(new Error('LOOPBACK_PORT_UNAVAILABLE')))
    reservation.listen(0, '127.0.0.1', () => { const port = reservation.address().port; reservation.close(() => resolve(port)) })
  })
  const env = Object.fromEntries(['SystemRoot', 'WINDIR', 'PATH', 'TEMP', 'TMP', 'COMSPEC'].filter(k => process.env[k]).map(k => [k, process.env[k]]))
  Object.assign(env, { SSH_ASKPASS: binding.askPassFile, SSH_ASKPASS_REQUIRE: 'force', DISPLAY: 'layersentry-noninteractive', ROCKY_PASSWORD: secret.password })
  const started = Date.now()
  const child = spawn(path.join(process.env.SystemRoot, 'System32', 'OpenSSH', 'ssh.exe'), dcTunnelArguments(binding, port), { stdio: 'ignore', windowsHide: true, shell: false, env })
  delete env.ROCKY_PASSWORD
  secret.password = null
  let ended = false
  child.on('error', () => { ended = true }); child.on('exit', () => { ended = true })
  const inspect = async absent => {
    const args = ['-NoProfile', '-NonInteractive', '-File', path.join(directory, 'dc-listener-proof.ps1'), '-SshProcessId', String(child.pid), '-LocalPort', String(port), '-StartedAfterEpochMs', String(started)]
    if (absent) args.push('-ExpectAbsent')
    const { stdout } = await exec(path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), args, { windowsHide: true, timeout: 8000, maxBuffer: 8192 })
    return JSON.parse(stdout)
  }
  const assertReady = async () => {
    requireThat(!ended && Number.isInteger(child.pid), 'DC_SSH_TUNNEL_FAILED')
    const proof = validateDcListenerProof(await inspect(false), child.pid, port, started)
    requireThat(!ended, 'DC_SSH_TUNNEL_FAILED')
    return proof
  }
  const close = async () => {
    if (!ended) {
      child.kill()
      await new Promise(resolve => { const timer = setTimeout(resolve, 5000); child.once('exit', () => { clearTimeout(timer); resolve() }) })
    }
    requireThat(ended, 'DC_SSH_CLEANUP_UNVERIFIED')
    const proof = await inspect(true)
    requireThat(proof.schema === 1 && proof.listenerAbsent === true && proof.localLoopbackPort === port, 'DC_LISTENER_CLEANUP_UNVERIFIED')
  }
  try {
    const deadline = Date.now() + 20000
    while (Date.now() < deadline) {
      requireThat(!ended, 'DC_SSH_TUNNEL_FAILED')
      try {
        const proof = await assertReady()
        return { base: `http://127.0.0.1:${port}/client/`, proof: { ...proof, hostKeyFingerprint: DC_FINGERPRINT, strictHostVerification: true }, alive: () => !ended, assertReady, close }
      } catch { requireThat(!ended, 'DC_SSH_TUNNEL_FAILED') }
      await new Promise(resolve => setTimeout(resolve, 150))
    }
    throw new Error('DC_SSH_TUNNEL_TIMEOUT')
  } catch (error) { await close(); throw error }
}
