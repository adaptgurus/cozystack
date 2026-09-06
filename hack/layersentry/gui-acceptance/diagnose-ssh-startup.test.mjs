import test from 'node:test'
import assert from 'node:assert/strict'
import { sshEnvironment, classifySshFailure } from './owned-tunnel.mjs'
import { configOnlyArguments, diagnosticEnvironments, acceptStartupProof, probeInputBinding, dummyHelperInvocation, MARKER } from './diagnose-ssh-startup.mjs'

test('both launch callers share a credential-free ProgramData-aware environment', () => {
  const input = { SystemRoot: 'C:\\WINDOWS', ProgramData: 'C:\\ProgramData', PATH: 'system path', ROCKY_PASSWORD: 'never-inherit-real-password', CLOUDSTACK_SECRET_KEY: 'never-inherit-key', SSH_AUTH_SOCK: 'never-inherit-agent', DEBUG: 'never-inherit-debug' }
  assert.deepEqual(sshEnvironment(input), { SystemRoot: input.SystemRoot, PATH: input.PATH, ProgramData: input.ProgramData })
  const { baseline, fixed } = diagnosticEnvironments(input, 'C:\\private\\dummy.cmd')
  assert.equal(fixed.ProgramData, input.ProgramData); assert.equal(baseline.ProgramData, undefined)
  const comparison = { ...fixed }; delete comparison.ProgramData
  assert.deepEqual(baseline, comparison)
  assert.equal(fixed.ROCKY_PASSWORD, 'LAYERSENTRY_NONSECRET_ASKPASS_DIAGNOSTIC')
  assert.ok(!JSON.stringify({ baseline, fixed }).includes('never-inherit'))
})

test('configuration probe never requests a connection, forward or remote command', () => {
  assert.deepEqual(configOnlyArguments(), ['-G', '-F', 'NUL', '-o', 'CanonicalizeHostname=no', '-o', 'ProxyCommand=none', '-o', 'PermitLocalCommand=no', '-o', 'BatchMode=yes', 'root@10.10.10.14'])
  assert.equal(classifySshFailure("couldn't find ProgramData environment variable"), 'PROGRAMDATA_MISSING')
  assert.equal(classifySshFailure('failed to initialize w32posix wrapper'), 'WIN32_WRAPPER_INIT_FAILED')
  assert.equal(classifySshFailure('No user exists for uid 1'), 'LOCAL_USER_LOOKUP_FAILED')
})

test('dummy helper command accepts only owned safe basenames and uses private cwd', () => {
  assert.deepEqual(dummyHelperInvocation('/windows', '/private/dummy-askpass-abcd-1234.cmd'), { executable: '/windows/System32/cmd.exe', args: ['/d', '/c', 'dummy-askpass-abcd-1234.cmd'], cwd: '/private' })
  for (const helper of ['/private/dummy-askpass-a&whoami.cmd', '/private/other.cmd', '/private/dummy-askpass-a.cmd /c bad']) assert.throws(() => dummyHelperInvocation('/windows', helper))
})

test('startup gate requires exact ProgramData differential and proven cmd dummy, without stdin causal claim', () => {
  const entry = (kind, programData) => {
    const env = { SystemRoot: 'windows', ...(programData ? { ProgramData: 'programdata' } : {}) }
    const helper = kind === 'helper'
    return { inputBinding: { ...probeInputBinding(kind + '-executable', (helper ? 'b' : 'a').repeat(64), helper ? ['/d', '/c', 'dummy-askpass-abcd.cmd'] : configOnlyArguments(), env, helper, 'pipe'), cwdSha256: helper ? 'c'.repeat(64) : null }, stderrBytes: 0, stdoutBytes: helper ? Buffer.byteLength(MARKER) : null,
      exitSignal: null, exitCode: 0, spawnErrorCode: null, processClosed: true, timedOut: false, outputTruncated: false, stderrClass: 'UNKNOWN', ...(helper ? { dummyMarkerMatched: true } : {}) }
  }
  const proof = () => ({ schema: 1, networkConnectionAttempted: false, realCredentialsUsed: false,
    configuration: { baseline: { ...entry('ssh', false), exitCode: 255 }, fixed: entry('ssh', true) }, askpass: entry('helper', true) })
  assert.deepEqual(acceptStartupProof(proof()), { programData: 'DIFFERENTIAL_ONLY_EARLY_STDERR_UNAVAILABLE', askpass: 'EXACT_DUMMY_CMD_HELPER_VERIFIED' })
  const message = proof(); message.configuration.baseline.stderrClass = 'PROGRAMDATA_MISSING'; message.configuration.baseline.stderrBytes = 60
  assert.equal(acceptStartupProof(message).programData, 'EXACT_MESSAGE_AND_DIFFERENTIAL')
  for (const mutate of [
    p => { p.configuration.baseline.stderrBytes = 1 }, p => { p.configuration.baseline.exitCode = 0 }, p => { p.configuration.baseline.exitCode = 1 },
    p => { p.configuration.baseline.stderrClass = 'AUTH_REJECTED' }, p => { p.configuration.fixed.inputBinding.environmentWithoutProgramDataSha256 = 'b'.repeat(64) },
    p => { p.configuration.fixed.inputBinding.argumentsSha256 = 'b'.repeat(64) }, p => { p.configuration.fixed.inputBinding.executableSha256 = 'b'.repeat(64) },
    p => { p.configuration.fixed.inputBinding.cwdSha256 = 'f'.repeat(64) }, p => { p.configuration.fixed.inputBinding.stdinMode = 'ignore' },
    p => { p.configuration.fixed.inputBinding.programDataPresent = false }, p => { p.configuration.fixed.exitCode = 255 }, p => { p.configuration.fixed.processClosed = false },
    p => { p.configuration.fixed.outputTruncated = true }, p => { p.askpass.dummyMarkerMatched = false }, p => { p.askpass.stdoutBytes = 0 },
    p => { p.askpass.inputBinding.stdinMode = 'ignore' }, p => { p.askpass.inputBinding.environmentSha256 = 'f'.repeat(64) },
    p => { p.askpass.inputBinding.cwdSha256 = null }, p => { p.askpass.exitCode = 255 }, p => { p.askpass.stderrBytes = 1 },
    p => { p.askpass.stdoutBytes = 42 }, p => { p.askpass.timedOut = true }, p => { p.realCredentialsUsed = true }, p => { p.networkConnectionAttempted = true }
  ]) { const changed = proof(); mutate(changed); assert.throws(() => acceptStartupProof(changed)) }
})
