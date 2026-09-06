import test from 'node:test'
import assert from 'node:assert/strict'
import { sshEnvironment, classifySshFailure } from './owned-tunnel.mjs'
import { configOnlyArguments, diagnosticEnvironments, acceptStartupProof } from './diagnose-ssh-startup.mjs'

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

test('diagnostic gate requires causal failure, corrected success and both dummy helper proofs', () => {
  const item = () => ({ exitCode: 0, spawnErrorCode: null, processClosed: true, timedOut: false, outputTruncated: false, stderrClass: 'UNKNOWN' })
  const proof = () => ({ schema: 1, networkConnectionAttempted: false, realCredentialsUsed: false, configuration: { baseline: { ...item(), exitCode: 255, stderrClass: 'PROGRAMDATA_MISSING' }, fixed: item() }, askpass: { baseline: { ...item(), dummyMarkerMatched: true }, fixed: { ...item(), dummyMarkerMatched: true } } })
  assert.doesNotThrow(() => acceptStartupProof(proof()))
  for (const mutate of [p => { p.configuration.baseline.stderrClass = 'UNKNOWN' }, p => { p.configuration.fixed.exitCode = 255 }, p => { p.configuration.fixed.processClosed = false }, p => { p.configuration.fixed.outputTruncated = true }, p => { p.askpass.fixed.dummyMarkerMatched = false }, p => { p.askpass.baseline.timedOut = true }, p => { p.realCredentialsUsed = true }, p => { p.networkConnectionAttempted = true }]) {
    const changed = proof(); mutate(changed); assert.throws(() => acceptStartupProof(changed))
  }
})
