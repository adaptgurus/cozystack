"""Execute the real wrapper against isolated Hyper-V/capture fixtures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent
POWERSHELL = os.environ.get('POWERSHELL_TEST_BINARY') or shutil.which('pwsh')
MOCKS = r'''
function Import-Module { param($Name) }
function Get-VM {
    param($Name)
    [pscustomobject]@{ Id = $env:TEST_VM_ID; Name = 'sen'; State = $env:TEST_VM_STATE }
}
& $env:SNAPSHOT_WRAPPER
'''
CAPTURE = r'''
param($VmNames, $OutputDirectory)
if (@($VmNames).Count -ne 1 -or $VmNames[0] -cne 'sen') { throw 'Wrong capture target' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
if ($env:TEST_CAPTURE -eq 'no-report') { return }
$report = @{
    Host = 'TESTSER'; CollectionMode = 'read-only-hyperv-console-thumbnail'
    VirtualMachines = @(@{ Name = 'sen'; State = 'Running'; ConsoleCaptureStatus = 'Success'
        ConsoleImage = 'sen-console.png'; ConsoleWidth = 640; ConsoleHeight = 480 })
}
if ($env:TEST_CAPTURE -eq 'failed') { $report.VirtualMachines[0].ConsoleCaptureStatus = 'Failed' }
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'console-capture.json')
if ($env:TEST_CAPTURE -ne 'no-image') {
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'sen-console.png'), [byte[]](1..16))
}
'''


@unittest.skipUnless(POWERSHELL, 'Set POWERSHELL_TEST_BINARY or install pwsh for wrapper tests')
class SnapshotTests(unittest.TestCase):
    def run_fixture(self, expected, attempted, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / 'invoke-dc-console-snapshot.ps1'
            shutil.copyfile(ROOT / wrapper.name, wrapper)
            (root / 'capture-hyperv-console.ps1').write_text(CAPTURE)
            env = dict(os.environ, RUNNER_TEMP=directory, GITHUB_RUN_ID='fixture', GITHUB_RUN_ATTEMPT='1',
                       GITHUB_SHA='fixture', COMPUTERNAME='TESTSER', SNAPSHOT_WRAPPER=str(wrapper),
                       TEST_VM_ID='29ba176b-b81a-4f47-8f51-ecec869f247f', TEST_VM_STATE='Running',
                       TEST_CAPTURE='success')
            env.update(overrides)
            result = subprocess.run([POWERSHELL, '-NoLogo', '-NoProfile', '-Command', MOCKS],
                                    env=env, capture_output=True, text=True, timeout=20)
            state = json.loads((root / 'layersentry-dc-console-fixture-1/summary.json').read_text(encoding='utf-8-sig'))
            self.assertEqual(state['status'], expected, result.stderr)
            self.assertEqual(state['captureAttempted'], attempted)
            self.assertEqual(state['captureSucceeded'], expected == 'CAPTURED')
            self.assertEqual(result.returncode == 0, expected == 'CAPTURED')
            self.assertFalse(state['guestInputPerformed'])
            self.assertFalse(state['mutationPerformed'])

    def test_exact_running_vm_with_image_passes(self):
        self.run_fixture('CAPTURED', True)

    def test_wrong_host_never_captures(self):
        self.run_fixture('TARGET_BINDING_FAILED', False, COMPUTERNAME='OTHER')

    def test_wrong_vm_id_never_captures(self):
        self.run_fixture('TARGET_BINDING_FAILED', False, TEST_VM_ID='00000000-0000-0000-0000-000000000000')

    def test_stopped_vm_never_captures(self):
        self.run_fixture('TARGET_BINDING_FAILED', False, TEST_VM_STATE='Off')

    def test_missing_report_never_claims_success(self):
        self.run_fixture('CAPTURE_FAILED', True, TEST_CAPTURE='no-report')

    def test_missing_image_never_claims_success(self):
        self.run_fixture('CAPTURE_FAILED', True, TEST_CAPTURE='no-image')

    def test_reported_failure_never_claims_success(self):
        self.run_fixture('CAPTURE_FAILED', True, TEST_CAPTURE='failed')


if __name__ == '__main__':
    unittest.main()
