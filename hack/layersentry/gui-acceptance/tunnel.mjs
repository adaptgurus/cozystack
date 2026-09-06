import net from 'node:net'
import { spawn } from 'node:child_process'
import { requireThat } from './contract.mjs'

// Only the trusted wrapper supplies these protected file paths. No password,
// agent forwarding, shell command or arbitrary forwarding destination is used.
export function tunnelArguments (binding, port) {
  requireThat(binding?.target === 'dr' && binding.host === '10.10.10.20' && /^[a-z_][a-z0-9_-]{0,31}$/.test(binding.user), 'SSH_TARGET_BINDING_REQUIRED')
  requireThat(typeof binding.keyFile === 'string' && typeof binding.knownHostsFile === 'string', 'SSH_TRUST_FILES_REQUIRED')
  requireThat(Number.isInteger(port) && port >= 1024 && port <= 65535, 'INVALID_LOOPBACK_PORT')
  return ['-F', 'none', '-N', '-T', '-i', binding.keyFile,
    '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
    '-o', `UserKnownHostsFile=${binding.knownHostsFile}`, '-o', 'GlobalKnownHostsFile=none',
    '-o', 'UpdateHostKeys=no', '-o', 'ForwardAgent=no', '-o', 'PermitLocalCommand=no',
    '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2',
    '-L', `127.0.0.1:${port}:127.0.0.1:8080`, `${binding.user}@${binding.host}`]
}

export async function openDrTunnel (binding) {
  tunnelArguments(binding, 1024)
  const port = await new Promise((resolve, reject) => {
    const reservation = net.createServer()
    reservation.once('error', () => reject(new Error('LOOPBACK_PORT_UNAVAILABLE')))
    reservation.listen(0, '127.0.0.1', () => { const port = reservation.address().port; reservation.close(() => resolve(port)) })
  })
  const child = spawn('ssh', tunnelArguments(binding, port), { stdio: 'ignore', windowsHide: true, shell: false })
  let ended = false
  child.on('error', () => { ended = true }); child.on('exit', () => { ended = true })
  const close = async () => {
    if (ended) return
    child.kill()
    await new Promise(resolve => { const timer = setTimeout(resolve, 3000); child.once('exit', () => { clearTimeout(timer); resolve() }) })
    requireThat(ended, 'SSH_TUNNEL_CLEANUP_UNVERIFIED')
  }
  try {
    const deadline = Date.now() + 15000
    while (Date.now() < deadline) {
      requireThat(!ended, 'STRICT_SSH_TUNNEL_FAILED')
      const connected = await new Promise(resolve => {
        const socket = net.connect({ host: '127.0.0.1', port })
        socket.setTimeout(300); socket.once('connect', () => { socket.destroy(); resolve(true) })
        socket.once('error', () => resolve(false)); socket.once('timeout', () => { socket.destroy(); resolve(false) })
      })
      if (connected) {
        requireThat(!ended, 'STRICT_SSH_TUNNEL_FAILED')
        return { base: `http://127.0.0.1:${port}/client/`, proof: { target: 'dr', sshHost: binding.host, remoteLoopbackPort: 8080, localLoopbackPort: port, processId: child.pid, strictHostVerification: true }, alive: () => !ended, close }
      }
      // Bounded network establishment polling; no API/login/mutation retry.
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    throw new Error('SSH_TUNNEL_TIMEOUT')
  } catch (error) { await close(); throw error }
}
