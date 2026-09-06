"""Guard and interruption tests; no host package/service operations."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('drprep', Path(__file__).with_name('prepare-dr-libvirt-validation.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrerequisiteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.calls = []
        self.before = {'rocky': '9.8', 'security': {'selinux': 'Enforcing', 'firewalld': 'active'}, 'addresses': [], 'links': []}

    def tearDown(self):
        self.temp.cleanup()

    def command(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if argv[0] == 'rpm':
            return '\n'.join(name + ' 0:1.0-1.x86_64' for name in module.PACKAGES)
        if argv[0] == 'python3':
            return '{"libvirt":10000000,"qemu":10000000,"domains":0}'
        return ''

    def run_prepare(self, run='123', baseline=None, command=None):
        with patch.object(module, 'baseline', baseline or (lambda: self.before)), \
             patch.object(module, 'journal_directory', lambda: os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)), \
             patch.object(module, 'command', command or self.command):
            return module.prepare(run)

    def test_success_signed_packages_and_local_sockets_only(self):
        result = self.run_prepare()
        self.assertEqual(result['status'], 'PREREQUISITES_VERIFIED')
        self.assertTrue(result['securityPreserved'])
        install = self.calls[0][0]
        self.assertEqual(install[0], 'dnf')
        self.assertIn('--disablerepo=*', install)
        self.assertIn('--setopt=*.gpgcheck=1', install)
        self.assertIn('--setopt=*.sslverify=1', install)
        self.assertEqual(self.calls[1][0], ['systemctl', 'start', *module.SOCKETS])
        self.assertTrue((self.root / '123-finished.json').exists())
        self.assertFalse(result['diskFormatted'])
        self.assertFalse(result['guestCreated'])

    def test_security_or_target_failure_does_not_install(self):
        def refuse():
            raise module.Refused('TARGET_MISMATCH')
        result = self.run_prepare(baseline=refuse)
        self.assertEqual(result['status'], 'REFUSED_BEFORE_PACKAGES')
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_uncertain_install_preserves_journal_and_prevents_replay(self):
        def fail(argv, **kwargs):
            self.calls.append(argv)
            raise TimeoutError('sensitive details omitted')
        result = self.run_prepare(command=fail)
        self.assertEqual(result['status'], 'FAILED_REQUIRES_INSPECTION')
        self.assertEqual(result['reason'], 'TimeoutError')
        self.assertTrue((self.root / '123-started.json').exists())
        self.assertFalse((self.root / '123-finished.json').exists())
        next_result = self.run_prepare('124')
        self.assertEqual(next_result['reason'], 'PREVIOUS_ATTEMPT_REQUIRES_INSPECTION')
        self.assertEqual(len(self.calls), 1)

    def test_exact_attempt_cannot_replay_after_success(self):
        self.run_prepare()
        previous = len(self.calls)
        result = self.run_prepare()
        self.assertEqual(result['reason'], 'FileExistsError')
        self.assertEqual(len(self.calls), previous)

    def test_domain_conflict_does_not_claim_ready(self):
        def occupied(argv, **kwargs):
            return '123-domain' if argv[0] == 'virsh' else self.command(argv, **kwargs)
        result = self.run_prepare(command=occupied)
        self.assertEqual(result['reason'], 'EXISTING_DOMAIN_CONFLICT')
        self.assertFalse((self.root / '123-finished.json').exists())

    def test_changed_host_security_or_network_cannot_pass(self):
        values = iter([self.before, {**self.before, 'links': ['changed']}])
        result = self.run_prepare(baseline=lambda: next(values))
        self.assertEqual(result['reason'], 'HOST_BASELINE_CHANGED')
        self.assertNotIn('securityPreserved', result)

    def test_reconciliation_requires_exact_single_unfinished_attempt(self):
        (self.root / '111-started.json').write_text('{}')
        with patch.object(module, 'baseline', lambda: self.before), \
             patch.object(module, 'journal_directory', lambda: os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)), \
             patch.object(module, 'command', self.command):
            result = module.reconcile_socket('222', '110')
        self.assertEqual(result['reason'], 'EXACT_UNFINISHED_ATTEMPT_REQUIRED')
        self.assertFalse(result['mutationAttempted'])
        self.assertEqual(self.calls, [])

    def test_reconciliation_rejects_same_or_non_numeric_attempt(self):
        for run, prior in [('123', '123'), ('124', '../123')]:
            with self.assertRaises(module.Refused):
                module.reconcile_socket(run, prior)
        self.assertEqual(self.calls, [])

    def test_run_identity_rejected_before_commands(self):
        with self.assertRaises(module.Refused):
            self.run_prepare('../124')
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
