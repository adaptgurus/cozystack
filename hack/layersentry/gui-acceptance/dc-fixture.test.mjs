import test from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import http from 'node:http'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { dcTunnelArguments, verifyDcHostKey, validateDcListenerProof, DC_FINGERPRINT, ASKPASS } from './dc-tunnel.mjs'
import { publicOperator, publicProject, makePlan, applyPlan, observe, journalStore, signedBody, nativeApi } from './dc-fixture.mjs'

const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
const requestId = id(1)
const username = 'fixture-admin'
const user = { id: id(2), username, account: 'fixture-account', accountid: id(3), accounttype: 1, domainid: id(4), state: 'enabled', apikey: 'PRIVATE_API_KEY', secretkey: 'PRIVATE_API_SECRET', email: 'PRIVATE_EMAIL' }
const project = { id: id(5), name: 'observed-project', domainid: id(4), state: 'Active', displaytext: 'Observed fixture', owner: [{ account: user.account, userid: user.id }] }
function apiFixture (projects = [], createResult = { jobid: id(6), id: id(7) }) {
  const calls = []
  const api = async (command, parameters) => {
    calls.push({ command, parameters })
    if (command === 'getUser') return { user }
    if (command === 'listDomains') return { count: 1, domain: [{ id: id(4), name: 'ROOT', level: 0 }] }
    if (command === 'listProjects') return { count: projects.length, project: projects }
    if (command === 'createProject') { if (createResult instanceof Error) throw createResult; return createResult }
    if (command === 'queryAsyncJobResult') return { jobstatus: 1 }
    throw new Error('UNEXPECTED_COMMAND')
  }
  return { api, calls }
}
function memoryJournal () {
  let entry
  return { exists: () => !!entry, read: () => structuredClone(entry), create: x => { assert.equal(entry, undefined); entry = structuredClone(x) }, update: x => { entry = structuredClone(x) } }
}
const planSha = 'a'.repeat(64)

test('DC arguments bind one target/forward, one password prompt, strict known hosts and no shell command', () => {
  const binding = { target: 'dc', host: '10.10.10.14', user: 'root', knownHostsFile: 'C:\\private path\\known_hosts', askPassFile: 'helper', passwordFile: 'password.json' }
  const args = dcTunnelArguments(binding, 18342)
  for (const value of ['-N', '-T', 'NumberOfPasswordPrompts=1', 'StrictHostKeyChecking=yes', 'ForwardAgent=no', 'ExitOnForwardFailure=yes', '127.0.0.1:18342:127.0.0.1:8080']) assert.ok(args.includes(value))
  assert.equal(args.at(-1), 'root@10.10.10.14')
  assert.ok(!args.join(' ').includes('password.json'))
  assert.throws(() => dcTunnelArguments({ ...binding, host: '10.10.10.20' }, 18342))
  assert.throws(() => dcTunnelArguments(binding, 0))
  assert.ok(ASKPASS.includes('GetEnvironmentVariable(\'ROCKY_PASSWORD\')'))
})

test('DC exact OOB host key required, no different target or alternative generated key', () => {
  const type = Buffer.from('ssh-ed25519'); const key = Buffer.alloc(32, 1)
  const blob = Buffer.concat([Buffer.from([0, 0, 0, 11]), type, Buffer.from([0, 0, 0, 32]), key]).toString('base64')
  assert.throws(() => verifyDcHostKey('10.10.10.14 ssh-ed25519 ' + blob), /FINGERPRINT_MISMATCH/)
  assert.throws(() => verifyDcHostKey('10.10.10.20 ssh-ed25519 ' + blob), /SCOPE_INVALID/)
  assert.throws(() => verifyDcHostKey('10.10.10.14 ssh-ed25519 AAAA'), /FORMAT_INVALID/)
  assert.equal(verifyDcHostKey('10.10.10.14 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBm79pqXi9hxDir8aG17FrN3itDTHLaPbad98QXAvlL2'), DC_FINGERPRINT)
})

test('listener proof rejects foreign PID, stale process and absent executable proof', () => {
  const proof = { schema: 1, target: 'dc', sshHost: '10.10.10.14', remoteLoopbackPort: 8080, localLoopbackPort: 18342, processId: 500, processStartedAt: 10000, listenerOwnerVerified: true, processPathVerified: true }
  assert.deepEqual(validateDcListenerProof(proof, 500, 18342, 10000), proof)
  for (const change of [{ processId: 501 }, { processStartedAt: 1 }, { processPathVerified: false }, { localLoopbackPort: 18343 }, { listenerOwnerVerified: false }]) assert.throws(() => validateDcListenerProof({ ...proof, ...change }, 500, 18342, 10000))
})

test('native user evidence excludes raw API keys, emails and guessed identities', () => {
  const value = publicOperator({ user }, username)
  assert.equal(value.userId, user.id); assert.equal(value.accountType, 1)
  assert.ok(!JSON.stringify(value).includes('PRIVATE'))
  assert.throws(() => publicOperator({ user }, 'different'))
  assert.throws(() => publicOperator({ user: { ...user, accounttype: 0 } }, username))
  assert.throws(() => publicOperator({ user: { ...user, state: 'disabled' } }, username))
})

test('Plan uses real active owned project and never mutates', async () => {
  const { api, calls } = apiFixture([project])
  const plan = await makePlan(api, username, 'API', requestId)
  assert.equal(plan.selectedProject.projectId, project.id)
  assert.equal(plan.proposal, null)
  assert.equal(plan.operator.loginDomain, '/')
  assert.equal(plan.persona.expectedUserId, user.id)
  assert.equal(plan.persona.projectId, project.id)
  assert.equal(plan.mutationPerformed, false)
  assert.ok(calls.every(x => x.command !== 'createProject'))
  assert.ok(!JSON.stringify(plan).includes('PRIVATE'))
})

test('foreign or inactive project never substitutes for owned active identity', async () => {
  const { api } = apiFixture([{ ...project, domainid: id(9) }, { ...project, state: 'Disabled' }])
  const plan = await makePlan(api, username, 'API', requestId)
  assert.equal(plan.selectedProject, null)
  assert.equal(plan.proposal.name, 'ls-gui-dc-' + requestId)
  assert.equal(plan.proposal.userid, user.id)
  assert.ok(!Object.hasOwn(plan.proposal, 'id'))
  assert.throws(() => publicProject({ ...project, owner: [{ account: 'foreign' }] }, plan.operator))
})

test('truncated list and unverified root login domain block Plan', async () => {
  const fixture = apiFixture()
  for (const command of ['listDomains', 'listProjects']) {
    const api = async (name, params) => name === command ? (name === 'listDomains' ? { count: 1, domain: [{ id: id(4), name: 'child', level: 1 }] } : { count: 101, project: [] }) : fixture.api(name, params)
    await assert.rejects(makePlan(api, username, 'API', requestId))
  }
})

test('Apply performs exactly one native create with explicit observed ownership; retry forbidden', async () => {
  const { api, calls } = apiFixture()
  const plan = await makePlan(api, username, 'API', requestId)
  const journal = memoryJournal()
  const value = await applyPlan(api, plan, planSha, username, 'API', journal)
  assert.equal(value.status, 'SUBMITTED'); assert.equal(value.jobId, id(6))
  await assert.rejects(applyPlan(api, plan, planSha, username, 'API', journal), /ALREADY_ATTEMPTED/)
  assert.equal(calls.filter(x => x.command === 'createProject').length, 1)
  assert.deepEqual(calls.find(x => x.command === 'createProject').parameters, { name: plan.proposal.name, displaytext: plan.proposal.displaytext, accountid: user.accountid, domainid: user.domainid, userid: user.id })
})

test('lost response leaves durable UNKNOWN and cannot replay create', async () => {
  const { api, calls } = apiFixture([], new Error('PRIVATE_SERVER_DETAIL'))
  const plan = await makePlan(api, username, 'API', requestId)
  const journal = memoryJournal()
  const value = await applyPlan(api, plan, planSha, username, 'API', journal)
  assert.equal(value.status, 'UNKNOWN')
  assert.ok(!JSON.stringify(value).includes('PRIVATE_SERVER_DETAIL'))
  await assert.rejects(applyPlan(api, plan, planSha, username, 'API', journal))
  assert.equal(calls.filter(x => x.command === 'createProject').length, 1)
})

test('plan drift and caller extra parameters are rejected before durable intent', async () => {
  const { api } = apiFixture()
  const plan = await makePlan(api, username, 'API', requestId)
  const journal = memoryJournal()
  await assert.rejects(applyPlan(apiFixture([project]).api, plan, planSha, username, 'API', journal), /PLAN_DRIFT/)
  await assert.rejects(applyPlan(api, { ...plan, proposal: { ...plan.proposal, account: 'foreign' } }, planSha, username, 'API', journal))
  assert.equal(journal.exists(), false)
})

test('Observe correlates actual project UUID/name/ownership without another create', async () => {
  const fixture = apiFixture()
  const plan = await makePlan(fixture.api, username, 'API', requestId)
  const journal = memoryJournal()
  await applyPlan(fixture.api, plan, planSha, username, 'API', journal)
  const observed = apiFixture([{ ...project, id: id(7), name: plan.proposal.name, displaytext: plan.proposal.displaytext }])
  const result = await observe(observed.api, plan, planSha, username, 'API', journal)
  assert.equal(result.status, 'FIXTURE_OBSERVED_GUI_NOT_TESTED')
  assert.equal(result.persona.expectedUserId, user.id)
  assert.ok(!observed.calls.some(x => x.command === 'createProject'))
  await assert.rejects(observe(observed.api, plan, 'b'.repeat(64), username, 'API', journal), /JOURNAL_BINDING/)
})

test('durable journal persists exclusive intent across reopen and rejects hardlink replacement', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dc-gui-journal-test-'))
  const previous = process.env.LAYERSENTRY_GUI_ACL_VERIFIED
  process.env.LAYERSENTRY_GUI_ACL_VERIFIED = '1'
  try {
    const journal = journalStore(directory, requestId)
    journal.create({ status: 'SUBMISSION_STARTED' })
    const reopened = journalStore(directory, requestId)
    assert.equal(reopened.read().status, 'SUBMISSION_STARTED')
    assert.throws(() => reopened.create({ status: 'REPLAY' }))
    fs.linkSync(path.join(directory, requestId + '.json'), path.join(directory, 'alias'))
    assert.throws(() => reopened.update({ status: 'REPLACED' }))
  } finally { fs.rmSync(directory, { recursive: true, force: true }); if (previous === undefined) delete process.env.LAYERSENTRY_GUI_ACL_VERIFIED; else process.env.LAYERSENTRY_GUI_ACL_VERIFIED = previous }
})

test('API command boundary prevents login or unreviewed mutation before transport use', async () => {
  let checks = 0
  const api = nativeApi({ assertReady: async () => { checks++ } }, { apiKey: 'API', apiSecret: 'SECRET' }, false)
  await assert.rejects(api('createProject', {}), /FORBIDDEN/)
  await assert.rejects(api('deleteProject', {}), /FORBIDDEN/)
  await assert.rejects(api('login', {}), /FORBIDDEN/)
  assert.equal(checks, 0)
})

test('native signing encodes spaces and reserved bytes without placing credentials in endpoint', () => {
  const body = signedBody('listProjects', { name: "Fixture !'()* +" }, 'API', 'SECRET')
  assert.ok(body.includes('name=Fixture%20%21%27%28%29%2A%20%2B'))
  const encoded = body.split('&signature=')[0]
  assert.equal(decodeURIComponent(body.split('&signature=')[1]), crypto.createHmac('sha1', 'SECRET').update(encoded.toLowerCase()).digest('base64'))
  assert.ok(!body.includes('SECRET'))
})


test('native API sends signed POST only through owned loopback and does not follow redirect', async () => {
  let requests = 0
  const server = http.createServer((request, response) => {
    requests++
    assert.equal(request.method, 'POST'); assert.equal(request.url, '/client/api')
    response.writeHead(302, { Location: 'http://foreign.invalid/client/api' }); response.end()
  })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  let checked = 0
  const tunnel = { assertReady: async () => { checked++ }, alive: () => true, base: `http://127.0.0.1:${server.address().port}/client/` }
  try {
    await assert.rejects(nativeApi(tunnel, { apiKey: 'API', apiSecret: 'SECRET' }, false)('listProjects'), /RESPONSE_REJECTED/)
    assert.equal(requests, 1); assert.equal(checked, 1)
  } finally { await new Promise(resolve => server.close(resolve)) }
})

test('actual PowerShell listener proof rejects wrong owner and inspection failure', { skip: !process.env.LAYERSENTRY_TEST_PWSH }, () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dc-gui-listener-test-'))
  const source = fs.readFileSync(new URL('./dc-listener-proof.ps1', import.meta.url), 'utf8')
  try {
    for (const scenario of ['valid', 'valid-dr', 'foreign', 'query-failure', 'absence-query-failure', 'wrong-path', 'stale-process']) {
      const script = path.join(directory, scenario + '.ps1')
      const start = Date.now()
      const mock = `$env:SystemRoot='/mock/windows'
function Get-Process { param($Id,$ErrorAction) [pscustomobject]@{Path=(Join-Path $env:SystemRoot '${scenario === 'wrong-path' ? 'foreign.exe' : 'System32\\OpenSSH\\ssh.exe'}');StartTime=[DateTimeOffset]::FromUnixTimeMilliseconds(${scenario === 'stale-process' ? start - 60000 : start}).UtcDateTime} }
function Get-NetTCPConnection { param($ErrorAction) ${scenario.includes('query-failure') ? "throw 'denied'" : `[pscustomobject]@{State='Listen';LocalPort=18342;LocalAddress='127.0.0.1';OwningProcess=${scenario === 'foreign' ? 501 : 500}}`} }
`
      // Functions are defined before invoking the exact source in its own script scope.
      const original = path.join(directory, 'proof.ps1'); fs.writeFileSync(original, source)
      fs.writeFileSync(script, mock + `& '${original.replaceAll("'", "''")}' -Target ${scenario === 'valid-dr' ? 'dr' : 'dc'} -SshProcessId 500 -LocalPort 18342 -StartedAfterEpochMs ${start} ${scenario === 'absence-query-failure' ? '-ExpectAbsent' : ''}
exit $LASTEXITCODE
`)
      if (scenario.startsWith('valid')) {
        const result = execFileSync(process.env.LAYERSENTRY_TEST_PWSH, ['-NoProfile', '-NonInteractive', '-File', script], { encoding: 'utf8' })
        assert.equal(JSON.parse(result).listenerOwnerVerified, true)
        assert.equal(JSON.parse(result).sshHost, scenario === 'valid-dr' ? '10.10.10.20' : '10.10.10.14')
      } else assert.throws(() => execFileSync(process.env.LAYERSENTRY_TEST_PWSH, ['-NoProfile', '-NonInteractive', '-File', script], { stdio: 'pipe' }))
    }
  } finally { fs.rmSync(directory, { recursive: true, force: true }) }
})


test('concurrent Apply attempts cannot issue two create requests', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'dc-gui-concurrency-test-'))
  const previous = process.env.LAYERSENTRY_GUI_ACL_VERIFIED
  process.env.LAYERSENTRY_GUI_ACL_VERIFIED = '1'
  try {
    const { api, calls } = apiFixture()
    const plan = await makePlan(api, username, 'API', requestId)
    const attempts = await Promise.allSettled([1, 2].map(() => applyPlan(api, plan, planSha, username, 'API', journalStore(directory, requestId))))
    assert.equal(attempts.filter(x => x.status === 'fulfilled').length, 1)
    assert.equal(calls.filter(x => x.command === 'createProject').length, 1)
  } finally { fs.rmSync(directory, { recursive: true, force: true }); if (previous === undefined) delete process.env.LAYERSENTRY_GUI_ACL_VERIFIED; else process.env.LAYERSENTRY_GUI_ACL_VERIFIED = previous }
})
