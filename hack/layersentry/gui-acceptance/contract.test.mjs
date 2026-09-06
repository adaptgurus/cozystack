import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { validateRequest, readProtectedCredentials, classifyGate, allowedRequest, publicFailure } from './contract.mjs'
const origin = 'http://10.10.10.20:8080'
const uuid = '11111111-1111-4111-8111-111111111111'
const request = () => ({ schema: 1, artifactRunId: '123', artifactName: 'test-artifact', target: 'dr', transport: 'strict-ssh-loopback', cloudstackUiCommit: 'a'.repeat(40), artifactSha256: 'b'.repeat(64), personas: [{ id: 'operator', expectedUserId: uuid, projectId: uuid, projectName: 'Disposable project' }] })
test('exact lab and immutable artifact binding is mandatory', () => {
  assert.equal(validateRequest(request()), 'dr')
  for (const change of [{ target: 'http://evil' }, { transport: 'http' }, { target: 'dc' }, { cloudstackUiCommit: 'main' }, { artifactSha256: 'latest' }, { personas: [] }]) assert.throws(() => validateRequest({ ...request(), ...change }))
  const duplicate = request(); duplicate.personas.push(duplicate.personas[0]); assert.throws(() => validateRequest(duplicate))
})
test('route guard rejects all module/native mutations and cross-origin credentials', () => {
  assert.equal(allowedRequest(origin + '/client/api?command=listProjects&sessionkey=private', 'GET', null, origin), true)
  assert.equal(allowedRequest(origin + '/client/api', 'POST', 'command=login&password=private', origin), true)
  for (const [url, method, data] of [[origin + '/client/api?command=deleteProject', 'GET'], [origin + '/client/api', 'POST', 'command=deployVirtualMachine'], [origin + '/client/layersentry-k8s/v1/kubernetes/clusters', 'POST'], ['https://evil.invalid/client/api', 'POST', 'command=login'], [origin + '/client/layersentry-k8s/v1/kubernetes/admin', 'GET'], [origin + '/client/layersentry-dr/v1/promote', 'GET']]) assert.equal(allowedRequest(url, method, data, origin), false)
})
test('accepted or partially configured service never becomes ready evidence', () => {
  assert.equal(classifyGate(202, { kubernetes: true }).status, 'BLOCKED')
  assert.equal(classifyGate(200, { kubernetes: true }).status, 'BLOCKED')
  assert.equal(classifyGate(200, { kubernetes: true, gates: { capc_volume_ownership_safe: true } }).status, 'NOT_TESTED')
  assert.equal(classifyGate(200, '<html>').status, 'BLOCKED')
})
test('public errors never expose browser URLs, headers, passwords or bodies', () => {
  for (const message of ['password=top-secret', 'GET http://host?sessionkey=private', '{"token":"private"}', 'Timeout 20s waiting for username']) assert.equal(publicFailure(new Error(message)), 'GUI_CHECK_FAILED')
  assert.equal(publicFailure(new Error('SERVED_ARTIFACT_MISMATCH')), 'SERVED_ARTIFACT_MISMATCH')
})
test('private file permissions, ownership, links and bounded input are checked', { skip: process.platform === 'win32' }, t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ls-gui-contract-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const file = path.join(dir, 'credentials.json'); fs.writeFileSync(file, '{}', { mode: 0o600 })
  assert.deepEqual(readProtectedCredentials(file), {})
  fs.chmodSync(file, 0o644); assert.throws(() => readProtectedCredentials(file), /PERMISSIONS/); fs.chmodSync(file, 0o600)
  fs.symlinkSync(file, path.join(dir, 'alias')); assert.throws(() => readProtectedCredentials(path.join(dir, 'alias')), /SYMLINK/)
  fs.linkSync(file, path.join(dir, 'hard')); assert.throws(() => readProtectedCredentials(file), /UNSAFE/); fs.unlinkSync(path.join(dir, 'hard'))
  fs.writeFileSync(file, 'x'.repeat(32769)); assert.throws(() => readProtectedCredentials(file), /UNSAFE/)
})


test('SSH transport binds only the reviewed DR host and loopback destination', async () => {
  const { tunnelArguments } = await import('./tunnel.mjs')
  const binding = { target: 'dr', host: '10.10.10.20', user: 'root', keyFile: '/private/key', knownHostsFile: '/private/known_hosts' }
  const args = tunnelArguments(binding, 23456)
  assert.ok(args.includes('127.0.0.1:23456:127.0.0.1:8080'))
  assert.ok(args.includes('StrictHostKeyChecking=yes')); assert.ok(args.includes('ExitOnForwardFailure=yes'))
  assert.ok(args.includes('ForwardAgent=no')); assert.equal(args.at(-1), 'root@10.10.10.20')
  for (const change of [{ target: 'dc' }, { host: '10.10.10.14' }, { host: 'untrusted.invalid' }, { user: 'root -o ProxyCommand=bad' }]) assert.throws(() => tunnelArguments({ ...binding, ...change }, 23456))
  for (const port of [22, 65536, '8080', -1]) assert.throws(() => tunnelArguments(binding, port))
})

test('DC GUI accepts only exact reviewed native operator/project fixture', async () => {
  const { validateDcFixture } = await import('./contract.mjs')
  const r = { ...request(), target: 'dc', dcFixtureSha256: 'c'.repeat(64), personas: [{ ...request().personas[0], id: 'platform-admin', accountType: 1 }] }
  const fixture = { schema: 1, target: 'dc', status: 'PLAN_EXISTING_PROJECT',
    transport: { target: 'dc', sshHost: '10.10.10.14', hostKeyFingerprint: 'SHA256:ibF5v8VUj3Iawmgn/czLeJK7zUAM2kIqIJdzV04uFPw', strictHostVerification: true, listenerOwnerVerified: true },
    operator: { accountType: 1, userId: uuid, accountId: uuid, domainId: uuid, username: 'observed-operator', loginDomain: '/' },
    persona: r.personas[0], selectedProject: { projectId: uuid, projectName: 'Disposable project', domainId: uuid, state: 'Active' } }
  assert.equal(validateDcFixture(r, fixture, 'observed-operator'), '/')
  for (const mutate of [f => { f.target = 'dr' }, f => { f.status = 'PLAN_CREATE_REQUIRES_REVIEW' }, f => { f.operator.accountType = 0 }, f => { f.operator.username = 'someone-else' }, f => { f.transport.sshHost = '10.10.10.20' }, f => { f.transport.listenerOwnerVerified = false }, f => { f.persona.projectName = 'other' }, f => { f.selectedProject.domainId = '22222222-2222-4222-8222-222222222222' }]) {
    const changed = structuredClone(fixture); mutate(changed)
    assert.throws(() => validateDcFixture(r, changed, 'observed-operator'))
  }
  assert.throws(() => validateDcFixture({ ...r, dcFixtureSha256: null }, fixture, 'observed-operator'))
  assert.throws(() => validateDcFixture({ ...r, personas: [{ ...r.personas[0], id: 'operator' }] }, fixture, 'observed-operator'))
})

test('credential delivery is fenced by fresh exact target, PID, start and listener proof', async () => {
  const { withVerifiedCredentialTransport } = await import('./contract.mjs')
  for (const target of ['dc', 'dr']) {
    const proof = { schema: 1, target, sshHost: target === 'dc' ? '10.10.10.14' : '10.10.10.20', remoteLoopbackPort: 8080, processId: 321, processStartedAt: 1770000000000, localLoopbackPort: 19876, strictHostVerification: true, listenerOwnerVerified: true, processPathVerified: true }
    let delivered = 0; let checked = 0
    const tunnel = { proof, alive: () => true, assertReady: async () => { checked++; return { ...proof } } }
    assert.equal(await withVerifiedCredentialTransport(tunnel, target, () => { delivered++; return 'sent' }), 'sent')
    assert.equal(delivered, 1); assert.equal(checked, 1)
    for (const change of [{ target: 'other' }, { sshHost: 'untrusted' }, { processId: 322 }, { processStartedAt: proof.processStartedAt + 1 }, { localLoopbackPort: 19877 }, { remoteLoopbackPort: 22 }, { listenerOwnerVerified: false }, { processPathVerified: false }]) {
      delivered = 0
      await assert.rejects(withVerifiedCredentialTransport({ ...tunnel, assertReady: async () => ({ ...proof, ...change }) }, target, () => { delivered++ }))
      assert.equal(delivered, 0, JSON.stringify(change))
    }
    delivered = 0
    await assert.rejects(withVerifiedCredentialTransport({ ...tunnel, alive: () => false }, target, () => { delivered++ }))
    await assert.rejects(withVerifiedCredentialTransport({ ...tunnel, assertReady: async () => { throw new Error('inspection failed') } }, target, () => { delivered++ }))
    assert.equal(delivered, 0)
  }
})

test('SSH failure classifier exposes only bounded categories, never sensitive text', async () => {
  const { classifySshFailure, validateListenerProof } = await import('./owned-tunnel.mjs')
  for (const [text, expected] of [
    ['ssh_askpass: posix_spawnp: No such file or directory', 'ASKPASS_LAUNCH_FAILED'],
    ['Host key verification failed.', 'HOSTKEY_REJECTED'],
    ['bind [127.0.0.1]:19876: Address already in use', 'FORWARD_BIND_FAILED'],
    ["Can't open user config file private/path: No such file or directory", 'CONFIG_PATH_FAILED'],
    ['root@10.10.10.14: Permission denied (password).', 'AUTH_REJECTED'],
    ['private unexpected text password=do-not-print', 'UNKNOWN']
  ]) assert.equal(classifySshFailure(text), expected)
  assert.throws(() => validateListenerProof({ schema: 1 }, {}, 1, 12345, Date.now()))
})
