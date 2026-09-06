"""PowerShell console fixtures; no Hyper-V, guest login, SSH or credentials used."""

import base64
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).parent
POWERSHELL = os.environ.get('POWERSHELL_TEST_BINARY') or shutil.which('pwsh')
KEY = 'ssh-ed25519 ' + base64.b64encode(b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20' + b'a' * 32).decode()
CHALLENGE = 'abcd1234' * 4
PASSWORD = 'FAKE-TEST-SECRET-DoNotPublish'

MOCKS = r'''
. $env:TRUST_WRAPPER
$script:Keys = @()
$script:Reads = 0
function Import-Module { param($Name) }
function Get-VM { param($Name); [pscustomobject]@{ Id=$env:TEST_VM_ID; Name='sen'; State='Running' } }
function Get-CimInstance { [pscustomobject]@{ Name=$env:TEST_VM_ID; ElementName='sen' } }
function Get-CimAssociatedInstance { [pscustomobject]@{ SystemName=$env:TEST_VM_ID; CreationClassName='Msvm_Keyboard' } }
function New-TrustPrivateDirectory([string]$Path) { New-Item -ItemType Directory -Path $Path | Out-Null }
function Get-TrustKeyboard { Assert-TrustDcIdentity; return 'keyboard' }
function Invoke-CimMethod {
    param($InputObject, $MethodName, $Arguments)
    if ($MethodName -eq 'TypeText') {
        if ($Arguments.asciiText.Length -gt 512) { throw 'Oversized text call' }
        $script:Keys += 'Text'
        if ($Arguments.asciiText -ceq $env:DC_PASSWORD) { $script:Keys[-1] = 'Password' }
    } elseif ($MethodName -eq 'TypeKey' -and $Arguments.keyCode -eq 13) { $script:Keys += 'Enter' }
    else { throw 'Unexpected keyboard operation' }
    if ($env:TEST_FAIL_KEY -eq [string]$script:Keys.Count) {
        throw ('Raw CIM exception containing ' + $env:DC_PASSWORD)
    }
    [pscustomobject]@{ ReturnValue=0 }
}
function New-TrustChallenge { return $env:TEST_CHALLENGE }
function Get-TrustCandidate { return $env:TEST_KEY }
function Read-TrustConsole([string]$Private) {
    Assert-TrustDcIdentity
    $script:Reads++
    $prompt = $env:TEST_PROMPT
    if ($env:TEST_PHASE -eq 'Refresh' -and $script:Keys.Count -eq 1 -and $script:Keys[0] -eq 'Enter') { $prompt = 'layersentry login:' }
    if ($env:TEST_PHASE -eq 'Login' -and $script:Keys.Count -eq 1 -and $script:Keys[0] -eq 'Enter') { $prompt = 'layersentry login:' }
    if ($env:TEST_PHASE -eq 'Login' -and $script:Keys -contains 'Text' -and $script:Keys[-1] -eq 'Enter') { $prompt = 'Password:' }
    if ($env:TEST_PHASE -eq 'Login' -and $script:Keys -contains 'Password' -and $script:Keys[-1] -eq 'Enter') { $prompt = '[root@layersentry ~]#' }
    $lines = @($prompt.Split("`n"))
    if ($env:TEST_PHASE -eq 'Verify' -and $script:Keys -contains 'Enter') {
        $nonce = $env:TEST_CHALLENGE
        $lines = @("LS-DC-$nonce-BEGIN", 'TARGET 10.10.10.14 ROOT KEY MATCH', "LS-DC-$nonce-END", '[root@layersentry ~]#')
    }
    $image = Join-Path $Private "capture-$script:Reads.png"
    # Private image content is a sentinel; Login must never publish it.
    [IO.File]::WriteAllText($image, 'private-image-sentinel')
    return [pscustomobject]@{ Lines=$lines; Image=$image; Started=(Get-Date); KnownPublicImage=($env:TEST_REVIEWED_IMAGE -ceq 'true'); ImageSha256='fixture-reviewed-digest' }
}
try { Invoke-DcTrustPhase -Phase $env:TEST_PHASE } finally {
    ConvertTo-Json -InputObject @($script:Keys) | Set-Content $env:TEST_TRACE
}
'''


@unittest.skipUnless(POWERSHELL, 'PowerShell is required for executed wrapper fixtures')
class ConsoleTrustTests(unittest.TestCase):
    def test_keyboard_uuid_identity_accepts_case_but_rejects_wrong_scope(self):
        command = r'''
function Assert-TrustDcIdentity {}
function Get-CimInstance { [pscustomobject]@{ Name=$env:TEST_SYSTEM_UUID; ElementName='sen' } }
function Get-CimAssociatedInstance {
    $key = [pscustomobject]@{ SystemName=$env:TEST_KEY_UUID; CreationClassName=$env:TEST_KEY_CLASS }
    $key
    if ($env:TEST_DUPLICATE -eq 'true') { $key }
}
$null = Get-TrustKeyboard
'''
        uuid = '29BA176B-B81A-4F47-8F51-ECEC869F247F'
        valid = dict(TEST_SYSTEM_UUID=uuid, TEST_KEY_UUID=uuid, TEST_KEY_CLASS='Msvm_Keyboard', TEST_DUPLICATE='false')
        self.assertEqual(self.run_function(command, **valid).returncode, 0)
        for field, value in (('TEST_SYSTEM_UUID', 'not-a-guid'), ('TEST_KEY_UUID', '00000000-0000-0000-0000-000000000000'),
                             ('TEST_KEY_CLASS', 'Other'), ('TEST_DUPLICATE', 'true')):
            with self.subTest(field=field):
                self.assertNotEqual(self.run_function(command, **dict(valid, **{field: value})).returncode, 0)

    def test_open_async_uses_its_declared_random_access_stream_result(self):
        source = (ROOT / 'read-console-ocr.ps1').read_text()
        selection = source[source.index('$asTaskMethod ='):source.index('if ($null -eq $asTaskMethod)')]
        selection = selection.replace('[System.WindowsRuntimeSystemExtensions]', '[TestExtensions]')
        wait = source[source.index('function Wait-WinRtOperation'):source.index('[void][Windows.Storage.StorageFile')]
        stream = source[source.index('    $streamOperation ='):source.index('    $decoderOperation =')]
        code = r'''
Add-Type -TypeDefinition @'
using System.Threading.Tasks;
namespace Windows.Foundation { public interface IAsyncOperation<T> {} }
namespace Windows.Storage { public enum FileAccessMode { Read } }
namespace Windows.Storage.Streams {
 public interface IRandomAccessStream {}
 public interface IRandomAccessStreamWithContentType : IRandomAccessStream {}
}
public class TestOperation : Windows.Foundation.IAsyncOperation<Windows.Storage.Streams.IRandomAccessStream> {}
public class TestFile {
 public Windows.Foundation.IAsyncOperation<Windows.Storage.Streams.IRandomAccessStream> OpenAsync(Windows.Storage.FileAccessMode mode) { return new TestOperation(); }
}
public static class TestExtensions {
 public static Task<string> AsTask<T>(Windows.Foundation.IAsyncOperation<T> operation) { return Task.FromResult("stream"); }
}
'@
$storageFile = [TestFile]::new()
''' + selection + wait + stream + r'''
if ($stream -cne 'stream') { throw 'OpenAsync result type mismatch.' }
'''
        result = self.run_function(code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_winrt_async_operation_overload_is_selected_even_when_action_is_first(self):
        source = (ROOT / 'read-console-ocr.ps1').read_text()
        selection = source[source.index('$asTaskMethod ='):source.index('if ($null -eq $asTaskMethod)')]
        selection = selection.replace('[System.WindowsRuntimeSystemExtensions]', '[TestExtensions]')
        code = r'''
Add-Type -TypeDefinition @'
using System.Threading.Tasks;
namespace Windows.Foundation {
 public interface IAsyncActionWithProgress<T> {}
 public interface IAsyncOperation<T> {}
}
public class TestOperation : Windows.Foundation.IAsyncOperation<string> {}
public static class TestExtensions {
 public static Task<string> AsTask<T>(Windows.Foundation.IAsyncActionWithProgress<T> action) { return Task.FromResult("wrong"); }
 public static Task<string> AsTask<T>(Windows.Foundation.IAsyncOperation<T> operation) { return Task.FromResult("operation"); }
}
'@
''' + selection + r'''
$method = $asTaskMethod.MakeGenericMethod([string])
$task = $method.Invoke($null, @([TestOperation]::new()))
if ($task.Result -cne 'operation') { throw 'Wrong asynchronous overload selected.' }
'''
        result = self.run_function(code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_phase(self, phase, prompt, expected_keys, success=True, **override):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / 'invoke-dc-console-trust.ps1'
            shutil.copyfile(ROOT / script.name, script)
            env = dict(os.environ, TRUST_WRAPPER=str(script), RUNNER_TEMP=folder, GITHUB_RUN_ID='fixture',
                       GITHUB_RUN_ATTEMPT='1', GITHUB_SHA='test-source', COMPUTERNAME='TESTSER',
                       TEST_VM_ID='29ba176b-b81a-4f47-8f51-ecec869f247f', TEST_PHASE=phase,
                       TEST_PROMPT=prompt, TEST_TRACE=str(root / 'trace.json'), TEST_FAIL_KEY='0', TEST_REVIEWED_IMAGE='false',
                       TEST_KEY=KEY, TEST_CHALLENGE=CHALLENGE, DC_HOST='10.10.10.14', DC_USER='root', DC_PASSWORD=PASSWORD)
            env.update(override)
            result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-Command', MOCKS], env=env,
                                    text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            self.assertNotIn(PASSWORD, result.stdout + result.stderr)
            trace = json.loads((root / 'trace.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(trace, expected_keys)
            evidence = root / 'layersentry-dc-trust-fixture-1'
            state = json.loads((evidence / 'summary.json').read_text(encoding='utf-8-sig'))
            for path in evidence.rglob('*'):
                if path.is_file():
                    self.assertNotIn(PASSWORD.encode(), path.read_bytes())
                    if phase != 'Verify':
                        self.assertNotIn(b'private-image-sentinel', path.read_bytes())
            self.assertEqual(list(root.glob('dc-trust-private-*')), [])
            self.assertFalse(state['sshAuthenticationAttempted'])
            self.assertFalse(state['guestConfigurationChanged'])
            return state

    def test_observe_never_types_or_publishes_private_image(self):
        state = self.run_phase('Observe', 'layersentry login:', [])
        self.assertEqual(state['initialPrompt'], 'EMPTY_LOGIN')
        self.assertNotIn('reviewedPublicImageOcrLines', state)

    def test_refresh_only_allows_one_enter_for_exact_reviewed_image(self):
        self.run_phase('Refresh', 'unknown OCR', [], success=False)
        state = self.run_phase('Refresh', 'unknown OCR', ['Enter'], TEST_REVIEWED_IMAGE='true')
        self.assertEqual(state['status'], 'EMPTY_LOGIN_REFRESHED_NO_CREDENTIAL_INPUT')
        self.assertFalse(state['passwordSent'])
        self.run_phase('Refresh', 'unknown OCR', ['Enter'], success=False,
                       TEST_REVIEWED_IMAGE='true', TEST_FAIL_KEY='1')

    def test_login_uses_fresh_password_prompt_and_keeps_all_images_private(self):
        state = self.run_phase('Login', 'layersentry login:', ['Text', 'Enter', 'Password', 'Enter'])
        self.assertEqual(state['status'], 'AUTHENTICATED_AWAITING_PUBLIC_KEY_PHASE')
        self.assertTrue(state['passwordSent'])
        self.assertFalse(state['hostTrustEstablished'])

    def test_existing_password_prompt_never_receives_credentials(self):
        self.run_phase('Login', 'Password:', [], success=False)

    def test_observed_kernel_output_allows_one_refresh_before_fresh_login(self):
        prompt = 'layersentry login: [ 14.043958] /proc/cgroups message\n[ 19.177230] hrtimer message'
        self.run_phase('Login', prompt, ['Enter', 'Text', 'Enter', 'Password', 'Enter'])

    def test_prefilled_login_and_unknown_shell_never_receive_credentials(self):
        for prompt in ('layersentry login: admin', '[root@foreign ~]#', 'unknown text'):
            self.run_phase('Login', prompt, [], success=False)

    def test_wrong_vm_never_receives_input(self):
        self.run_phase('Login', 'layersentry login:', [], success=False, TEST_VM_ID='wrong')

    def test_wrong_credential_target_never_receives_input(self):
        self.run_phase('Login', 'layersentry login:', [], success=False, DC_HOST='10.10.10.20')

    def test_uncertain_username_and_password_input_never_get_enter_or_replay(self):
        for fail, expected in (('1', ['Text']), ('3', ['Text', 'Enter', 'Password'])):
            self.run_phase('Login', 'layersentry login:', expected, success=False, TEST_FAIL_KEY=fail)

    def test_verify_requires_authenticated_empty_root_prompt(self):
        self.run_phase('Verify', 'layersentry login:', [], success=False)

    def test_guest_command_is_encoded_and_chunked_with_public_receipt(self):
        command = self.run_function("New-TrustGuestCommand $env:TEST_KEY $env:TEST_CHALLENGE").stdout.strip()
        self.assertNotIn(CHALLENGE, command)
        self.assertNotIn('ROOT KEY MATCH', command)
        payload = base64.b64decode(command.split("'")[3]).decode()
        self.assertIn("assert key == candidate", payload)
        self.assertIn("os.geteuid() == 0", payload)
        self.assertIn("10.10.10.14", payload)
        count = (len(command) + 383) // 384
        state = self.run_phase('Verify', '[root@layersentry ~]#', ['Text'] * count + ['Enter'])
        self.assertEqual(state['status'], 'OOB_HOST_KEY_VERIFIED')

    def run_function(self, command, **overrides):
        env = dict(os.environ, TRUST_WRAPPER=str(ROOT / 'invoke-dc-console-trust.ps1'), TEST_KEY=KEY, TEST_CHALLENGE=CHALLENGE)
        env.update(overrides)
        return subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-Command', '. $env:TRUST_WRAPPER; ' + command],
                              env=env, text=True, capture_output=True, timeout=10)

    def test_old_challenge_wrong_key_and_extra_console_text_are_rejected(self):
        command = r'''
$view = [pscustomobject]@{Lines=@('LS-DC-old-BEGIN','TARGET 10.10.10.14 ROOT KEY MATCH','LS-DC-old-END','[root@layersentry ~]#')}
Assert-TrustPublicReceipt $view $env:TEST_KEY $env:TEST_CHALLENGE
'''
        self.assertNotEqual(self.run_function(command).returncode, 0)
        for extra in ('wrong-key', PASSWORD):
            command = r'''
$nonce=$env:TEST_CHALLENGE
$view=[pscustomobject]@{Lines=@("LS-DC-$nonce-BEGIN",'TARGET 10.10.10.14 ROOT KEY MATCH',$env:TEST_EXTRA,"LS-DC-$nonce-END",'[root@layersentry ~]#')}
Assert-TrustPublicReceipt $view $env:TEST_KEY $nonce
'''
            result = self.run_function(command, TEST_EXTRA=extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn(PASSWORD, result.stdout + result.stderr)

    def test_guest_payload_refuses_symlinks_hardlinks_wrong_key_and_wrong_address(self):
        command = self.run_function("New-TrustGuestCommand $env:TEST_KEY $env:TEST_CHALLENGE").stdout.strip()
        payload = base64.b64decode(command.split("'")[3]).decode()
        self.assertLessEqual(len(command), 3500)
        for case in ('valid', 'key-symlink', 'directory-symlink', 'key-hardlink', 'key-writable', 'wrong-key', 'wrong-address'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                ssh = root / 'etc' / 'ssh'
                ssh.mkdir(parents=True)
                key = ssh / 'ssh_host_ed25519_key.pub'
                key.write_text((KEY if case != 'wrong-key' else 'ssh-ed25519 wrong') + ' public-comment\n')
                if case == 'key-symlink':
                    key.rename(ssh / 'target')
                    key.symlink_to(ssh / 'target')
                elif case == 'directory-symlink':
                    ssh.rename(root / 'actual-ssh')
                    ssh.symlink_to(root / 'actual-ssh')
                elif case == 'key-hardlink':
                    os.link(key, ssh / 'other')
                elif case == 'key-writable':
                    key.chmod(0o666)
                real_open, real_stat = os.open, os.fstat

                def open_file(path, flags, *args, **kwargs):
                    return real_open(str(root) if path == '/' else path, flags, *args, **kwargs)

                def stat_file(fd):
                    info = real_stat(fd)
                    # Fixture represents root ownership; actual links/modes/FD
                    # resolution are exercised by the development filesystem.
                    return SimpleNamespace(st_uid=0, st_mode=info.st_mode, st_nlink=info.st_nlink)

                def read_ip(args, **_kwargs):
                    self.assertEqual(args, ['/usr/sbin/ip', '-j', '-4', 'address', 'show'])
                    return SimpleNamespace(stdout=json.dumps([{'addr_info': [{'local': '10.10.10.20' if case == 'wrong-address' else '10.10.10.14'}]}]))

                output = io.StringIO()
                with patch('os.open', side_effect=open_file), patch('os.fstat', side_effect=stat_file), patch('os.geteuid', return_value=0), patch('subprocess.run', side_effect=read_ip), redirect_stdout(output):
                    exec(compile(payload, '<fixed-public-key-payload>', 'exec'), {})
                if case == 'valid':
                    self.assertIn('LS-DC-' + CHALLENGE + '-BEGIN', output.getvalue())
                    self.assertIn('TARGET 10.10.10.14 ROOT KEY MATCH', output.getvalue())
                    self.assertNotIn(KEY, output.getvalue())
                else:
                    self.assertEqual(output.getvalue(), 'DC HOST KEY VERIFICATION FAILED\n')


if __name__ == '__main__':
    unittest.main()
