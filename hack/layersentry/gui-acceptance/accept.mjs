import fs from 'node:fs'
import crypto from 'node:crypto'
import path from 'node:path'
import { openDrTunnel } from './tunnel.mjs'
import { openDcTunnel } from './dc-tunnel.mjs'
import { validateRequest, validateDcFixture, withVerifiedCredentialTransport, readProtectedCredentials, readProtectedBytes, requireThat, classifyGate, allowedRequest, publicFailure } from './contract.mjs'

// No Playwright test reporter, trace, video, HAR, console forwarding, raw DOM,
// request headers/bodies, cookies or storageState are written to evidence.
const [requestPath, inventoryPath, credentialPath, output, tunnelBindingPath] = process.argv.slice(2)
const result = { schema: 1, status: 'NOT_TESTED', moduleCompletionApproved: false, checks: [], personas: [], lifecycle: { kubernetes: 'NOT_TESTED', dbaas: 'NOT_TESTED', apaas: 'NOT_TESTED', drReplication: 'NOT_TESTED' } }
let out; let tunnel; let authenticationFailed = false; const authenticatedPersonas = new Set()
const timeout = 20000
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex')
const deadline = Date.now() + 12 * 60 * 1000
const remaining = () => { requireThat(Date.now() < deadline, 'GUI_DEADLINE_EXCEEDED'); return Math.min(timeout, deadline - Date.now()) }
const check = (name, status = 'PASS', reason) => result.checks.push({ name, status, ...(reason ? { reason } : {}) })

async function getBounded (client, url) {
  const response = await client.get(url, { timeout: remaining(), maxRedirects: 0, failOnStatusCode: false })
  requireThat(response.status() === 200, 'SERVED_ASSET_UNAVAILABLE')
  const declared = Number(response.headers()['content-length'] || 0)
  requireThat(declared <= 32 * 1024 * 1024, 'SERVED_ASSET_TOO_LARGE')
  const bytes = await response.body()
  requireThat(bytes.length <= 32 * 1024 * 1024, 'SERVED_ASSET_TOO_LARGE')
  await response.dispose()
  return bytes
}

async function backendRead (page, suffix) {
  remaining()
  // Execute native same-origin reads in the authenticated browser. Values stay
  // in process memory; only status/boolean/count projections enter the receipt.
  return page.evaluate(async suffix => {
    const key = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('sessionkey='))?.slice(11)
    if (!key) return { code: 401, body: null }
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 15000)
    try {
      const response = await fetch('/client/layersentry-k8s/v1/kubernetes/' + suffix, {
        cache: 'no-store', redirect: 'error', credentials: 'same-origin', signal: controller.signal,
        headers: { Accept: 'application/json', 'X-LayerSentry-Session-Key': decodeURIComponent(key) }
      })
      const type = response.headers.get('content-type') || ''
      const text = await response.text()
      return { code: response.status, body: type.includes('application/json') && text.length <= 1048576 ? JSON.parse(text) : null }
    } catch { return { code: 0, body: null } } finally { clearTimeout(timer) }
  }, suffix)
}

async function personaChecks (browser, name, base, spec, credentials) {
  const record = { browser: name, persona: spec.id, checks: [], modules: Object.fromEntries(['kubernetes', 'dbaas', 'apaas', 'streaming', 'packages', 'drReplication'].map(key => [key, { status: 'NOT_TESTED', reason: 'GUI_FLOW_NOT_REACHED' }])) }
  result.personas.push(record)
  const observed = (name, status = 'PASS', reason) => record.checks.push({ name, status, ...(reason ? { reason } : {}) })
  const context = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block', acceptDownloads: false })
  let unexpected = 0; let pageErrors = 0; let loginSubmissions = 0
  await context.route('**/*', async route => {
    const req = route.request()
    const endpoint = new URL(req.url())
    if (endpoint.pathname.replace(/\/$/, '') === '/client/api' && req.method() === 'POST' && new URLSearchParams(req.postData() || '').get('command') === 'login') {
      loginSubmissions++
      if (loginSubmissions > 1) { authenticationFailed = true; unexpected++; return route.abort('blockedbyclient') }
    }
    if (!allowedRequest(req.url(), req.method(), req.postData(), new URL(base).origin)) { unexpected++; return route.abort('blockedbyclient') }
    if (endpoint.pathname.replace(/\/$/, '') === '/client/api' && req.method() === 'POST' && new URLSearchParams(req.postData() || '').get('command') === 'login') {
      try { return await withVerifiedCredentialTransport(tunnel, result.target, () => route.continue()) } catch { authenticationFailed = true; unexpected++; return route.abort('blockedbyclient') }
    }
    return route.continue()
  })
  const page = await context.newPage()
  page.setDefaultTimeout(timeout); page.setDefaultNavigationTimeout(timeout)
  page.on('pageerror', () => { pageErrors++ })
  try {
    requireThat(tunnel.alive(), 'STRICT_SSH_TUNNEL_FAILED')
    const secret = credentials[spec.id]
    requireThat(secret && typeof secret.username === 'string' && typeof secret.password === 'string' && secret.password.length > 0 && typeof secret.domain === 'string', 'PERSONA_CREDENTIAL_MISSING')
    await page.goto(base + '#/user/login', { waitUntil: 'domcontentloaded', timeout: remaining() })
    await page.locator('#formLogin input[autocomplete="username"]').fill(secret.username)
    try { await withVerifiedCredentialTransport(tunnel, result.target, () => page.locator('#formLogin input[autocomplete="current-password"]').fill(secret.password)) } catch { authenticationFailed = true; throw new Error('SSH_CREDENTIAL_TRANSPORT_UNVERIFIED') }
    await page.locator('#formLogin input[aria-label="Domain"]').fill(secret.domain)
    const login = page.waitForResponse(response => {
      try { const req = response.request(); return new URLSearchParams(req.postData() || '').get('command') === 'login' } catch { return false }
    }, { timeout: remaining() }).catch(() => null)
    await page.locator('#formLogin button[type="submit"]').click()
    const reply = await login
    if (!reply || reply.status() !== 200) { authenticationFailed = true; throw new Error('GUI_LOGIN_REJECTED') }
    const identity = await reply.json()
    if (identity.loginresponse?.userid !== spec.expectedUserId || typeof identity.loginresponse?.sessionkey !== 'string' || (spec.accountType !== undefined && identity.loginresponse?.type !== String(spec.accountType))) { authenticationFailed = true; throw new Error('GUI_IDENTITY_MISMATCH') }
    await page.locator('#formLogin').waitFor({ state: 'hidden', timeout: remaining() })
    observed('authenticated-gui-login'); authenticatedPersonas.add(spec.id)
    await page.goto(base + '#/kubernetes-data-services', { waitUntil: 'domcontentloaded', timeout: remaining() })
    const root = page.locator('.layersentry-k8s-services')
    try { await root.waitFor({ state: 'visible', timeout: remaining() }) } catch {
      observed('kubernetes-route', 'BLOCKED', 'MODULE_HIDDEN_OR_MISSING')
      record.modules.kubernetes = { status: 'NOT_TESTED', reason: 'MODULE_HIDDEN_OR_MISSING' }
      return
    }
    observed('kubernetes-route')
    const title = root.getByText('Kubernetes & Data Services', { exact: true })
    await title.screenshot({ path: path.join(out, `${name}-${spec.id}-module-title.png`), timeout: remaining() })
    const selection = root.locator('#k8s-project')
    await selection.click()
    const choice = page.getByRole('option', { name: spec.projectName, exact: true })
    // Ant Select's hidden accessibility option may be non-clickable; select
    // the visible matching title and require exact option identity uniqueness.
    const visibleChoice = page.locator('.ant-select-dropdown:not(.ant-select-dropdown-hidden) .ant-select-item-option').filter({ has: page.locator('.ant-select-item-option-content').getByText(spec.projectName, { exact: true }) })
    if (await visibleChoice.count() === 1) await visibleChoice.click()
    else { requireThat(await choice.count() === 1, 'PROJECT_OPTION_NOT_UNIQUE'); await choice.click() }
    await selection.press('Escape')
    // Trigger GUI refresh and observe a real project-bound request, not just
    // dropdown text. A closed backend may prevent cluster reads entirely.
    const readinessResponse = page.waitForResponse(r => new URL(r.url()).pathname.endsWith('/kubernetes/readiness'), { timeout: remaining() }).catch(() => null)
    await root.getByRole('button', { name: 'Refresh', exact: true }).click()
    await readinessResponse
    const readiness = await backendRead(page, 'readiness')
    const gate = classifyGate(readiness.code, readiness.body)
    record.modules.kubernetes = gate
    if (gate.status === 'BLOCKED') {
      requireThat(await root.getByRole('button', { name: 'Create cluster', exact: true }).isDisabled(), 'CREATE_ENABLED_WITH_CLOSED_GATE')
      requireThat(await root.getByText('Cluster provisioning is unavailable', { exact: true }).isVisible(), 'CLOSED_GATE_NOT_VISIBLE')
      observed('closed-provisioning-gate-visible')
    }
    const query = new URLSearchParams({ projectId: spec.projectId }).toString()
    const [clusters, operations, packages] = await Promise.all([
      backendRead(page, 'clusters?' + query), backendRead(page, 'operations?' + query + '&limit=50'), backendRead(page, 'packages?' + query)
    ])
    record.backend = { readinessHttp: readiness.code, clustersHttp: clusters.code, operationsHttp: operations.code, packagesHttp: packages.code }
    if (clusters.code === 200 && Array.isArray(clusters.body?.clusters) && operations.code === 200 && Array.isArray(operations.body?.operations)) {
      requireThat(operations.body.operations.every(op => op.projectId === spec.projectId), 'FOREIGN_OPERATION_VISIBLE')
      const guiRequest = page.waitForResponse(r => {
        const u = new URL(r.url()); return u.pathname.endsWith('/kubernetes/clusters') && u.searchParams.get('projectId') === spec.projectId
      }, { timeout: remaining() }).catch(() => null)
      await root.getByRole('button', { name: 'Refresh', exact: true }).click(); requireThat(await guiRequest, 'PROJECT_SCOPED_GUI_REQUEST_MISSING')
      observed('authenticated-project-scoped-gui-request')
      record.inventory = { clusters: clusters.body.clusters.length, operations: operations.body.operations.length }
      if (clusters.body.clusters.length) {
        const cluster = clusters.body.clusters[0]
        requireThat(typeof cluster.name === 'string', 'INVALID_CLUSTER_RESPONSE')
        await root.getByRole('button', { name: cluster.name, exact: true }).click()
        await root.getByText('Choose a platform-approved package for ' + cluster.name + '. Availability does not mean the package is installed.', { exact: true }).waitFor({ state: 'visible', timeout: remaining() })
        observed('cluster-package-screen')
        record.modules.packages = { status: 'NOT_TESTED', reason: 'PACKAGE_LIFECYCLE_NOT_EXECUTED' }
      } else record.modules.packages = { status: 'NOT_TESTED', reason: 'NO_MANAGED_CLUSTER_FIXTURE' }
    } else observed('project-inventory', 'BLOCKED', 'BACKEND_INVENTORY_UNAVAILABLE')
    if (spec.foreignProjectId) {
      const negative = await backendRead(page, 'clusters?' + new URLSearchParams({ projectId: spec.foreignProjectId }))
      if (negative.code === 403) observed('foreign-project-read-denied')
      else if (negative.code === 0 || negative.code >= 500) observed('foreign-project-read-denied', 'NOT_TESTED', 'BACKEND_UNAVAILABLE')
      else throw new Error('FOREIGN_PROJECT_ACCESS_NOT_DENIED')
    } else observed('foreign-project-read-denied', 'NOT_TESTED', 'NO_FOREIGN_SCOPE_FIXTURE')
    for (const service of ['DBaaS', 'APaaS', 'Streaming']) {
      await root.getByRole('tab', { name: service, exact: true }).click()
      if (await root.getByText(service + ' provisioning is unavailable', { exact: true }).isVisible()) {
        observed(service + '-unavailable-message'); record.modules[service.toLowerCase()] = { status: 'BLOCKED', reason: 'SERVICE_LIFECYCLE_UNAVAILABLE' }
      } else record.modules[service.toLowerCase()] = { status: 'NOT_TESTED', reason: 'NEW_SERVICE_FLOW_REQUIRES_ACCEPTANCE' }
    }
    record.modules.drReplication = { status: 'NOT_TESTED', reason: 'DEDICATED_REPLICATION_ROUTE_NOT_IMPLEMENTED' }

  } catch (error) {
    observed('gui-acceptance', authenticationFailed ? 'NOT_TESTED' : 'FAIL', publicFailure(error))
  } finally {
    // Native logout is the only cleanup mutation. Do not persist the session.
    try {
      const loggedOut = await page.evaluate(async () => {
        const raw = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('sessionkey='))?.slice(11)
        if (!raw) return true
        const response = await fetch('/client/api', { method: 'POST', credentials: 'same-origin', redirect: 'error', signal: AbortSignal.timeout(10000),
          body: new URLSearchParams({ command: 'logout', response: 'json', sessionkey: decodeURIComponent(raw) }) })
        const body = await response.json(); return response.ok && body.logoutresponse?.success === true
      })
      observed('session-logout', loggedOut ? 'PASS' : 'FAIL', loggedOut ? undefined : 'LOGOUT_UNVERIFIED')
    } catch { observed('session-logout', 'FAIL', 'LOGOUT_UNVERIFIED') }
    observed('read-only-network-boundary', unexpected === 0 ? 'PASS' : 'FAIL', unexpected ? 'UNEXPECTED_NETWORK_OR_MUTATION' : undefined)
    observed('no-browser-page-errors', pageErrors === 0 ? 'PASS' : 'FAIL', pageErrors ? 'BROWSER_PAGE_ERROR' : undefined)
    await context.close()
  }
}

try {
  delete process.env.DEBUG; delete process.env.PWDEBUG
  const { chromium, firefox } = await import('playwright')
  const request = JSON.parse(fs.readFileSync(requestPath, 'utf8'))
  validateRequest(request)
  const inventory = JSON.parse(fs.readFileSync(inventoryPath, 'utf8'))
  requireThat(inventory.schema === 1 && inventory.cloudstackUiCommit === request.cloudstackUiCommit && inventory.artifactSha256 === request.artifactSha256, 'INVENTORY_BINDING_MISMATCH')
  requireThat(Array.isArray(inventory.assets) && inventory.assets.length > 0 && inventory.assets.length <= 10000, 'INVALID_ASSET_INVENTORY')
  const credentials = readProtectedCredentials(credentialPath)
  const binding = readProtectedCredentials(tunnelBindingPath)
  requireThat(binding.target === request.target, 'SSH_TARGET_BINDING_REQUIRED')
  const files = request.target === 'dc' ? ['passwordFile', 'askPassFile', 'knownHostsFile', 'nativeFixtureFile'] : ['keyFile', 'knownHostsFile']
  for (const key of files) {
    requireThat(typeof binding[key] === 'string' && path.dirname(path.resolve(binding[key])) === path.dirname(path.resolve(tunnelBindingPath)), 'SSH_TARGET_BINDING_REQUIRED')
    readProtectedBytes(binding[key])
  }
  if (request.target === 'dc') {
    const fixture = readProtectedBytes(binding.nativeFixtureFile)
    requireThat(digest(fixture) === request.dcFixtureSha256, 'DC_FIXTURE_HASH_MISMATCH')
    const domain = validateDcFixture(request, JSON.parse(fixture), credentials['platform-admin']?.username)
    requireThat(credentials['platform-admin']?.domain === domain, 'DC_FIXTURE_LOGIN_DOMAIN_MISMATCH')
  }
  out = path.resolve(output); fs.mkdirSync(out, { mode: 0o700 })
  result.personaCoverage = Object.fromEntries(['platform-admin', 'department-admin', 'operator', 'auditor'].map(id => [id, request.personas.some(p => p.id === id) ? 'PENDING' : 'NOT_TESTED']))
  result.artifactRunId = request.artifactRunId; result.artifactName = request.artifactName
  result.target = request.target; result.cloudstackUiCommit = request.cloudstackUiCommit; result.artifactSha256 = request.artifactSha256
  result.runnerCommit = /^[0-9a-f]{40}$/.test(process.env.GITHUB_SHA || '') ? process.env.GITHUB_SHA : null
  result.workflowRunId = /^\d+$/.test(process.env.GITHUB_RUN_ID || '') ? process.env.GITHUB_RUN_ID : null
  tunnel = request.target === 'dc' ? await openDcTunnel(binding) : await openDrTunnel(binding)
  const base = tunnel.base
  result.security = { transport: 'STRICT_SSH_LOOPBACK', tunnel: tunnel.proof, productionTlsVerified: false, privateStatePersisted: false }
  for (const [name, engine, options] of [['chrome', chromium, { channel: 'chrome' }], ['firefox', firefox, {}]]) {
    if (authenticationFailed) { check(name + '-login', 'NOT_TESTED', 'PRIOR_AUTHENTICATION_FAILURE_NO_RETRY'); continue }
    requireThat(tunnel.alive(), 'STRICT_SSH_TUNNEL_FAILED')
    let browser
    try {
      browser = await engine.launch({ ...options, headless: true, timeout: remaining() })
      check(name + '-launch'); result[name + 'Version'] = browser.version()
      const context = await browser.newContext({ serviceWorkers: 'block' })
      try {
        for (const asset of inventory.assets) {
          requireThat(typeof asset.path === 'string' && /^[A-Za-z0-9_./@+ -]+$/.test(asset.path) && !asset.path.split('/').includes('..') && !asset.path.startsWith('/'), 'INVALID_ASSET_PATH')
          const data = await getBounded(context.request, base + asset.path.split('/').map(encodeURIComponent).join('/'))
          requireThat(data.length === asset.size && digest(data) === asset.sha256, 'SERVED_ARTIFACT_MISMATCH')
        }
        const config = JSON.parse(await getBounded(context.request, base + 'config.json'))
        requireThat(Object.entries(inventory.branding).every(([k, v]) => config[k] === v), 'SERVED_BRANDING_MISMATCH')
        requireThat(config.apiBase === '/client/api' && !config.multipleServer, 'UNAPPROVED_API_ENDPOINT')
        check(name + '-exact-served-artifact')
      } finally { await context.close() }
      for (const persona of request.personas) {
        if (authenticationFailed) break
        if (name === 'firefox' && !authenticatedPersonas.has(persona.id)) { check('firefox-' + persona.id + '-login', 'NOT_TESTED', 'FIRST_BROWSER_AUTHENTICATION_NOT_VERIFIED'); continue }
        await personaChecks(browser, name, base, persona, credentials)
      }
    } catch (error) { check(name + '-acceptance', 'FAIL', publicFailure(error)) } finally { if (browser) await browser.close() }
  }
  await tunnel.close(); check('owned-ssh-tunnel-closed')
  const failed = authenticationFailed || [...result.checks, ...result.personas.flatMap(p => p.checks)].some(c => c.status === 'FAIL')
  result.status = failed ? 'BLOCKED' : 'PARTIAL'
  result.reason = failed ? 'GUI_CHECK_FAILURE' : 'READ_ONLY_GUI_CHECKS_DO_NOT_CERTIFY_MODULE_LIFECYCLES'
  fs.writeFileSync(path.join(out, 'acceptance.json'), JSON.stringify(result, null, 2), { mode: 0o600, flag: 'wx' })
  console.log(JSON.stringify({ status: result.status, moduleCompletionApproved: false }))
  process.exitCode = failed ? 1 : 2
} catch (error) {
  if (out && error.tunnelDiagnostic) {
    result.status = 'BLOCKED'; result.reason = publicFailure(error); result.transportDiagnostic = error.tunnelDiagnostic
    fs.writeFileSync(path.join(out, 'acceptance.json'), JSON.stringify(result, null, 2), { mode: 0o600, flag: 'wx' })
  }
  console.error(publicFailure(error)); process.exitCode = 1
} finally {
  if (tunnel) { try { await tunnel.close() } catch { console.error('SSH_TUNNEL_CLEANUP_UNVERIFIED'); process.exitCode = 1 } }
}
