import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('dc_launcher', ROOT / 'run-dc-storage-registration-stdin.py')
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)
PWSH = os.environ.get('POWERSHELL_TEST_BINARY')


def payload():
    proof = json.loads((ROOT / 'evidence/dc-registration-public-proof-20260906.json').read_text())
    sources = {}
    for name, file in [('dr_recovery_acceptance', 'dr_recovery_acceptance.py'), ('dc_native_storage_registration', 'register-dc-native-storage.py')]:
        code = (ROOT / file).read_bytes()
        sources[name] = {'base64': base64.b64encode(code).decode(), 'sha256': hashlib.sha256(code).hexdigest()}
    return {'schema': 1, 'target': '10.10.10.14', 'mode': 'Plan', 'sources': sources,
            'proof': proof['base64'], 'apiKey': 'FAKE-API-KEY', 'apiSecret': 'FAKE-API-SECRET'}


class LauncherTests(unittest.TestCase):
    def test_exact_payload_and_public_proof_hash(self):
        value, proof = launcher.parse_payload(json.dumps(payload()).encode())
        self.assertEqual(value['mode'], 'Plan')
        self.assertEqual(hashlib.sha256(proof).hexdigest(), launcher.PROOF_SHA256)

    def test_wrong_target_mode_source_or_proof_is_refused(self):
        for field in ('target', 'mode', 'source', 'proof'):
            with self.subTest(field=field):
                value = payload()
                if field == 'source':
                    value['sources']['dr_recovery_acceptance']['sha256'] = '0' * 64
                elif field == 'proof':
                    value['proof'] = base64.b64encode(b'changed').decode()
                else:
                    value[field] = 'invalid'
                with self.assertRaises(ValueError):
                    launcher.parse_payload(json.dumps(value).encode())

    def test_private_journal_creation_and_parent_symlink_refusal(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            parent = Path(directory)
            fd = launcher.private_directory(parent / 'new-journal')
            os.close(fd)
            self.assertEqual((parent / 'new-journal').stat().st_mode & 0o777, 0o700)
            (parent / 'alias').symlink_to(parent / 'new-journal', target_is_directory=True)
            with self.assertRaises(OSError):
                launcher.private_directory(parent / 'alias' / 'child')

    def test_persisted_public_proof_is_immutable_and_refuses_links(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            fd = launcher.private_directory(directory)
            try:
                launcher.install_public_proof(fd, b'public proof')
                launcher.install_public_proof(fd, b'public proof')
                with self.assertRaises(ValueError):
                    launcher.install_public_proof(fd, b'changed')
                os.link(Path(directory) / 'public-proof.json', Path(directory) / 'alias')
                with self.assertRaises(ValueError):
                    launcher.install_public_proof(fd, b'public proof')
            finally:
                os.close(fd)

    @unittest.skipUnless(PWSH, 'PowerShell binary required')
    def test_actual_powershell_bundle_keeps_credentials_out_of_remote_arguments(self):
        source = (ROOT / 'invoke-dc-native-storage-registration.ps1').read_text()
        section = source[source.index('    $proof = '):source.index("    $state.status = 'SSH_OR_COLLECTOR_FAILED'")]
        fixture = '''
$ErrorActionPreference='Stop'
$Mode='Register'
$state=@{}
$known='fixture-known-hosts'
$env:CLOUDSTACK_API_KEY='FAKE-API-KEY'
$env:CLOUDSTACK_SECRET_KEY='FAKE-API-SECRET'
'''
        checks = '''
if(($sshArgs -join ' ') -match 'FAKE-API'){throw 'Credential entered command arguments'}
$decoded=$envelope|ConvertFrom-Json
if($decoded.apiSecret -cne 'FAKE-API-SECRET' -or $decoded.mode -cne 'Register'){throw 'Private input missing'}
if($remote -notmatch '^timeout 240 python3 <\(printf %s '){throw 'Wrong remote launcher'}
if($sshArgs -notcontains 'StrictHostKeyChecking=yes'){throw 'Host trust weakened'}
'PRIVATE_STDIN_BUNDLE_PASS'
$PSNativeCommandArgumentPassing='Legacy'
& python3 -c 'import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())' $remote
'''
        with tempfile.NamedTemporaryFile('w', suffix='.ps1') as script:
            script.write(fixture + section + checks)
            script.flush()
            result = subprocess.run([PWSH, '-NoProfile', '-File', script.name], cwd=ROOT.parents[1], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PRIVATE_STDIN_BUNDLE_PASS', result.stdout)
        self.assertNotIn('FAKE-API-SECRET', result.stdout + result.stderr)
        remote = base64.b64decode(result.stdout.strip().splitlines()[-1]).decode()
        self.assertNotIn(chr(34), remote)
        self.assertNotIn(chr(39), remote)
        actual = subprocess.run(['bash', '-c', remote], input=b'{}', capture_output=True, timeout=30)
        self.assertEqual(actual.returncode, 1)
        self.assertEqual(json.loads(actual.stdout)['status'], 'PRIVATE_INPUT_OR_JOURNAL_GATE')
        self.assertEqual(actual.stderr, b'')


if __name__ == '__main__':
    unittest.main()
