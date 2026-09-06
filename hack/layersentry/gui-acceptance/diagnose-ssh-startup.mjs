import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { spawn } from 'node:child_process'
import { pathToFileURL } from 'node:url'
import { ASKPASS } from './dc-tunnel.mjs'
import { sshEnvironment, classifySshFailure } from './owned-tunnel.mjs'
import { requireThat, publicFailure, readProtectedBytes } from './contract.mjs'

export const MARKER = 'LAYERSENTRY_NONSECRET_ASKPASS_DIAGNOSTIC'
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

const hash = value => crypto.createHash('sha256').update(value).digest('hex')
export function probeInputBinding (executable, executableSha256, args, env, captureMarker = false, stdinMode = 'ignore') {
  requireThat(['ignore', 'pipe'].includes(stdinMode), 'SSH_DIAGNOSTIC_STDIN_MODE')
  const stableEnvironment = Object.fromEntries(Object.entries(env).filter(([key]) => key !== 'ProgramData').sort(([a], [b]) => a.localeCompare(b)))
  return { executableSha256, executablePathSha256: hash(executable), argumentsSha256: hash(JSON.stringify(args)), environmentWithoutProgramDataSha256: hash(JSON.stringify(stableEnvironment)),
    stdinMode, environmentSha256: hash(JSON.stringify(Object.fromEntries(Object.entries(env).sort(([a], [b]) => a.localeCompare(b))))), stdioSha256: hash(JSON.stringify([stdinMode, captureMarker ? 'pipe' : 'ignore', 'pipe'])), programDataPresent: typeof env.ProgramData === 'string' && env.ProgramData.length > 0 }
}

export async function probe (executable, args, env, captureMarker = false, stdinMode = 'ignore', cwd = undefined) {
  const metadata = fs.statSync(executable)
  requireThat(metadata.isFile() && metadata.size <= 32 * 1024 * 1024, 'SSH_DIAGNOSTIC_EXECUTABLE_SIZE')
  const inputBinding = { ...probeInputBinding(executable, hash(fs.readFileSync(executable)), args, env, captureMarker, stdinMode), cwdSha256: cwd ? hash(cwd) : null }
  return new Promise(resolve => {
    let stdoutBytes = 0; let stderrBytes = 0
    let stdout = Buffer.alloc(0); let stderr = Buffer.alloc(0); let truncated = false; let timedOut = false; let settled = false
    let spawnErrorCode = null; let exitCode = null; let exitSignal = null; let cleanupTimer
    const child = spawn(executable, args, { env, cwd, shell: false, windowsHide: true, stdio: [stdinMode, captureMarker ? 'pipe' : 'ignore', 'pipe'] })
    if (stdinMode === 'pipe') child.stdin.end()
    const append = (data, current) => { if (data.length + current.length > 32768) truncated = true; return Buffer.concat([current, data.subarray(0, Math.max(0, 32768 - current.length))]) }
    child.stdout?.on('data', data => { stdoutBytes += data.length; stdout = append(data, stdout) })
    child.stderr?.on('data', data => { stderrBytes += data.length; stderr = append(data, stderr) })
    child.once('error', error => { spawnErrorCode = ['ENOENT', 'EACCES', 'EPERM', 'EINVAL', 'ENOMEM'].includes(error.code) ? error.code : 'OTHER' })
    child.once('exit', (code, signal) => { exitCode = Number.isInteger(code) ? code : null; exitSignal = ['SIGTERM', 'SIGKILL'].includes(signal) ? signal : (signal ? 'OTHER' : null) })
    const finish = closed => {
      if (settled) return
      settled = true; clearTimeout(timer); clearTimeout(cleanupTimer)
      const receipt = { inputBinding, stderrBytes, stdoutBytes: captureMarker ? stdoutBytes : null, processId: child.pid || null, exitCode, spawnErrorCode, exitSignal, timedOut, processClosed: closed, outputTruncated: truncated, stderrClass: classifySshFailure(stderr.toString('utf8')),
        ...(captureMarker ? { dummyMarkerMatched: stdout.toString('utf8').trim() === MARKER } : {}) }
      stdout.fill(0); stderr.fill(0); stdout = Buffer.alloc(0); stderr = Buffer.alloc(0)
      resolve(receipt)
    }
    const timer = setTimeout(() => { timedOut = true; child.kill(); cleanupTimer = setTimeout(() => finish(false), 3000) }, 10000)
    // Wait for close, not only exit, to classify all bounded stderr bytes.
    child.once('close', () => finish(true))
  })
}

export function dummyHelperInvocation (systemRoot, helper) {
  const basename = path.basename(helper)
  requireThat(/^dummy-askpass-[a-f0-9-]+\.cmd$/.test(basename), 'DUMMY_HELPER_BASENAME_REQUIRED')
  return { executable: path.join(systemRoot, 'System32', 'cmd.exe'), args: ['/d', '/c', basename], cwd: path.dirname(helper) }
}

export function acceptStartupProof (result) {
  requireThat(result?.schema === 1 && result.networkConnectionAttempted === false && result.realCredentialsUsed === false, 'SSH_STARTUP_PROOF_SCOPE')
  const baseline = result.configuration?.baseline; const fixed = result.configuration?.fixed; const helper = result.askpass
  requireThat(baseline?.exitCode === 255 && fixed?.exitCode === 0 && (baseline.stderrClass === 'PROGRAMDATA_MISSING' || (baseline.stderrClass === 'UNKNOWN' && baseline.stderrBytes === 0)), 'SSH_STARTUP_CAUSE_NOT_REPRODUCED')
  requireThat(baseline.inputBinding?.programDataPresent === false && fixed.inputBinding?.programDataPresent === true, 'SSH_STARTUP_ENVIRONMENT_DELTA_CHANGED')
  for (const key of ['executableSha256', 'executablePathSha256', 'argumentsSha256', 'environmentWithoutProgramDataSha256', 'stdioSha256']) requireThat(/^[0-9a-f]{64}$/.test(baseline.inputBinding[key]) && baseline.inputBinding[key] === fixed.inputBinding[key], 'SSH_STARTUP_INVARIANTS_CHANGED')
  requireThat(baseline.inputBinding.cwdSha256 === fixed.inputBinding.cwdSha256 && baseline.inputBinding.stdinMode === 'pipe' && fixed.inputBinding.stdinMode === 'pipe', 'SSH_STARTUP_INVARIANTS_CHANGED')
  for (const item of [baseline, fixed, helper]) requireThat(item?.processClosed === true && item.spawnErrorCode === null && item.exitSignal === null && Number.isSafeInteger(item.stderrBytes) && item.stderrBytes >= 0 && !item.timedOut && !item.outputTruncated, 'SSH_STARTUP_PROBE_INCOMPLETE')
  // Run the exact helper directly through cmd, as proven by matrix34064799291.
  // This proves its bytes/environment, not OpenSSH authentication or shell equivalence.
  requireThat(helper.exitCode === 0 && helper.dummyMarkerMatched === true && helper.stdoutBytes === Buffer.byteLength(MARKER) && helper.stderrBytes === 0, 'SSH_DUMMY_HELPER_NOT_VERIFIED')
  requireThat(helper.inputBinding?.programDataPresent === true && helper.inputBinding.stdinMode === 'pipe' && helper.inputBinding.environmentSha256 === fixed.inputBinding.environmentSha256 && /^[0-9a-f]{64}$/.test(helper.inputBinding.cwdSha256), 'SSH_DUMMY_HELPER_INPUT_CHANGED')
  return { programData: baseline.stderrClass === 'PROGRAMDATA_MISSING' ? 'EXACT_MESSAGE_AND_DIFFERENTIAL' : 'DIFFERENTIAL_ONLY_EARLY_STDERR_UNAVAILABLE', askpass: 'EXACT_DUMMY_CMD_HELPER_VERIFIED' }
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
    result.configuration = { baseline: await probe(executable, configOnlyArguments(), baseline, false, 'pipe'), fixed: await probe(executable, configOnlyArguments(), fixed, false, 'pipe') }
    // Only a generated safe basename enters cmd syntax; its private parent is
    // the cwd. No outer PowerShell invocation and no credential substitution.
    const invocation = dummyHelperInvocation(fixed.SystemRoot, helper)
    result.askpass = await probe(invocation.executable, invocation.args, fixed, true, 'pipe', invocation.cwd)
    result.causalProof = acceptStartupProof(result); result.status = 'PASS'
  } catch (error) { result.reason = publicFailure(error) } finally {
    if (fs.existsSync(helper)) fs.unlinkSync(helper)
    result.dummyHelperRemoved = !fs.existsSync(helper)
    if (!result.dummyHelperRemoved) result.status = 'BLOCKED'
    fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 })
  }
  process.exitCode = result.status === 'PASS' ? 0 : 1
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch(error => { console.error(publicFailure(error)); process.exitCode = 1 })
