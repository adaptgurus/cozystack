import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { CONSOLE_SCRIPT, OUTPUT_SCRIPT, HELPER_SCRIPT, encodedCommand, expandedSystemEnvironment, launchCases } from './diagnose-powershell-launch.mjs'
import { MARKER, probe } from './diagnose-ssh-startup.mjs'

test('PowerShell variants contain only fixed dummy expressions and exact files', () => {
  assert.equal(Buffer.from(encodedCommand(CONSOLE_SCRIPT).at(-1), 'base64').toString('utf16le'), CONSOLE_SCRIPT)
  const files = { helper: '/private/dummy-123.cmd', console: '/private/console.ps1', invoke: '/private/invoke.ps1' }
  const fixed = { ROCKY_PASSWORD: MARKER }; const expanded = { ...fixed, ProgramData: 'system' }
  const cases = launchCases('/system/powershell.exe', '/system/cmd.exe', files, fixed, expanded)
  assert.equal(cases.length, 9)
  assert.deepEqual(cases.map(item => item.id), ['command-console', 'command-output', 'encoded-console', 'file-console', 'command-helper', 'encoded-helper', 'file-helper', 'cmd-helper', 'file-console-expanded-system-env'])
  assert.equal(cases[0].args.at(-1), CONSOLE_SCRIPT); assert.equal(cases[1].args.at(-1), OUTPUT_SCRIPT)
  assert.equal(cases[4].args.at(-1), HELPER_SCRIPT)
  assert.deepEqual(cases[7].args, ['/d', '/c', 'dummy-123.cmd']); assert.equal(cases[7].cwd, '/private')
  assert.ok(cases.every(item => !item.args.includes('-NoExit')))
  assert.throws(() => launchCases('/ps', '/cmd', { ...files, helper: '/private/evil&command.cmd' }, fixed, expanded))
})

test('expanded system comparison excludes all real credential and profile code variables', () => {
  const source = { USERPROFILE: 'profile', PATHEXT: '.EXE;.CMD', PSModulePath: 'system-modules', CLOUDSTACK_API_KEY: 'real-api-key', ROCKY_PASSWORD: 'real-password', GH_TOKEN: 'real-token', DEBUG: '1', PSExecutionPolicyPreference: 'Bypass' }
  const env = expandedSystemEnvironment(source, { ROCKY_PASSWORD: MARKER })
  assert.deepEqual(env, { ROCKY_PASSWORD: MARKER, USERPROFILE: 'profile', PATHEXT: '.EXE;.CMD', PSModulePath: 'system-modules' })
  assert.ok(!JSON.stringify(env).includes('real-'))
})

test('actual bounded subprocess collector sees marker and never retains raw text', { skip: process.platform === 'win32' || !fs.existsSync('/usr/bin/python3') }, async () => {
  const receipt = await probe('/usr/bin/python3', ['-c', `import sys;sys.stdout.write('${MARKER}');sys.stderr.write('dummy unknown diagnostic')`], { PATH: '/usr/bin:/bin' }, true, 'pipe')
  assert.equal(receipt.exitCode, 0); assert.equal(receipt.processClosed, true)
  assert.equal(receipt.stdoutBytes, Buffer.byteLength(MARKER)); assert.equal(receipt.dummyMarkerMatched, true)
  assert.equal(receipt.stderrBytes, 24); assert.equal(receipt.stderrClass, 'UNKNOWN')
  assert.ok(!JSON.stringify(receipt).includes(MARKER)); assert.ok(!JSON.stringify(receipt).includes('dummy unknown diagnostic'))
})
