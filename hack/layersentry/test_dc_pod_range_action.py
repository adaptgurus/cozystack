import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import yaml
from unittest.mock import patch

ROOT = Path(__file__).parent
for name, file in [('dc_native_storage_registration', 'register-dc-native-storage.py'), ('dc_pod_range', 'dc-pod-range.py'), ('pod_action_loader', 'run-dc-pod-range-apply-stdin.py')]:
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
controller = sys.modules['dc_pod_range']
loader = sys.modules['pod_action_loader']
import dr_recovery_acceptance as native


class ActionTests(unittest.TestCase):
    def binding(self):
        return loader.fixture_binding(controller)

    def receipts(self):
        return {name: (ROOT / 'evidence' / ('lab-pod-reviewed-' + name + '.json')).read_bytes() for name in controller.LAB_RECEIPTS}

    def journal(self, directory):
        os.chmod(directory, 0o700)
        return native.Journal(directory, self.binding(), 'http://10.10.10.14:8080/client/api')

    def test_observe_absence_creates_no_directory_or_file(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'absent'
            observed = loader.ReadOnlyJournal(str(target), self.binding(), 'http://10.10.10.14:8080/client/api', native)
            self.assertFalse(target.exists())
            self.assertFalse(observed.exists)
            self.assertEqual(loader.public_operation(observed, controller, native), {'state': 'NOT_SUBMITTED'})
            observed.close()

    def test_observe_preserves_bytes_rejects_active_writer_and_wrong_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            with self.assertRaises(BlockingIOError):
                loader.ReadOnlyJournal(directory, self.binding(), 'http://10.10.10.14:8080/client/api', native)
            journal.close()
            before = {p.name: p.read_bytes() for p in Path(directory).iterdir()}
            observed = loader.ReadOnlyJournal(directory, self.binding(), 'http://10.10.10.14:8080/client/api', native)
            observed.close()
            self.assertEqual(before, {p.name: p.read_bytes() for p in Path(directory).iterdir()})
            with self.assertRaisesRegex(native.GateError, 'BINDING'):
                loader.ReadOnlyJournal(directory, {'wrong': True}, 'http://10.10.10.14:8080/client/api', native)

    def test_observe_rejects_symlink_and_hardlink_journal(self):
        for mode in ('symlink', 'hardlink'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                journal = self.journal(directory)
                journal.close()
                path = Path(directory) / 'journal.json'
                if mode == 'symlink':
                    path.rename(Path(directory) / 'real')
                    path.symlink_to(Path(directory) / 'real')
                else:
                    os.link(path, Path(directory) / 'alias')
                with self.assertRaises((OSError, native.GateError)):
                    loader.ReadOnlyJournal(directory, self.binding(), 'http://10.10.10.14:8080/client/api', native)

    def test_unknown_submission_is_never_replayed_and_observer_queries_only_known_job(self):
        job = '9eebba10-0c37-42c9-8b56-3e39bc10145f'
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            calls = []
            def submit(command, **params):
                calls.append(command)
                if command == 'updatePodManagementNetworkIpRange':
                    disk = json.loads((Path(directory) / 'journal.json').read_text())
                    self.assertEqual(disk['operations']['pod-range']['state'], 'SUBMITTING')
                    return {'jobid': job}
                raise TimeoutError('PRIVATE_FAILURE')
            with patch.object(controller, 'observe_lab', return_value=controller.OLD):
                with self.assertRaisesRegex(native.GateError, 'NO_REPLAY'):
                    controller.execute_lab(submit, self.receipts(), controller.LAB_RESERVATION, journal, True)
            journal.close()
            observed = loader.ReadOnlyJournal(directory, self.binding(), 'http://10.10.10.14:8080/client/api', native)
            before = (Path(directory) / 'journal.json').read_bytes()
            def query(command, **params):
                self.assertEqual((command, params), ('queryAsyncJobResult', {'jobid': job}))
                return {'jobstatus': 1}
            with patch.object(controller, 'observe_lab', return_value=controller.NEW):
                result = loader.observe_result(query, observed, self.receipts(), controller.LAB_RESERVATION, controller, native)
            self.assertEqual(result['journalOperation']['state'], 'SUBMISSION_UNCERTAIN')
            self.assertEqual(result['journalOperation']['nativeJobStatus'], 1)
            self.assertFalse(result['journalWritesPerformed'])
            self.assertEqual(before, (Path(directory) / 'journal.json').read_bytes())
            observed.close()
            journal = self.journal(directory)
            with patch.object(controller, 'observe_lab', return_value=controller.OLD):
                with self.assertRaisesRegex(native.GateError, 'NO_REPLAY'):
                    controller.execute_lab(lambda *a, **kw: self.fail('Replay'), self.receipts(), controller.LAB_RESERVATION, journal, True)
            journal.close()
            self.assertEqual(calls.count('updatePodManagementNetworkIpRange'), 1)

    def test_only_exact_owned_job_is_allowed_and_other_jobs_block(self):
        own = '9eebba10-0c37-42c9-8b56-3e39bc10145f'
        jobs = [{'jobid': own}]
        def rows(api, command, kind, **params):
            return [{'name': params['name'], 'value': 'false'}] if command == 'listConfigurations' else jobs
        with patch.object(controller, 'observe_scope', return_value=controller.OLD), patch.object(controller, 'rows', side_effect=rows):
            self.assertEqual(controller.observe_lab(None, own), controller.OLD)
            jobs.append({'jobid': 'unrelated'})
            with self.assertRaisesRegex(native.GateError, 'PENDING_NATIVE'):
                controller.observe_lab(None, own)
            jobs[:] = [{'jobid': own}]
            with self.assertRaisesRegex(native.GateError, 'PENDING_NATIVE'):
                controller.observe_lab(None)

    def test_original_plan_bytes_are_required_before_source_loading(self):
        proof = json.loads((ROOT / 'evidence/dc-registration-public-proof-20260906.json').read_text())['base64']
        code = b'pass\n'
        payload = {'schema': 1, 'target': '10.10.10.14', 'mode': 'Observe',
                   'sources': {name: {'base64': base64.b64encode(code).decode(), 'sha256': hashlib.sha256(code).hexdigest()} for name in loader.SOURCES},
                   'proof': proof, 'apiKey': 'fixture', 'apiSecret': 'fixture', 'labReceipts': {}, 'reservation': controller.LAB_RESERVATION,
                   'reviewedPlan': base64.b64encode((ROOT / 'evidence/dc-pod-reviewed-plan.json').read_bytes()).decode()}
        loader.parse_payload(json.dumps(payload).encode())
        payload['reviewedPlan'] = base64.b64encode(b'{}').decode()
        with self.assertRaisesRegex(ValueError, 'REVIEWED_PLAN_DIGEST'):
            loader.parse_payload(json.dumps(payload).encode())


@unittest.skipUnless(os.environ.get('POWERSHELL_TEST_BINARY'), 'PowerShell execution required')
class TransportTests(unittest.TestCase):
    def test_actual_legacy_apply_observe_private_transport(self):
        source = (ROOT / 'invoke-dc-pod-range-apply-ssh.ps1').read_text()
        section = source[source.index('    $proof = '):source.index("    $state.status = 'SSH_OR_COLLECTOR_FAILED'")]
        for mode in ('Apply', 'Observe'):
            pre = "$ErrorActionPreference='Stop';$Mode='" + mode + "';$state=@{};$known='fixture';$env:CLOUDSTACK_API_KEY='PRIVATE_TEST_KEY';$env:CLOUDSTACK_SECRET_KEY='PRIVATE_TEST_SECRET'\n"
            post = """
if(($sshArgs -join ' ') -match 'PRIVATE_TEST'){throw 'Secret in arguments'}
$payload=$envelope|ConvertFrom-Json
if($payload.labReceipts.PSObject.Properties.Name.Count -ne 3 -or -not $payload.reviewedPlan){throw 'Missing receipts'}
$PSNativeCommandArgumentPassing='Legacy'
& python3 -c 'import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())' $remote
"""
            with tempfile.NamedTemporaryFile('w', suffix='.ps1') as file:
                file.write(pre + section + post)
                file.flush()
                ps = subprocess.run([os.environ['POWERSHELL_TEST_BINARY'], '-NoProfile', '-File', file.name], cwd=ROOT.parents[1], capture_output=True, text=True, timeout=20)
            self.assertEqual(ps.returncode, 0, ps.stderr)
            process = subprocess.run(['bash', '-c', base64.b64decode(ps.stdout.strip()).decode()], input='{}', capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 1)
            self.assertEqual(json.loads(process.stdout)['status'], 'PRIVATE_INPUT_OR_NETWORK_GATE')
            self.assertFalse(process.stderr)

    def test_actual_workflow_guard_rejects_wrong_phase_or_plan(self):
        workflow=yaml.safe_load((ROOT.parents[1]/'.github/workflows/layersentry-dc-pod-range-action.yml').read_text())
        source=workflow['jobs']['plan']['steps'][1]['run']
        for mode, valid_hash, expected in [('Apply', True, True), ('Observe', True, True), ('Plan', True, False), ('Apply', False, False)]:
            with self.subTest(mode=mode, valid_hash=valid_hash), tempfile.TemporaryDirectory() as directory:
                request=Path(directory)/'hack/layersentry/dc-pod-range-actions/fixture.json'
                request.parent.mkdir(parents=True)
                request.write_text(json.dumps({'schema':1,'target':'10.10.10.14','mode':mode,'authorization':'DC-POD-EXCLUSIVE-LAB-ACTION','planSha256':loader.PLAN_SHA256 if valid_hash else '0'*64,'reservation':controller.LAB_RESERVATION}))
                entry=Path(directory)/'hack/layersentry/invoke-dc-pod-range-apply-ssh.ps1'
                entry.write_text("param([string]$Mode)\nSet-Content -LiteralPath invoked.txt -Value $Mode")
                script=Path(directory)/'guard.ps1'
                script.write_text("function git { $global:LASTEXITCODE=0; 'hack/layersentry/dc-pod-range-actions/fixture.json' }\n"+source)
                env=dict(os.environ,GITHUB_REPOSITORY='adaptgurus/cozystack',GITHUB_REF='refs/heads/codex/dr-dc-trust',GITHUB_EVENT_NAME='push',GITHUB_SHA='fixture')
                result=subprocess.run([os.environ['POWERSHELL_TEST_BINARY'],'-NoProfile','-File',str(script)],cwd=directory,env=env,capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode==0,expected,result.stderr if expected else '')
                self.assertEqual((Path(directory)/'invoked.txt').exists(),expected)
