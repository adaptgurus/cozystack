import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_dc_console_snapshot import ROOT, POWERSHELL, CAPTURE


MOCKS = r'''
function Import-Module { param($Name) }
function Get-VM {
    param($Name)
    [pscustomobject]@{ Id = $env:TEST_VM_ID; Name = 'sen'; State = 'Running' }
}
function Get-CimInstance {
    param($Namespace, $ClassName, $Filter)
    if ($Filter -cne "Name='29ba176b-b81a-4f47-8f51-ecec869f247f'") { throw 'Wrong CIM filter' }
    [pscustomobject]@{ Name = $env:TEST_VM_ID; ElementName = 'sen' }
}
function Get-CimAssociatedInstance { param($InputObject, $ResultClassName); [pscustomobject]@{ Name = 'keyboard' } }
function Invoke-CimMethod {
    param($InputObject, $MethodName, $Arguments)
    if ($MethodName -eq 'TypeText' -and $Arguments.asciiText -ceq 'root') {
        'TypeText:root' | Add-Content $env:TEST_TRACE
    } elseif ($MethodName -eq 'TypeKey' -and $Arguments.keyCode -eq 13) {
        'TypeKey:13' | Add-Content $env:TEST_TRACE
    } else { throw 'Unexpected keyboard operation' }
    [pscustomobject]@{ ReturnValue = [int]$env:TEST_KEY_RC }
}
& $env:LOGIN_WRAPPER
'''
OCR = r'''
param($ImagePath)
$prompt = $env:TEST_PROMPT
if ($ImagePath -match 'refreshed-') { $prompt = $env:TEST_REFRESH_PROMPT }
@{ text = $prompt; lines = @(@{ text = 'Rocky Linux 9.8' }) + @($prompt.Split("`n") | ForEach-Object { @{ text = $_ } }) } | ConvertTo-Json -Depth 4
'''


@unittest.skipUnless(POWERSHELL, 'Set POWERSHELL_TEST_BINARY or install pwsh for wrapper tests')
class BeginLoginTests(unittest.TestCase):
    def run_fixture(self, expected_keys, expected_status, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / 'invoke-dc-console-begin-login.ps1'
            shutil.copyfile(ROOT / wrapper.name, wrapper)
            (root / 'capture-hyperv-console.ps1').write_text(CAPTURE + r'''
if ($env:TEST_CAPTURE -eq 'after-no-image' -and $OutputDirectory -match 'after-') {
    Remove-Item -LiteralPath (Join-Path $OutputDirectory 'sen-console.png')
}
''')
            (root / 'read-console-ocr.ps1').write_text(OCR)
            trace = root / 'keys.txt'
            env = dict(os.environ, RUNNER_TEMP=directory, GITHUB_RUN_ID='fixture', GITHUB_RUN_ATTEMPT='1',
                       GITHUB_SHA='fixture', COMPUTERNAME='TESTSER', LOGIN_WRAPPER=str(wrapper),
                       TEST_VM_ID='29ba176b-b81a-4f47-8f51-ecec869f247f', TEST_PROMPT='layersentry login:',
                       TEST_CAPTURE='success', TEST_TRACE=str(trace), TEST_KEY_RC='0', TEST_REFRESH_PROMPT='layersentry login:')
            env.update(overrides)
            result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-Command', MOCKS],
                                    env=env, capture_output=True, text=True, timeout=20)
            state = json.loads((root / 'layersentry-dc-begin-login-fixture-1/summary.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(state['status'], expected_status, result.stderr)
            self.assertEqual(trace.read_text().splitlines() if trace.exists() else [], expected_keys)
            self.assertEqual(state['inputAttempted'], bool(expected_keys))
            self.assertEqual(state['afterCaptured'], bool(expected_keys) and expected_status != 'AFTER_CAPTURE_FAILED_INPUT_OUTCOME_REQUIRES_REVIEW')
            self.assertFalse(state['passwordSent'])
            self.assertFalse(state['guestConfigChanged'])
            self.assertEqual(result.returncode == 0, expected_status == 'USERNAME_SENT_AWAITING_CONSOLE_REVIEW')

    def test_login_sends_only_literal_root_and_enter(self):
        self.run_fixture(['TypeText:root', 'TypeKey:13'], 'USERNAME_SENT_AWAITING_CONSOLE_REVIEW')

    def test_password_prompt_does_not_receive_input(self):
        self.run_fixture([], 'LOGIN_PROMPT_NOT_VERIFIED', TEST_PROMPT='Password:')

    def test_shell_prompt_does_not_receive_input(self):
        self.run_fixture([], 'LOGIN_PROMPT_NOT_VERIFIED', TEST_PROMPT='[root@layersentry ~]#')

    def test_unknown_or_prefilled_prompt_does_not_receive_input(self):
        for prompt in ('', 'layersentry login: root', 'other login:'):
            with self.subTest(prompt=prompt):
                self.run_fixture([], 'LOGIN_PROMPT_NOT_VERIFIED', TEST_PROMPT=prompt)

    def test_wrong_vm_does_not_receive_input(self):
        self.run_fixture([], 'TARGET_BINDING_FAILED', TEST_VM_ID='other')

    def test_missing_before_image_does_not_receive_input(self):
        self.run_fixture([], 'BEFORE_CAPTURE_FAILED', TEST_CAPTURE='no-image')

    def test_uncertain_typing_does_not_retry_or_send_enter(self):
        self.run_fixture(['TypeText:root'], 'INPUT_OUTCOME_UNKNOWN', TEST_KEY_RC='4096')

    def test_missing_after_image_fails_without_more_input(self):
        self.run_fixture(['TypeText:root', 'TypeKey:13'], 'AFTER_CAPTURE_FAILED_INPUT_OUTCOME_REQUIRES_REVIEW', TEST_CAPTURE='after-no-image')

    def test_interleaved_kernel_logs_get_one_refresh_before_username(self):
        self.run_fixture(['TypeKey:13', 'TypeText:root', 'TypeKey:13'], 'USERNAME_SENT_AWAITING_CONSOLE_REVIEW',
                         TEST_PROMPT='layersentry login: [14.043] /proc/cgroups message\n[19.300] hrtimer message\n[54.100] hv_balloon message')

    def test_unknown_trailing_text_or_supplied_username_blocks_refresh(self):
        for prompt in ('layersentry login:\nunknown text', 'layersentry login: root\n[14.0] kernel message',
                       'layersentry login:\n[14.0] kernel message\nPassword:'):
            with self.subTest(prompt=prompt):
                self.run_fixture([], 'LOGIN_PROMPT_NOT_VERIFIED', TEST_PROMPT=prompt)

    def test_refresh_must_produce_strict_empty_prompt_without_retry(self):
        self.run_fixture(['TypeKey:13'], 'REFRESHED_LOGIN_PROMPT_NOT_VERIFIED',
                         TEST_PROMPT='layersentry login:\n[14.0] kernel message', TEST_REFRESH_PROMPT='Password:')

    def test_uncertain_refresh_does_not_send_username_or_retry(self):
        self.run_fixture(['TypeKey:13'], 'REFRESH_INPUT_OUTCOME_UNKNOWN',
                         TEST_PROMPT='layersentry login:\n[14.0] kernel message', TEST_KEY_RC='4096')


if __name__ == '__main__':
    unittest.main()
