import test from 'node:test'
import assert from 'node:assert/strict'
import { sshEnvironment, classifySshFailure } from './owned-tunnel.mjs'
import { configOnlyArguments, diagnosticEnvironments, acceptStartupProof, probeInputBinding } from './diagnose-ssh-startup.mjs'

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

test('diagnostic gate independently requires ProgramData and stdin-only dummy differentials', () => {
  const entry = (kind, programData, stdinMode) => {
    const env = { SystemRoot: 'windows', ...(programData ? { ProgramData: 'programdata' } : {}) }
    const helper = kind === 'helper'
    return { inputBinding: probeInputBinding(kind + '-executable', (helper ? 'b' : 'a').repeat(64), helper ? ['fixed helper command'] : configOnlyArguments(), env, helper, stdinMode), stderrBytes: 0, stdoutBytes: helper ? 0 : null,
      exitSignal: null, exitCode: 0, spawnErrorCode: null, processClosed: true, timedOut: false, outputTruncated: false, stderrClass: 'UNKNOWN', ...(helper ? { dummyMarkerMatched: false } : {}) }
  }
  const proof = () => ({ schema: 1, networkConnectionAttempted: false, realCredentialsUsed: false,
    configuration: { baseline: { ...entry('ssh', false, 'ignore'), exitCode: 255 }, fixed: entry('ssh', true, 'ignore') },
    askpass: { baseline: entry('helper', false, 'ignore'), fixed: entry('helper', true, 'ignore') },
    configurationClosedPipe: entry('ssh', true, 'pipe'), askpassClosedPipe: { ...entry('helper', true, 'pipe'), dummyMarkerMatched: true, stdoutBytes: 40 } })
  assert.equal(acceptStartupProof(proof()).stdin, 'NUL_EMPTY_CLOSED_PIPE_DUMMY_VERIFIED')
  assert.equal(acceptStartupProof(proof()).programData, 'DIFFERENTIAL_ONLY_EARLY_STDERR_UNAVAILABLE')
  const message = proof(); message.configuration.baseline.stderrClass = 'PROGRAMDATA_MISSING'; message.configuration.baseline.stderrBytes = 60
  assert.equal(acceptStartupProof(message).programData, 'EXACT_MESSAGE_AND_DIFFERENTIAL')
  for (const mutate of [
    p => { p.configuration.baseline.stderrBytes = 1 }, p => { p.configuration.baseline.exitCode = 0 }, p => { p.configuration.baseline.exitCode = 1 },
    p => { p.configuration.baseline.stderrClass = 'AUTH_REJECTED' }, p => { p.configuration.fixed.inputBinding.environmentWithoutProgramDataSha256 = 'b'.repeat(64) },
    p => { p.configuration.fixed.inputBinding.argumentsSha256 = 'b'.repeat(64) }, p => { p.configuration.fixed.inputBinding.executableSha256 = 'b'.repeat(64) },
    p => { p.configuration.fixed.inputBinding.programDataPresent = false }, p => { p.configuration.fixed.exitCode = 255 }, p => { p.configuration.fixed.processClosed = false },
    p => { p.configuration.fixed.outputTruncated = true }, p => { p.askpassClosedPipe.dummyMarkerMatched = false }, p => { p.askpassClosedPipe.stdoutBytes = 0 },
    p => { p.askpassClosedPipe.inputBinding.stdinMode = 'ignore' }, p => { p.askpassClosedPipe.inputBinding.environmentSha256 = 'f'.repeat(64) },
    p => { p.askpassClosedPipe.inputBinding.argumentsSha256 = 'f'.repeat(64) }, p => { p.configurationClosedPipe.exitCode = 255 },
    p => { p.askpass.fixed.stdoutBytes = 1 }, p => { p.askpass.baseline.timedOut = true }, p => { p.realCredentialsUsed = true }, p => { p.networkConnectionAttempted = true }
  ]) { const changed = proof(); mutate(changed); assert.throws(() => acceptStartupProof(changed)) }
})
