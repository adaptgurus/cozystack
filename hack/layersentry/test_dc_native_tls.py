import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
for name, filename in [('dc_native_storage_registration', 'register-dc-native-storage.py'), ('dc_native_tls', 'dc-native-tls.py')]:
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module; spec.loader.exec_module(module)
import dc_native_tls as tls
from dr_recovery_acceptance import Journal, GateError


class TlsCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='layersentry-tls-test-'); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.journal = Journal(self.root, {'scope': 'offline-test'}, tls.ENDPOINT); self.addCleanup(self.journal.close)
        self.expected = {'hostname': 'dc.example.test'}

    def command(self, args):
        return subprocess.run(['openssl', *args], cwd=self.root, capture_output=True, check=True, timeout=30).stdout

    def ca(self):
        self.command(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'test-ca.key', '-out', 'original-ca.pem', '-days', '1', '-subj', '/CN=Offline Test CA', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'])
        (self.root / 'original-ca.pem').chmod(0o600)
        self.expected['caSha256'] = tls.sha(tls.cert_der((self.root / 'original-ca.pem').read_bytes()))

    def sign(self, hostname='dc.example.test', ip='10.10.10.14', purpose='serverAuth'):
        (self.root / 'extensions.cnf').write_text('subjectAltName=DNS:' + hostname + ',IP:' + ip + ('\nextendedKeyUsage=' + purpose + '\nbasicConstraints=CA:FALSE' if purpose else '') + '\n')
        self.command(['x509', '-req', '-in', 'server.csr', '-CA', 'original-ca.pem', '-CAkey', 'test-ca.key', '-set_serial', '123', '-days', '1', '-extfile', 'extensions.cnf', '-out', 'server.crt'])
        (self.root / 'server.crt').chmod(0o600)

    def test_original_config_bytes_and_http_values_are_preserved(self):
        original = b'# Native server config\r\nhttp.enable=true\r\nhttp.port=8080\r\nrequest.log=arbitrary retained bytes\r\nhttps.enable=false\r\n'
        candidate = tls.config_candidate(original, 'a' * 64)
        self.assertTrue(candidate.startswith(original)); self.assertEqual(candidate.count(original), 1)
        parsed = tls.properties(candidate)
        self.assertEqual((parsed['http.enable'], parsed['http.port']), ('true', '8080'))
        self.assertEqual((parsed['https.enable'], parsed['https.port']), ('true', '8443'))
        for source in (b'http.enable=false\n', b'password.encryption.type=web\n', b'http.port=9090\n', b'https.enable=true\n', b'http\\u002eport=8080\n', b'http.port=80\\\n80\n'):
            with self.assertRaises(GateError): tls.config_candidate(source, 'a' * 64)

    def test_real_openssl_key_csr_certificate_and_server_purpose(self):
        self.ca(); binding = tls.key_prepare(self.journal, self.expected); self.sign(purpose=None)
        proof = tls.verify_certificate(self.root, self.expected)
        self.assertEqual(proof['publicKeySha256'], binding['publicKeySha256'])
        self.assertEqual(tls.key_prepare(self.journal, self.expected), binding)
        key_before = (self.root / 'server.key').read_bytes()
        for hostname, ip, purpose in [('foreign.example.test', '10.10.10.14', 'serverAuth'), ('dc.example.test', '10.10.10.20', 'serverAuth'), ('dc.example.test', '10.10.10.14', 'clientAuth')]:
            self.sign(hostname, ip, purpose)
            with self.assertRaises(GateError): tls.verify_certificate(self.root, self.expected)
        self.assertEqual((self.root / 'server.key').read_bytes(), key_before)
        self.assertNotIn('BEGIN PRIVATE KEY', json.dumps(self.journal.data))
        self.assertNotIn((self.root / 'keystore.password').read_text(), json.dumps(self.journal.data))

    def test_original_ca_and_key_substitution_are_rejected(self):
        self.ca(); tls.key_prepare(self.journal, self.expected); self.sign()
        with self.assertRaisesRegex(GateError, 'ORIGINAL_CA_CHANGED'): tls.verify_certificate(self.root, {**self.expected, 'caSha256': '0' * 64})
        self.command(['genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', 'server.key'])
        with self.assertRaises(GateError): tls.verify_certificate(self.root, self.expected)
        with self.assertRaises(GateError): tls.key_prepare(self.journal, self.expected)

    def test_ambiguous_issuance_is_not_replayed_and_journal_has_no_secret(self):
        self.ca(); key = tls.key_prepare(self.journal, self.expected)
        api = Mock(side_effect=RuntimeError('private credential must not escape'))
        for _ in range(2):
            with self.assertRaisesRegex(GateError, 'UNCERTAIN_NO_REPLAY'): tls.issue_observe(api, self.journal, self.expected, key)
        self.assertEqual(api.call_count, 1)
        self.assertNotIn('private credential', json.dumps(self.journal.data))

    def test_pending_job_only_queries_recorded_job_and_rejects_private_key_response(self):
        self.ca(); key = tls.key_prepare(self.journal, self.expected); job = str(uuid.uuid4())
        api = Mock(side_effect=[{'jobid': job}, {'jobstatus': 0}, {'jobstatus': 1, 'jobresult': {'certificates': {'privatekey': 'not allowed'}}}])
        self.assertFalse(tls.issue_observe(api, self.journal, self.expected, key))
        with self.assertRaisesRegex(GateError, 'MUST_NOT_CONTAIN_PRIVATE_KEY'): tls.issue_observe(api, self.journal, self.expected, key)
        self.assertEqual([c.args[0] for c in api.call_args_list], ['issueCertificate', 'queryAsyncJobResult', 'queryAsyncJobResult'])
        self.assertTrue(all(c.kwargs.get('jobid') == job for c in api.call_args_list[1:]))

    def test_native_response_envelope_and_csr_success_binding(self):
        self.ca(); key = tls.key_prepare(self.journal, self.expected); self.sign()
        leaf = (self.root / 'server.crt').read_text(); (self.root / 'server.crt').unlink()
        ca = (self.root / 'original-ca.pem').read_text()
        api = Mock(side_effect=[{'jobid': str(uuid.uuid4())}, {'jobstatus': 1, 'jobresult': {'certificates': {'certificate': leaf, 'cacertificates': ca}}}])
        self.assertTrue(tls.issue_observe(api, self.journal, self.expected, key))
        self.assertTrue(tls.issue_observe(api, self.journal, self.expected, key)); self.assertEqual(api.call_count, 2)
        self.assertEqual(tls.ca_read(Mock(return_value={'cacertificates': {'certificate': ca}}))[1], self.expected['caSha256'])
        with self.assertRaises(GateError): tls.ca_read(Mock(return_value={'certificate': ca}))

    def test_partial_key_creation_and_changed_password_are_not_replaced(self):
        self.journal.data['operations']['key'] = {'state': 'SUBMITTING'}; self.journal.save()
        with self.assertRaises(FileNotFoundError): tls.key_prepare(self.journal, self.expected)
        self.assertFalse((self.root / 'server.key').exists())
        self.journal.data['operations'].clear(); self.journal.save()
        tls.key_prepare(self.journal, self.expected)
        (self.root / 'keystore.password').write_text('1' * 64)
        with self.assertRaisesRegex(GateError, 'KEY_MATERIAL_CHANGED'): tls.key_prepare(self.journal, self.expected)

    def test_real_native_jks_import_export_and_drift(self):
        executable = os.environ.get('LAYERSENTRY_TEST_KEYTOOL') or shutil.which('keytool')
        if not executable: self.skipTest('real keytool executable unavailable')
        self.ca(); tls.key_prepare(self.journal, self.expected); self.sign()
        proof = tls.verify_certificate(self.root, self.expected)
        self.journal.data['operations']['issue'] = {'state': 'RECONCILED', **proof}; self.journal.save()
        tls.create_once(self.root / 'original-server.properties', b'http.enable=true\nhttp.port=8080\n')
        original_run = tls.run
        def execute(args, data=None):
            return original_run(([executable] + args[1:]) if args[0] == 'keytool' else args, data)
        with patch.object(tls, 'run', side_effect=execute):
            first = tls.keystore_prepare(self.journal, self.expected)
            self.assertEqual(first, tls.keystore_prepare(self.journal, self.expected))
            self.assertEqual((self.root / 'server.jks').read_bytes()[:4], bytes.fromhex('feedfeed'))
            content = (self.root / 'server.jks').read_bytes()
            (self.root / 'server.jks').write_bytes(content + b'changed')
            with self.assertRaisesRegex(GateError, 'KEYSTORE_BYTES_CHANGED'): tls.keystore_prepare(self.journal, self.expected)

    def test_install_intent_without_outcome_never_replays_file_publish(self):
        self.ca(); tls.key_prepare(self.journal, self.expected); self.sign()
        original = b'http.enable=true\nhttp.port=8080\n'
        candidate = tls.config_candidate(original, (self.root / 'keystore.password').read_text())
        tls.create_once(self.root / 'original-server.properties', original)
        tls.create_once(self.root / 'server.properties.candidate', candidate)
        # This unit test exercises only routing before any keystore mutation;
        # native JKS content has its separate real keytool qualification above.
        store = b'owned staged bytes'; tls.create_once(self.root / 'server.jks', store)
        target_store = self.root / 'active.jks'
        target_config = self.root / 'server.properties'; target_config.write_bytes(original)
        proof = tls.verify_certificate(self.root, self.expected)
        self.journal.data['operations']['keystore'] = {'state': 'RECONCILED', **proof, 'candidateSha256': tls.sha(candidate), 'keystoreSha256': tls.sha(store)}
        group = type('Group', (), {'gr_gid': os.getgid()})()
        self.journal.data['operations']['install-keystore'] = {'state': 'SUBMITTING', 'specification': {'path': str(target_store), 'sha256': tls.sha(store), 'uid': 0, 'gid': os.getgid(), 'mode': 0o640}}
        expected = {**self.expected, 'serverPropertiesSha256': tls.sha(original)}
        with patch.object(tls, 'validate_plan'), patch.object(tls, 'native_identity', return_value=expected['hostname']), patch.object(tls, 'ca_read', return_value=(b'', expected['caSha256'])), patch.object(tls.grp, 'getgrnam', return_value=group), patch.object(tls, 'CONFIG', target_config), patch.object(tls, 'KEYSTORE', target_store), patch.object(tls.os, 'replace') as replace:
            with self.assertRaisesRegex(GateError, 'INSTALL_UNCERTAIN_NO_REPLAY'): tls.install(Mock(), self.journal, expected)
            replace.assert_not_called()
        self.assertFalse(target_store.exists()); self.assertEqual(target_config.read_bytes(), original)

    def test_private_loader_rejects_target_source_and_mode_substitution(self):
        spec = importlib.util.spec_from_file_location('dc_native_tls_loader_test', ROOT / 'run-dc-native-tls-stdin.py')
        loader = importlib.util.module_from_spec(spec); spec.loader.exec_module(loader)
        import base64
        proof = json.loads((ROOT / 'evidence/dc-registration-public-proof-20260906.json').read_text())['base64']
        code = b'# source-contract-only'
        data = {'schema': 1, 'target': tls.TARGET, 'mode': 'Plan', 'sources': {name: {'base64': base64.b64encode(code).decode(), 'sha256': tls.sha(code)} for name in loader.SOURCES}, 'proof': proof, 'apiKey': 'unit-key', 'apiSecret': 'unit-secret', 'plan': {}, 'planSha256': '', 'firewallSources': []}
        self.assertEqual(loader.parse_payload(json.dumps(data).encode())['mode'], 'Plan')
        observation = {**data, 'mode': 'ObserveIdentity', 'apiKey': '', 'apiSecret': ''}
        self.assertEqual(loader.parse_payload(json.dumps(observation).encode())['mode'], 'ObserveIdentity')
        with self.assertRaisesRegex(ValueError, 'CREDENTIALS_FORBIDDEN'):
            loader.parse_payload(json.dumps({**observation, 'apiKey': 'not-needed'}).encode())
        for change in ({'target': '10.10.10.20'}, {'mode': 'Shell'}, {'sources': {}}, {'mode': 'Install'}, {'apiKey': ''}):
            with self.assertRaises(ValueError): loader.parse_payload(json.dumps({**data, **change}).encode())

    def test_native_bios_binding_rejects_vm_id_and_other_guest(self):
        tls.require_guest_bios('ccbcac90-c8e3-4091-90a0-7e2e8cf2f7e5')
        for value in (tls.VM_ID, '12345678-abcd-abcd-abcd-123456789abc', ''):
            with self.assertRaisesRegex(GateError, 'BIOS_UUID_MISMATCH'): tls.require_guest_bios(value)
        with patch.object(tls, 'local_dc_binding'), patch.object(tls, 'read_file', return_value=tls.VM_ID.encode()), patch.object(tls, 'run') as commands:
            with self.assertRaisesRegex(GateError, 'BIOS_UUID_MISMATCH'): tls.native_identity(Mock())
            commands.assert_not_called()

    def test_public_identity_observation_never_accepts_vm_id_as_binding(self):
        observed = '12345678-abcd-abcd-abcd-123456789abc'
        with patch.object(tls, 'local_dc_binding'), patch.object(tls, 'read_file', return_value=(observed + '\n').encode()):
            value = tls.observe_guest_identity()
        self.assertEqual(value['guestProductUuid'], observed)
        self.assertFalse(value['identityBindingEstablished'])
        self.assertFalse(value['mutationPerformed'])
        with patch.object(tls, 'local_dc_binding'), patch.object(tls, 'read_file', return_value=b'not-public-uuid'):
            with self.assertRaisesRegex(GateError, 'GUEST_UUID_SHAPE'): tls.observe_guest_identity()

    def test_file_and_firewall_scope_guards(self):
        file = self.root / 'sample'; file.write_text('bytes'); file.chmod(0o600)
        alias = self.root / 'alias'; alias.symlink_to(file)
        with self.assertRaises(GateError): tls.read_file(alias, private=True)
        hard = self.root / 'hard'; os.link(file, hard)
        with self.assertRaises(GateError): tls.read_file(file, private=True)
        self.assertEqual(tls.validate_sources(['10.10.10.20/32']), ['10.10.10.20/32'])
        for sources in (['0.0.0.0/0'], ['10.10.10.0/24'], ['10.10.11.1/32'], ['::1/128'], ['10.10.10.20/32'] * 2):
            with self.assertRaises(GateError): tls.validate_sources(sources)


if __name__ == '__main__': unittest.main()
