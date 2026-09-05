import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('remote', Path(__file__).with_name('dr-management-remote.py'))
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.request = {'request_id': 'dr-first-node', 'source_sha': 'a' * 40,
                        'configuration': {'mode': 'combined', 'db_host': 'localhost',
                                          'management_ip': '10.10.10.20', 'initialize_database': True},
                        'repositories': {'cloudstack.repo': '[cloudstack]\n'}}
        self.action = {'request': 'hack/layersentry/dr-management-requests/dr-first-node.json',
                       'phase': 'Preflight', 'authorization': ''}

    def test_valid_phases_and_explicit_apply_authorization(self):
        for phase in ('Preflight', 'Status', 'Apply'):
            self.action.update(phase=phase, authorization='dr-first-node:Apply' if phase == 'Apply' else '')
            remote.validate_request(self.request, self.action)
        self.action['authorization'] = ''
        with self.assertRaises(ValueError):
            remote.validate_request(self.request, self.action)

    def test_target_and_credential_injection_rejected(self):
        for key, value in [('management_ip', '10.10.10.21'), ('mode', 'external'),
                           ('db_host', 'remote.example'), ('db_password', 'secret'),
                           ('repo_files', ['/etc/shadow']), ('initialize_database', False)]:
            with self.subTest(key=key):
                request = copy.deepcopy(self.request)
                request['configuration'][key] = value
                with self.assertRaises(ValueError):
                    remote.validate_request(request, self.action)

    def test_repository_traversal_rejected(self):
        for filename in ('../evil.repo', '/etc/yum.repos.d/evil.repo', 'a;touch.repo'):
            self.request['repositories'] = {filename: 'content'}
            with self.assertRaises(ValueError):
                remote.validate_request(self.request, self.action)

    def test_receipt_binds_source_config_repositories_and_certificate(self):
        original = remote.fingerprint(self.request, b'certificate')
        for key, value in [('source_sha', 'b' * 40), ('repositories', {'new.repo': 'changed'})]:
            request = copy.deepcopy(self.request)
            request[key] = value
            self.assertNotEqual(original, remote.fingerprint(request, b'certificate'))
        self.assertNotEqual(original, remote.fingerprint(self.request, b'other certificate'))

    def test_journal_evidence_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'journal.json'
            path.write_text('{"stages":{"database":"applied","password":"secret","management":"secret"}}')
            with patch.object(remote, 'JOURNAL', path):
                self.assertEqual({'database': 'applied'}, remote.journal_stages())

    def test_unknown_fields_and_unpinned_source_rejected(self):
        for key, value in [('source_sha', 'main'), ('secret', 'sensitive')]:
            request = copy.deepcopy(self.request)
            request[key] = value
            with self.assertRaises(ValueError):
                remote.validate_request(request, self.action)

    def test_apply_receipt_rejects_drift_expiry_and_future(self):
        remote.validate_receipt({'fingerprint': 'same', 'passed_at': 100000}, 'same', 100001)
        for receipt in ({'fingerprint': 'changed', 'passed_at': 100000},
                        {'fingerprint': 'same', 'passed_at': 0},
                        {'fingerprint': 'same', 'passed_at': 200000}):
            with self.assertRaises(ValueError):
                remote.validate_receipt(receipt, 'same', 100001)

    def test_failure_never_publishes_exception_or_native_output(self):
        captured = io.StringIO()
        with patch.object(remote.sys, 'argv', ['remote.py', '/invalid']), \
                patch.object(remote, 'execute', side_effect=RuntimeError('password=SUPERSECRET')), \
                patch.object(remote, 'journal_stages', return_value={}), \
                contextlib.redirect_stdout(captured):
            self.assertEqual(1, remote.main())
        result = json.loads(captured.getvalue())
        self.assertEqual('failed', result['outcome'])
        self.assertNotIn('SUPERSECRET', captured.getvalue())


if __name__ == '__main__':
    unittest.main()
