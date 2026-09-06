import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { spawn } from 'node:child_process'
import { pathToFileURL } from 'node:url'
import { ASKPASS } from './dc-tunnel.mjs'
import { sshEnvironment, classifySshFailure } from './owned-tunnel.mjs'
import { requireThat, publicFailure, readProtectedBytes } from './contract.mjs'

const MARKER = 'LAYERSENTRY_NONSECRET_ASKPASS_DIAGNOSTIC'
export function configOnlyArguments () {
  return ['-G', '-F', 'NUL', '-o', 'CanonicalizeHostname=no', '-o', 'ProxyCommand=none', '-o', 'PermitLocalCommand=no', '-o', 'BatchMode=yes', 'root@10.10.10.14']
}
export function diagnosticEnvironments (source, helper) {
  const fixed = sshEnvironment(source)
  // The only password-named variable is a fixed public test marker. The
  // existing operator/SSH/API credentials are neither read nor inherited.
  Object.assign(fixed, { ROCKY_PASSWORD: MARKER, SSH_ASKPASS: helper, SSH_ASKPASS_REQUIRE: 'force', DISPLAY: 'layersentry-noninteractive', LAYERSENTRY_DUMMY_ASKPASS: helper })
  const baseline = { ...fixed }; delete baseline.ProgramData
  return { baseline, fixed }
}

async function probe (executable, args, env, captureMarker = false) {
  return new Promise(resolve => {
    let stdout = Buffer.alloc(0); let stderr = Buffer.alloc(0); let truncated = false; let timedOut = false; let settled = false
    let spawnErrorCode = null; let exitCode = null; let exitSignal = null; let cleanupTimer
    const child = spawn(executable, args, { env, shell: false, windowsHide: true, stdio: ['ignore', captureMarker ? 'pipe' : 'ignore', 'pipe'] })
    const append = (data, current) => { if (data.length + current.length > 32768) truncated = true; return Buffer.concat([current, data.subarray(0, Math.max(0, 32768 - current.length))]) }
    child.stdout?.on('data', data => { stdout = append(data, stdout) })
    child.stderr?.on('data', data => { stderr = append(data, stderr) })
    child.once('error', error => { spawnErrorCode = ['ENOENT', 'EACCES', 'EPERM', 'EINVAL', 'ENOMEM'].includes(error.code) ? error.code : 'OTHER' })
    child.once('exit', (code, signal) => { exitCode = Number.isInteger(code) ? code : null; exitSignal = ['SIGTERM', 'SIGKILL'].includes(signal) ? signal : (signal ? 'OTHER' : null) })
    const finish = closed => {
      if (settled) return
      settled = true; clearTimeout(timer); clearTimeout(cleanupTimer)
      const receipt = { processId: child.pid || null, exitCode, spawnErrorCode, exitSignal, timedOut, processClosed: closed, outputTruncated: truncated, stderrClass: classifySshFailure(stderr.toString('utf8')),
        ...(captureMarker ? { dummyMarkerMatched: stdout.toString('utf8').trim() === MARKER } : {}) }
      stdout.fill(0); stderr.fill(0); stdout = Buffer.alloc(0); stderr = Buffer.alloc(0)
      resolve(receipt)
    }
    const timer = setTimeout(() => { timedOut = true; child.kill(); cleanupTimer = setTimeout(() => finish(false), 3000) }, 10000)
    // Wait for close, not only exit, to classify all bounded stderr bytes.
    child.once('close', () => finish(true))
  })
}

export function acceptStartupProof (result) {
  requireThat(result?.schema === 1 && result.networkConnectionAttempted === false && result.realCredentialsUsed === false, 'SSH_STARTUP_PROOF_SCOPE')
  const baseline = result.configuration?.baseline; const fixed = result.configuration?.fixed
  requireThat(baseline?.exitCode === 255 && baseline.stderrClass === 'PROGRAMDATA_MISSING' && fixed?.exitCode === 0, 'SSH_STARTUP_CAUSE_NOT_REPRODUCED')
  for (const item of [baseline, fixed, result.askpass?.baseline, result.askpass?.fixed]) requireThat(item?.processClosed === true && item.spawnErrorCode === null && !item.timedOut && !item.outputTruncated, 'SSH_STARTUP_PROBE_INCOMPLETE')
  requireThat(result.askpass.baseline.exitCode === 0 && result.askpass.baseline.dummyMarkerMatched === true && result.askpass.fixed.exitCode === 0 && result.askpass.fixed.dummyMarkerMatched === true, 'SSH_DUMMY_ASKPASS_FAILED')
}

async function main () {
  const [privateDirectory, output] = process.argv.slice(2)
  requireThat(process.platform === 'win32' && process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'WINDOWS_TRUSTED_DIAGNOSTIC_WRAPPER_REQUIRED')
  requireThat(typeof privateDirectory === 'string' && typeof output === 'string', 'SSH_DIAGNOSTIC_PATHS_REQUIRED')
  const directory = path.resolve(privateDirectory)
  requireThat(fs.lstatSync(directory).isDirectory() && !fs.lstatSync(directory).isSymbolicLink(), 'SSH_DIAGNOSTIC_PRIVATE_DIRECTORY_REQUIRED')
  const helper = path.join(directory, 'dummy-askpass-' + crypto.randomUUID() + '.cmd')
  const result = { schema: 1, status: 'BLOCKED', networkConnectionAttempted: false, realCredentialsUsed: false, scope: 'WINDOWS_OPENSSH_STARTUP_ONLY', productionCertified: false }
  try {
    fs.writeFileSync(helper, ASKPASS, { flag: 'wx', mode: 0o600 })
    requireThat(readProtectedBytes(helper).toString('utf8') === ASKPASS, 'SSH_DIAGNOSTIC_HELPER_CHANGED')
    const { baseline, fixed } = diagnosticEnvironments(process.env, helper)
    requireThat(fixed.ProgramData && fixed.SystemRoot, 'SSH_DIAGNOSTIC_SYSTEM_ENV_REQUIRED')
    const executable = path.join(fixed.SystemRoot, 'System32', 'OpenSSH', 'ssh.exe')
    const powershell = path.join(fixed.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    result.configuration = { baseline: await probe(executable, configOnlyArguments(), baseline), fixed: await probe(executable, configOnlyArguments(), fixed) }
    // Invoke only the exact generated .cmd via a fixed PowerShell expression;
    // its path is an environment value, never interpolated command text.
    const args = ['-NoProfile', '-NonInteractive', '-Command', '& $env:LAYERSENTRY_DUMMY_ASKPASS']
    result.askpass = { baseline: await probe(powershell, args, baseline, true), fixed: await probe(powershell, args, fixed, true) }
    acceptStartupProof(result); result.status = 'PASS'
  } catch (error) { result.reason = publicFailure(error) } finally {
    if (fs.existsSync(helper)) fs.unlinkSync(helper)
    result.dummyHelperRemoved = !fs.existsSync(helper)
    if (!result.dummyHelperRemoved) result.status = 'BLOCKED'
    fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 })
  }
  process.exitCode = result.status === 'PASS' ? 0 : 1
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch(error => { console.error(publicFailure(error)); process.exitCode = 1 })
