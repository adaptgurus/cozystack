import fs from 'node:fs'
import path from 'node:path'

export function requireThat (value, code) { if (!value) throw new Error(code) }
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value)
export function validateRequest (r) {
  requireThat(r && r.schema === 1 && ['dc', 'dr'].includes(r.target) && r.transport === 'strict-ssh-loopback', 'INVALID_TARGET')
  requireThat(/^[0-9a-f]{40}$/.test(r.cloudstackUiCommit) && /^[0-9a-f]{64}$/.test(r.artifactSha256), 'INVALID_ARTIFACT')
  requireThat(typeof r.artifactRunId === 'string' && /^\d+$/.test(r.artifactRunId) && typeof r.artifactName === 'string' && /^[A-Za-z0-9_-]{1,160}$/.test(r.artifactName), 'INVALID_ARTIFACT_RUN')
  requireThat(Array.isArray(r.personas) && r.personas.length > 0 && r.personas.length <= 4, 'INVALID_PERSONAS')
  const seen = new Set()
  for (const p of r.personas) {
    requireThat(['platform-admin', 'department-admin', 'operator', 'auditor'].includes(p.id) && !seen.has(p.id), 'INVALID_PERSONA')
    seen.add(p.id)
    requireThat(uuid(p.expectedUserId) && uuid(p.projectId) && typeof p.projectName === 'string' && p.projectName.length > 0 && p.projectName.length <= 200, 'INVALID_PERSONA_SCOPE')
    requireThat(!p.foreignProjectId || (uuid(p.foreignProjectId) && p.foreignProjectId !== p.projectId && p.id !== 'platform-admin'), 'INVALID_FOREIGN_SCOPE')
  }
  requireThat(r.target === 'dr', 'DC_TRUSTED_TRANSPORT_PENDING')
  return r.target
}

export function readProtectedBytes (file) {
  const full = path.resolve(file)
  let current = path.parse(full).root
  for (const part of full.slice(current.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, part)
    requireThat(!fs.lstatSync(current).isSymbolicLink(), 'CREDENTIAL_SYMLINK')
  }
  const fd = fs.openSync(full, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0))
  try {
    const info = fs.fstatSync(fd)
    requireThat(info.isFile() && info.nlink === 1 && info.size <= 32768, 'UNSAFE_CREDENTIAL_FILE')
    if (process.platform !== 'win32') {
      requireThat(info.uid === process.geteuid() && (info.mode & 0o077) === 0, 'CREDENTIAL_FILE_PERMISSIONS')
    } else requireThat(process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'WINDOWS_ACL_VERIFICATION_REQUIRED')
    return fs.readFileSync(fd)
  } finally { fs.closeSync(fd) }
}

export function readProtectedCredentials (file) {
  const value = JSON.parse(readProtectedBytes(file).toString('utf8'))
  requireThat(value && typeof value === 'object' && !Array.isArray(value), 'INVALID_CREDENTIAL_FILE')
  return value
}

export function classifyGate (response, payload) {
  if (response !== 200 || !payload || typeof payload !== 'object') return { status: 'BLOCKED', reason: 'BACKEND_UNAVAILABLE' }
  if (payload.kubernetes !== true || payload.gates?.capc_volume_ownership_safe !== true) return { status: 'BLOCKED', reason: 'RELEASE_PREREQUISITES_CLOSED' }
  return { status: 'NOT_TESTED', reason: 'PROVISIONING_LIFECYCLE_NOT_EXECUTED' }
}

export function allowedRequest (url, method, data, origin) {
  let u
  try { u = new URL(url) } catch { return false }
  if (u.origin !== origin || !u.pathname.startsWith('/client/')) return false
  if (u.pathname === '/client/api' || u.pathname === '/client/api/') {
    const params = method === 'GET' ? u.searchParams : new URLSearchParams(data || '')
    const command = params.get('command') || ''
    return (method === 'GET' && /^(list|get|query|find)[A-Za-z0-9]+$/.test(command)) ||
      (method === 'POST' && ['login', 'logout'].includes(command))
  }
  if (u.pathname.startsWith('/client/layersentry-k8s/')) return method === 'GET' && /^\/client\/layersentry-k8s\/v1\/kubernetes\/(readiness|clusters|operations|packages|images)(\/[A-Za-z0-9-]+)*$/.test(u.pathname)
  return method === 'GET' && (['/client/', '/client/index.html', '/client/config.json', '/client/favicon.ico', '/client/manifest.json'].includes(u.pathname) || /^\/client\/(js|css|img|fonts|assets|locales)\/[A-Za-z0-9_./@+% -]+$/.test(u.pathname))
}

export function publicFailure (error) {
  const text = error instanceof Error ? error.message : ''
  return /^[A-Z][A-Z0-9_]{2,80}$/.test(text) ? text : 'GUI_CHECK_FAILED'
}
