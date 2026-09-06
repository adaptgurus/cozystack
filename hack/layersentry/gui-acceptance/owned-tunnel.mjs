import net from 'node:net'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { requireThat } from './contract.mjs'

export const TARGET_HOSTS = Object.freeze({ dc: '10.10.10.14', dr: '10.10.10.20' })
const exec = promisify(execFile)
const directory = path.dirname(fileURLToPath(import.meta.url))

export function validateListenerProof (proof, binding, pid, port, started) {
  requireThat(Object.hasOwn(TARGET_HOSTS, binding?.target) && TARGET_HOSTS[binding?.target] === binding?.host && proof?.schema === 1 && proof.target === binding.target && proof.sshHost === binding.host && proof.remoteLoopbackPort === 8080 &&
    proof.processId === pid && proof.localLoopbackPort === port && proof.listenerOwnerVerified === true && proof.processPathVerified === true &&
    Number.isSafeInteger(proof.processStartedAt) && proof.processStartedAt >= started - 1000 && proof.processStartedAt <= started + 15000, 'SSH_LISTENER_OWNER_MISMATCH')
  return proof
}

export function sshEnvironment (source = process.env) {
  // Windows OpenSSH 9.5 init_prog_paths requires ProgramData before main(),
  // including configuration-only -G. Never inherit credential/debug variables.
  return Object.fromEntries(['SystemRoot', 'WINDIR', 'PATH', 'TEMP', 'TMP', 'COMSPEC', 'ProgramData'].filter(key => source[key]).map(key => [key, source[key]]))
}

export function classifySshFailure (text) {
  // Conservative categories from OpenSSH 9.5 diagnostics. Text never escapes
  // this in-memory classifier; a category is evidence, not automatic recovery.
  if (text.includes("couldn't find ProgramData environment variable")) return 'PROGRAMDATA_MISSING'
  if (text.includes('failed to initialize w32posix wrapper')) return 'WIN32_WRAPPER_INIT_FAILED'
  if (/No user exists for uid [0-9]+/.test(text)) return 'LOCAL_USER_LOOKUP_FAILED'
  if (/ssh_askpass:|posix_spawn initialization failed|powershell(?:\.exe)?['"]? is not recognized/i.test(text)) return 'ASKPASS_LAUNCH_FAILED'
  if (/host key verification failed|remote host identification has changed|no .* host key is known|host key .* does not match/i.test(text)) return 'HOSTKEY_REJECTED'
  if (/cannot listen to port|could not request local forwarding|address already in use|bind .*permission denied/i.test(text)) return 'FORWARD_BIND_FAILED'
  if (/can't open (?:user )?config|bad configuration option|bad owner or permissions|no such file or directory|invalid format|bad permissions|unknown option|not a valid win32 application/i.test(text)) return 'CONFIG_PATH_FAILED'
  if (/permission denied|too many authentication failures|authentication failed/i.test(text)) return 'AUTH_REJECTED'
  return 'UNKNOWN'
}

export async function openOwnedSshTunnel (binding, argumentsForPort, env) {
  requireThat(process.platform === 'win32' && process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'WINDOWS_TRUSTED_TUNNEL_WRAPPER_REQUIRED')
  requireThat(Object.hasOwn(TARGET_HOSTS, binding?.target) && TARGET_HOSTS[binding.target] === binding.host, 'SSH_TARGET_BINDING_REQUIRED')
  const port = await new Promise((resolve, reject) => {
    const reservation = net.createServer()
    reservation.once('error', () => reject(new Error('LOOPBACK_PORT_UNAVAILABLE')))
    reservation.listen(0, '127.0.0.1', () => { const port = reservation.address().port; reservation.close(() => resolve(port)) })
  })
  const executable = path.join(process.env.SystemRoot, 'System32', 'OpenSSH', 'ssh.exe')
  const prerequisites = { executableExists: fs.existsSync(executable), systemRootPresent: Boolean(env.SystemRoot), programDataPresent: Boolean(env.ProgramData), pathPresent: Boolean(env.PATH), comspecPresent: Boolean(env.COMSPEC), tempPresent: Boolean(env.TEMP),
    askpassConfigured: binding.target === 'dc' ? env.SSH_ASKPASS === binding.askPassFile && env.SSH_ASKPASS_REQUIRE === 'force' && Boolean(env.DISPLAY) : null,
    askpassFileExists: binding.target === 'dc' ? fs.existsSync(binding.askPassFile) : null, passwordEnvironmentPresent: binding.target === 'dc' ? typeof env.ROCKY_PASSWORD === 'string' && env.ROCKY_PASSWORD.length > 0 : null }
  requireThat(prerequisites.programDataPresent, 'SSH_PROGRAMDATA_REQUIRED')
  const started = Date.now()
  const child = spawn(executable, argumentsForPort(port), { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true, shell: false, env })
  let stderr = Buffer.alloc(0); let stderrTruncated = false
  child.stderr.on('data', data => { const available = 32768 - stderr.length; if (data.length > available) stderrTruncated = true; if (available > 0) stderr = Buffer.concat([stderr, data.subarray(0, available)]) })
  let ended = false; let closed = false; let spawnErrorCode = null; let exitCode = null; let exitSignal = null
  child.on('error', error => { ended = true; spawnErrorCode = ['ENOENT', 'EACCES', 'EPERM', 'EINVAL', 'ENOMEM', 'UNKNOWN'].includes(error.code) ? error.code : 'OTHER' })
  child.on('exit', (code, signal) => { ended = true; exitCode = Number.isInteger(code) ? code : null; exitSignal = ['SIGTERM', 'SIGKILL'].includes(signal) ? signal : (signal ? 'OTHER' : null) })
  const inspect = async absent => {
    const args = ['-NoProfile', '-NonInteractive', '-File', path.join(directory, 'dc-listener-proof.ps1'), '-Target', binding.target,
      '-SshProcessId', String(child.pid || 1), '-LocalPort', String(port), '-StartedAfterEpochMs', String(started)]
    if (absent) args.push('-ExpectAbsent')
    const { stdout } = await exec(path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), args, { windowsHide: true, timeout: 8000, maxBuffer: 8192 })
    return JSON.parse(stdout)
  }
  const assertReady = async () => {
    requireThat(!ended && Number.isInteger(child.pid), 'STRICT_SSH_TUNNEL_FAILED')
    const proof = validateListenerProof(await inspect(false), binding, child.pid, port, started)
    requireThat(!ended, 'STRICT_SSH_TUNNEL_FAILED')
    return proof
  }
  const close = async () => {
    if (closed) return
    if (!ended) {
      child.kill()
      await new Promise(resolve => { const timer = setTimeout(resolve, 5000); child.once('exit', () => { clearTimeout(timer); resolve() }) })
    }
    requireThat(ended, 'SSH_TUNNEL_CLEANUP_UNVERIFIED')
    const proof = await inspect(true)
    requireThat(proof.schema === 1 && proof.target === binding.target && proof.sshHost === binding.host && proof.listenerAbsent === true && proof.localLoopbackPort === port, 'SSH_LISTENER_CLEANUP_UNVERIFIED')
    closed = true
    stderr.fill(0); stderr = Buffer.alloc(0)
  }
  try {
    const deadline = Date.now() + 20000
    while (Date.now() < deadline) {
      requireThat(!ended, 'STRICT_SSH_TUNNEL_FAILED')
      try {
        const proof = await assertReady()
        return { base: `http://127.0.0.1:${port}/client/`, proof: { ...proof, strictHostVerification: true }, alive: () => !ended && !closed, assertReady, close }
      } catch { requireThat(!ended, 'STRICT_SSH_TUNNEL_FAILED') }
      await new Promise(resolve => setTimeout(resolve, 150))
    }
    throw new Error('SSH_TUNNEL_TIMEOUT')
  } catch (error) {
    // Record only locally generated/allowlisted launch facts, never arguments,
    // environment, raw stderr, browser state or API response contents.
    const diagnostic = { schema: 1, target: binding.target, sshHost: binding.host, executable: 'System32/OpenSSH/ssh.exe', processId: child.pid || null, localLoopbackPort: port, spawnErrorCode, exitCode, exitSignal, stderrClass: classifySshFailure(stderr.toString('utf8')), stderrTruncated, prerequisites, cleanupVerified: false }
    try { await close(); diagnostic.cleanupVerified = true } catch { diagnostic.cleanupError = 'SSH_TUNNEL_CLEANUP_UNVERIFIED' }
    const failure = new Error(diagnostic.cleanupVerified ? (/^[A-Z][A-Z0-9_]{2,80}$/.test(error.message) ? error.message : 'SSH_TUNNEL_INSPECTION_FAILED') : 'SSH_TUNNEL_CLEANUP_UNVERIFIED')
    stderr.fill(0); stderr = Buffer.alloc(0)
    failure.tunnelDiagnostic = diagnostic
    throw failure
  }
}
