import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { openDcTunnel, DC_FINGERPRINT } from './dc-tunnel.mjs'
import { readProtectedCredentials, readProtectedBytes, publicFailure, requireThat } from './contract.mjs'

const uuid = x => typeof x === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(x)
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const encode = value => encodeURIComponent(String(value)).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase())
const publicText = x => typeof x === 'string' && x.length > 0 && x.length <= 200 && !/[\x00-\x1f\x7f]/.test(x)

export function signedBody (command, parameters, key, secret) {
  const values = { ...parameters, command, apikey: key, response: 'json' }
  const encoded = Object.keys(values).sort().map(k => encode(k) + '=' + encode(values[k])).join('&')
  const signature = crypto.createHmac('sha1', secret).update(encoded.toLowerCase()).digest('base64')
  return encoded + '&signature=' + encode(signature)
}

export function nativeApi (tunnel, credential, allowCreate) {
  return async (command, parameters = {}) => {
    requireThat(['getUser', 'listDomains', 'listProjects', 'queryAsyncJobResult'].includes(command) || (allowCreate && command === 'createProject'), 'DC_API_COMMAND_FORBIDDEN')
    await tunnel.assertReady()
    const url = new URL('api', tunnel.base)
    requireThat(url.hostname === '127.0.0.1' && url.protocol === 'http:' && url.pathname === '/client/api' && !url.search, 'DC_API_LOOPBACK_REQUIRED')
    const body = signedBody(command, parameters, credential.apiKey, credential.apiSecret)
    return new Promise((resolve, reject) => {
      let timer
      const request = http.request(url, { method: 'POST', agent: false, headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } }, response => {
        let raw = ''
        response.setEncoding('utf8')
        response.on('data', chunk => { raw += chunk; if (Buffer.byteLength(raw) > 1048576) request.destroy(new Error('DC_API_RESPONSE_TOO_LARGE')) })
        response.on('end', () => {
          clearTimeout(timer)
          try {
            requireThat(response.statusCode === 200 && tunnel.alive(), 'DC_API_RESPONSE_REJECTED')
            const value = JSON.parse(raw)[command.toLowerCase() + 'response']
            requireThat(value && typeof value === 'object' && !Array.isArray(value) && !Object.hasOwn(value, 'errorcode'), 'DC_API_COMMAND_REJECTED')
            resolve(value)
          } catch { reject(new Error('DC_API_RESPONSE_REJECTED')) }
        })
        response.on('error', () => { clearTimeout(timer); reject(new Error('DC_API_TRANSPORT_FAILED')) })
      })
      timer = setTimeout(() => request.destroy(new Error('DC_API_TIMEOUT')), 20000)
      request.on('error', () => { clearTimeout(timer); reject(new Error('DC_API_TRANSPORT_FAILED')) })
      request.end(body)
    })
  }
}

export function publicOperator (response, username) {
  const user = response?.user
  requireThat(user && user.username === username && user.state === 'enabled' && uuid(user.id) && uuid(user.accountid) && uuid(user.domainid) && publicText(user.account) && user.accounttype === 1, 'DC_NATIVE_OPERATOR_SCOPE_UNVERIFIED')
  return { userId: user.id, username: user.username, accountId: user.accountid, accountName: user.account, accountType: user.accounttype, domainId: user.domainid, personaId: 'platform-admin' }
}

function list (response, key) {
  const rows = response[key] ?? []
  requireThat(Array.isArray(rows) && rows.length <= 100 && Number.isInteger(response.count ?? 0) && (response.count ?? 0) === rows.length, 'DC_API_LIST_INCOMPLETE')
  return rows
}

export function publicProject (value, operator, requireActive = true) {
  requireThat(uuid(value?.id) && publicText(value.name) && value.domainid === operator.domainId && (!requireActive || value.state === 'Active'), 'DC_PROJECT_SCOPE_UNVERIFIED')
  requireThat(Array.isArray(value.owner) && value.owner.some(owner => owner.account === operator.accountName && (!owner.userid || owner.userid === operator.userId)), 'DC_PROJECT_OWNER_UNVERIFIED')
  return { projectId: value.id, projectName: value.name, domainId: value.domainid, state: value.state, displayText: value.displaytext ?? null }
}

export async function makePlan (api, username, apiKey, requestId, requestedProjectId = null) {
  requireThat(uuid(requestId) && publicText(username) && (!requestedProjectId || uuid(requestedProjectId)), 'DC_FIXTURE_REQUEST_INVALID')
  const operator = publicOperator(await api('getUser', { userapikey: apiKey }), username)
  const domains = list(await api('listDomains', { id: operator.domainId, page: 1, pagesize: 100 }), 'domain')
  requireThat(domains.length === 1 && domains[0].id === operator.domainId && domains[0].level === 0 && domains[0].name === 'ROOT', 'DC_ROOT_LOGIN_DOMAIN_UNVERIFIED')
  operator.loginDomain = '/'
  const rows = list(await api('listProjects', { account: operator.accountName, domainid: operator.domainId, listall: true, details: 'min', page: 1, pagesize: 100 }), 'project')
  const projects = []
  for (const row of rows) {
    if (row.state !== 'Active') continue
    try { projects.push(publicProject(row, operator)) } catch { /* Foreign scope is never selected. */ }
  }
  requireThat(new Set(projects.map(p => p.projectId)).size === projects.length, 'DC_DUPLICATE_PROJECT_IDENTITY')
  projects.sort((a, b) => a.projectId.localeCompare(b.projectId))
  const selected = requestedProjectId ? projects.find(p => p.projectId === requestedProjectId) : projects[0]
  requireThat(!requestedProjectId || selected, 'DC_REQUESTED_PROJECT_NOT_OWNED_ACTIVE')
  const name = 'ls-gui-dc-' + requestId
  requireThat(!rows.some(row => row.name === name), 'DC_FIXTURE_NAME_ALREADY_PRESENT')
  return { schema: 1, target: 'dc', sshHost: '10.10.10.14', hostKeyFingerprint: DC_FINGERPRINT, status: selected ? 'PLAN_EXISTING_PROJECT' : 'PLAN_CREATE_REQUIRES_REVIEW', requestId, operator, selectedProject: selected ?? null,
    proposal: selected ? null : { command: 'createProject', name, displaytext: 'LayerSentry DC GUI fixture ' + requestId + ' user ' + operator.userId, accountid: operator.accountId, domainid: operator.domainId, userid: operator.userId },
    persona: selected ? { id: operator.personaId, expectedUserId: operator.userId, accountType: operator.accountType, projectId: selected.projectId, projectName: selected.projectName } : null,
    mutationPerformed: false, personaCoverage: { 'platform-admin': 'IDENTITY_OBSERVED_GUI_NOT_TESTED', 'department-admin': 'NOT_TESTED', operator: 'NOT_TESTED', auditor: 'NOT_TESTED' } }
}

export function journalStore (directory, requestId) {
  requireThat(uuid(requestId) && process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'DC_JOURNAL_TRUST_REQUIRED')
  let current = path.parse(path.resolve(directory)).root
  for (const part of path.resolve(directory).slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part)
    requireThat(!fs.lstatSync(current).isSymbolicLink(), 'DC_JOURNAL_LINK_REJECTED')
  }
  const file = path.join(directory, requestId + '.json')
  return {
    exists: () => fs.existsSync(file),
    read: () => JSON.parse(readProtectedBytes(file).toString('utf8')),
    create: value => {
      const fd = fs.openSync(file, 'wx', 0o600)
      try { fs.writeFileSync(fd, JSON.stringify(value) + '\n'); fs.fsyncSync(fd) } finally { fs.closeSync(fd) }
    },
    update: value => {
      // Reject links/hardlinks before replacement; no secret is written to the durable journal.
      readProtectedBytes(file)
      const temporary = file + '.' + crypto.randomUUID() + '.tmp'
      const fd = fs.openSync(temporary, 'wx', 0o600)
      try { fs.writeFileSync(fd, JSON.stringify(value) + '\n'); fs.fsyncSync(fd) } finally { fs.closeSync(fd) }
      fs.renameSync(temporary, file)
    }
  }
}

function validatePlan (plan) {
  requireThat(plan?.schema === 1 && plan.target === 'dc' && plan.sshHost === '10.10.10.14' && plan.hostKeyFingerprint === DC_FINGERPRINT && uuid(plan.requestId) && plan.mutationPerformed === false, 'DC_PLAN_BINDING_INVALID')
  requireThat(plan.status === 'PLAN_CREATE_REQUIRES_REVIEW' && plan.selectedProject === null && plan.proposal?.command === 'createProject', 'DC_CREATE_PLAN_REQUIRED')
  const p = plan.proposal
  requireThat(p.name === 'ls-gui-dc-' + plan.requestId && p.displaytext === 'LayerSentry DC GUI fixture ' + plan.requestId + ' user ' + plan.operator.userId && p.accountid === plan.operator.accountId && p.domainid === plan.operator.domainId && p.userid === plan.operator.userId, 'DC_CREATE_PLAN_SCOPE_INVALID')
  requireThat(Object.keys(p).sort().join(',') === 'accountid,command,displaytext,domainid,name,userid', 'DC_CREATE_PLAN_EXTRA_PARAMETERS')
}

export async function applyPlan (api, plan, planSha256, username, apiKey, journal) {
  validatePlan(plan)
  requireThat(/^[a-f0-9]{64}$/.test(planSha256) && !journal.exists(), 'DC_CREATE_ALREADY_ATTEMPTED')
  const fresh = await makePlan(api, username, apiKey, plan.requestId)
  requireThat(JSON.stringify(fresh.operator) === JSON.stringify(plan.operator) && fresh.status === plan.status && JSON.stringify(fresh.proposal) === JSON.stringify(plan.proposal), 'DC_PLAN_DRIFT')
  const entry = { schema: 1, target: 'dc', requestId: plan.requestId, planSha256, operator: plan.operator, proposal: plan.proposal, status: 'SUBMISSION_STARTED', jobId: null, projectId: null, mutationMayHaveOccurred: true }
  // Exclusive durable write before the only create call; every existing journal blocks replay.
  journal.create(entry)
  try {
    const { command, ...parameters } = plan.proposal
    const response = await api(command, parameters)
    requireThat(uuid(response.jobid), 'DC_CREATE_RESPONSE_AMBIGUOUS')
    entry.jobId = response.jobid
    if (response.id) { requireThat(uuid(response.id), 'DC_CREATE_RESPONSE_AMBIGUOUS'); entry.projectId = response.id }
    entry.status = 'SUBMITTED'
    journal.update(entry)
    return entry
  } catch {
    entry.status = 'UNKNOWN'
    journal.update(entry)
    return entry
  }
}

export async function observe (api, plan, planSha256, username, apiKey, journal) {
  validatePlan(plan)
  const entry = journal.read()
  requireThat(entry.target === 'dc' && entry.requestId === plan.requestId && entry.planSha256 === planSha256 && JSON.stringify(entry.operator) === JSON.stringify(plan.operator) && JSON.stringify(entry.proposal) === JSON.stringify(plan.proposal), 'DC_JOURNAL_BINDING_INVALID')
  const operator = publicOperator(await api('getUser', { userapikey: apiKey }), username)
  requireThat(operator.userId === plan.operator.userId && operator.accountId === plan.operator.accountId && operator.domainId === plan.operator.domainId, 'DC_OBSERVATION_OPERATOR_CHANGED')
  if (entry.jobId) {
    requireThat(uuid(entry.jobId), 'DC_JOURNAL_JOB_INVALID')
    const job = await api('queryAsyncJobResult', { jobid: entry.jobId })
    requireThat([0, 1, 2].includes(job.jobstatus), 'DC_JOB_RESPONSE_INVALID')
    if (job.jobstatus === 0) return { ...entry, status: 'PENDING' }
    if (job.jobstatus === 2) { entry.status = 'FAILED_REQUIRES_REVIEW'; journal.update(entry); return entry }
  }
  const rows = list(await api('listProjects', { name: plan.proposal.name, account: operator.accountName, domainid: operator.domainId, listall: true, details: 'min', page: 1, pagesize: 100 }), 'project')
  requireThat(rows.length <= 1, 'DC_FIXTURE_IDENTITY_AMBIGUOUS')
  if (!rows.length) return { ...entry, status: 'UNKNOWN' }
  const project = publicProject(rows[0], operator)
  requireThat(project.projectName === plan.proposal.name && project.displayText === plan.proposal.displaytext && (!entry.projectId || entry.projectId === project.projectId), 'DC_FIXTURE_CORRELATION_FAILED')
  entry.status = 'FIXTURE_OBSERVED_GUI_NOT_TESTED'
  entry.projectId = project.projectId
  entry.project = project
  entry.persona = { id: operator.personaId, expectedUserId: operator.userId, accountType: operator.accountType, projectId: project.projectId, projectName: project.projectName }
  journal.update(entry)
  return entry
}

async function main () {
  const [mode, bindingPath, credentialsPath, output, requestOrPlan, expectedSha, journalDirectory] = process.argv.slice(2)
  requireThat(['Plan', 'Apply', 'Observe'].includes(mode), 'DC_FIXTURE_MODE_INVALID')
  const credential = readProtectedCredentials(credentialsPath)
  requireThat(publicText(credential.username) && typeof credential.apiKey === 'string' && credential.apiKey.length > 0 && typeof credential.apiSecret === 'string' && credential.apiSecret.length > 0, 'DC_API_CREDENTIALS_REQUIRED')
  let tunnel
  try {
    tunnel = await openDcTunnel(JSON.parse(readProtectedBytes(bindingPath).toString('utf8')))
    const api = nativeApi(tunnel, credential, mode === 'Apply')
    let result
    if (mode === 'Plan') result = await makePlan(api, credential.username, credential.apiKey, requestOrPlan)
    else {
      const bytes = readProtectedBytes(requestOrPlan)
      requireThat(hash(bytes) === expectedSha, 'DC_PLAN_HASH_MISMATCH')
      const plan = JSON.parse(bytes)
      const journal = journalStore(journalDirectory, plan.requestId)
      result = mode === 'Apply' ? await applyPlan(api, plan, expectedSha, credential.username, credential.apiKey, journal) : await observe(api, plan, expectedSha, credential.username, credential.apiKey, journal)
    }
    result.transport = tunnel.proof
    const fd = fs.openSync(output, 'wx', 0o600)
    try { fs.writeFileSync(fd, JSON.stringify(result, null, 2) + '\n'); fs.fsyncSync(fd) } finally { fs.closeSync(fd) }
  } catch (error) {
    // A pre-API launch failure still needs a public receipt; all fields below
    // are local allowlisted facts, not SSH stderr or native response content.
    if (error.tunnelDiagnostic) {
      fs.writeFileSync(output, JSON.stringify({ schema: 1, target: 'dc', status: 'TRANSPORT_FAILED', reason: publicFailure(error), mutationPerformed: false, transportDiagnostic: error.tunnelDiagnostic }, null, 2) + '\n', { mode: 0o600, flag: 'wx' })
    }
    throw error
  } finally { credential.apiSecret = null; credential.apiKey = null; if (tunnel) await tunnel.close() }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => { console.error(publicFailure(error)); process.exitCode = 1 })
}
