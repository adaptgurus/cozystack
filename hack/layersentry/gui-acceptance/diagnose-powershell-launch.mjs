import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { pathToFileURL } from 'node:url'
import { ASKPASS } from './dc-tunnel.mjs'
import { diagnosticEnvironments, MARKER, probe } from './diagnose-ssh-startup.mjs'
import { requireThat, publicFailure, readProtectedBytes } from './contract.mjs'

const prefix = ['-NoProfile', '-NonInteractive']
export const CONSOLE_SCRIPT = `[Console]::Write('${MARKER}')`
export const OUTPUT_SCRIPT = `Write-Output '${MARKER}'`
export const HELPER_SCRIPT = '& $env:LAYERSENTRY_DUMMY_ASKPASS'
export function encodedCommand (script) { return [...prefix, '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')] }
export function expandedSystemEnvironment (source, minimal) {
  const additions = ['SystemDrive', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'LOCALAPPDATA', 'APPDATA', 'PSModulePath', 'PATHEXT', 'USERDOMAIN', 'USERNAME', 'OS', 'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS']
  return { ...minimal, ...Object.fromEntries(additions.filter(key => source[key]).map(key => [key, source[key]])) }
}
export function launchCases (powershell, cmd, files, fixed, expanded) {
  requireThat(/^[a-z0-9-]+\.cmd$/.test(path.basename(files.helper)), 'DUMMY_HELPER_BASENAME_REQUIRED')
  return [
    { id: 'command-console', executable: powershell, args: [...prefix, '-Command', CONSOLE_SCRIPT], env: fixed },
    { id: 'command-output', executable: powershell, args: [...prefix, '-Command', OUTPUT_SCRIPT], env: fixed },
    { id: 'encoded-console', executable: powershell, args: encodedCommand(CONSOLE_SCRIPT), env: fixed },
    { id: 'file-console', executable: powershell, args: [...prefix, '-File', files.console], env: fixed },
    { id: 'command-helper', executable: powershell, args: [...prefix, '-Command', HELPER_SCRIPT], env: fixed },
    { id: 'encoded-helper', executable: powershell, args: encodedCommand(HELPER_SCRIPT), env: fixed },
    { id: 'file-helper', executable: powershell, args: [...prefix, '-File', files.invoke], env: fixed },
    // Fixed generated basename + cwd avoids shell interpolation of a path.
    { id: 'cmd-helper', executable: cmd, args: ['/d', '/c', path.basename(files.helper)], cwd: path.dirname(files.helper), env: fixed },
    { id: 'file-console-expanded-system-env', executable: powershell, args: [...prefix, '-File', files.console], env: expanded }
  ]
}

async function main () {
  const [privateDirectory, output] = process.argv.slice(2)
  requireThat(process.platform === 'win32' && process.env.LAYERSENTRY_GUI_ACL_VERIFIED === '1', 'WINDOWS_TRUSTED_DIAGNOSTIC_WRAPPER_REQUIRED')
  const directory = path.resolve(privateDirectory)
  requireThat(fs.lstatSync(directory).isDirectory() && !fs.lstatSync(directory).isSymbolicLink(), 'SSH_DIAGNOSTIC_PRIVATE_DIRECTORY_REQUIRED')
  const id = crypto.randomUUID()
  const files = { helper: path.join(directory, 'dummy-' + id + '.cmd'), console: path.join(directory, 'console-' + id + '.ps1'), invoke: path.join(directory, 'invoke-' + id + '.ps1') }
  const result = { schema: 1, status: 'BLOCKED', scope: 'POWERSHELL_DUMMY_LAUNCH_ONLY', networkConnectionAttempted: false, realCredentialsUsed: false, authenticationApproved: false, productionCertified: false, cases: [] }
  try {
    for (const [file, content] of [[files.helper, ASKPASS], [files.console, CONSOLE_SCRIPT], [files.invoke, HELPER_SCRIPT]]) {
      fs.writeFileSync(file, content, { mode: 0o600, flag: 'wx' })
      requireThat(readProtectedBytes(file).toString('utf8') === content, 'DUMMY_SCRIPT_CHANGED')
    }
    const { fixed } = diagnosticEnvironments(process.env, files.helper)
    const powershell = path.join(fixed.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    const cmd = path.join(fixed.SystemRoot, 'System32', 'cmd.exe')
    const cases = launchCases(powershell, cmd, files, fixed, expandedSystemEnvironment(process.env, fixed))
    // Three independent local-only children at a time; no open stdin or waits
    // for user input. Each uses the same bounded public byte-count collector.
    for (let index = 0; index < cases.length; index += 3) {
      const group = await Promise.allSettled(cases.slice(index, index + 3).map(async item => ({ id: item.id, ...await probe(item.executable, item.args, item.env, true, 'pipe', item.cwd) })))
      for (const [offset, entry] of group.entries()) result.cases.push(entry.status === 'fulfilled' ? entry.value : { id: cases[index + offset].id, probeFailure: publicFailure(entry.reason) })
    }
    requireThat(result.cases.every(item => item.processClosed === true && item.spawnErrorCode === null && !item.timedOut && !item.outputTruncated), 'DUMMY_LAUNCH_COLLECTION_INCOMPLETE')
    result.status = 'COLLECTED'
    // A winning variant is an observation only. Root must review and bind any
    // subsequent transport change to exact helper and startup proof.
    result.markerVerifiedCases = result.cases.filter(item => item.exitCode === 0 && item.dummyMarkerMatched === true).map(item => item.id)
  } catch (error) { result.reason = publicFailure(error) } finally {
    for (const file of Object.values(files)) if (fs.existsSync(file)) fs.unlinkSync(file)
    result.ownedDummyFilesRemoved = Object.values(files).every(file => !fs.existsSync(file))
    if (!result.ownedDummyFilesRemoved) result.status = 'BLOCKED'
    fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n', { mode: 0o600, flag: 'wx' })
  }
  process.exitCode = result.status === 'COLLECTED' ? 0 : 1
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch(error => { console.error(publicFailure(error)); process.exitCode = 1 })
