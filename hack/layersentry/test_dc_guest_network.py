import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent
for name, file in [('dc_native_storage_registration', 'register-dc-native-storage.py'), ('dc_guest_network', 'dc-guest-network.py')]:
    spec = importlib.util.spec_from_file_location(name, ROOT / file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
network = sys.modules['dc_guest_network']
from dr_recovery_acceptance import GateError, Journal


class GuestTests(unittest.TestCase):
    def journal(self, directory):
        os.chmod(directory, 0o700)
        return Journal(directory, {'fixed': 'dc-network'}, 'http://127.0.0.1:8080/client/api')

    def test_durable_intent_before_submission_and_effect_reconciliation(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            observed = []
            def submit():
                disk = json.loads((Path(directory) / 'journal.json').read_text())
                self.assertEqual(disk['operations']['bridge']['state'], 'SUBMITTING')
                observed.append(True)
                raise TimeoutError('PRIVATE_COMMAND_BODY')
            network.once(journal, 'bridge', {'uuid': network.BRIDGE_UUID}, lambda: bool(observed), submit)
            self.assertEqual(journal.data['operations']['bridge']['state'], 'RECONCILED')
            journal.close()

    def test_failed_submission_is_not_replayed_after_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            calls = []
            with self.assertRaisesRegex(GateError, 'NO_REPLAY'):
                network.once(journal, 'bridge', {}, lambda: False, lambda: calls.append(1))
            journal.close()
            journal = self.journal(directory)
            with self.assertRaisesRegex(GateError, 'NO_REPLAY'):
                network.once(journal, 'bridge', {}, lambda: False, lambda: calls.append(2))
            self.assertEqual(calls, [1])
            journal.close()

    def test_failed_journal_prevents_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            with patch.object(journal, 'save', side_effect=OSError), patch.object(network, 'run') as submit:
                with self.assertRaises(OSError):
                    network.once(journal, 'port', {}, lambda: False, submit)
                submit.assert_not_called()
            journal.close()

    def test_owned_autoconnect_can_reconcile_without_command_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            spec = {'port': network.PORT_UUID, 'bridge': network.BRIDGE_UUID}
            journal.data['operations']['activate'] = {'specification': spec, 'state': 'ARMED'}
            journal.save()
            with patch.object(network, 'run') as submit:
                network.once(journal, 'activate', spec, lambda: True, submit)
                submit.assert_not_called()
            journal.close()

    def test_exact_mac_binding_rejects_duplicate_management_or_addressed_interface(self):
        for links, addresses in [
            ([{'ifname': 'ens8', 'address': network.MAC}, {'ifname': 'ens9', 'address': network.MAC}], []),
            ([{'ifname': 'eth0', 'address': network.MAC}], []),
            ([{'ifname': 'ens8', 'address': network.MAC}], [{'addr_info': [{'local': '10.10.20.42'}]}]),
        ]:
            with patch.object(network, 'read_json', side_effect=[links, addresses]):
                with self.assertRaises(GateError):
                    network.guest_device(True)
        with patch.object(network, 'read_json', side_effect=[[{'ifname': 'ens8', 'address': network.MAC}], [{'addr_info': []}]]):
            self.assertEqual(network.guest_device(True), 'ens8')

    def test_profiles_have_no_bridge_l3_and_only_mac_bound_guest_port(self):
        bridge = network.desired_profile('bridge', 'ens8')
        port = network.desired_profile('port', 'ens8')
        self.assertEqual((bridge['ipv4.method'], bridge['ipv6.method']), ('disabled', 'disabled'))
        self.assertEqual(port['connection.master'], network.BRIDGE_UUID)
        self.assertEqual(port['802-3-ethernet.mac-address'].lower(), network.MAC)
        self.assertNotIn('gateway', json.dumps([bridge, port]))

    def test_plan_calls_no_command_mutator_and_keeps_nic_absence_explicit(self):
        with patch.object(network, 'management_identity', return_value={'fixed': True}), patch.object(network, 'api_scope', return_value=None), patch.object(network, 'guest_device', return_value=None), patch.object(network, 'no_profile_collisions'), patch.object(network, 'once') as mutation:
            result = network.execute(None, None, 'Plan')
            self.assertEqual(result['nicStatus'], 'NOT_ADDED')
            mutation.assert_not_called()

    def test_label_requires_both_owned_profiles_before_api_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            with patch.object(network, 'management_identity', return_value={'fixed': True}), patch.object(network, 'api_scope', return_value=None), patch.object(network, 'guest_device', return_value='ens8'), patch.object(network, 'no_profile_collisions'), patch.object(network, 'profile_observed', return_value=False), patch.object(network, 'once') as mutation:
                with self.assertRaisesRegex(GateError, 'PROFILES_NOT_READY'):
                    network.execute(None, journal, 'Label')
                mutation.assert_not_called()
            journal.close()


@unittest.skipUnless(os.environ.get('POWERSHELL_TEST_BINARY'), 'PowerShell execution required')
class HyperVTests(unittest.TestCase):
    def test_actual_hyperv_controller_journals_and_preserves_management(self):
        result = subprocess.run([os.environ['POWERSHELL_TEST_BINARY'], '-NoProfile', '-File', str(ROOT / 'test-dc-guest-network.ps1')], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DC_GUEST_NETWORK_TESTS_PASS', result.stdout)

    def test_actual_legacy_ssh_bundle_and_private_loader(self):
        source = (ROOT / 'invoke-dc-guest-network-ssh.ps1').read_text()
        section = source[source.index('    $proof = '):source.index("    $state.status = 'SSH_OR_COLLECTOR_FAILED'")]
        pre = "$ErrorActionPreference='Stop';$Mode='Plan';$state=@{};$known='fixture';$env:CLOUDSTACK_API_KEY='PRIVATE_TEST_KEY';$env:CLOUDSTACK_SECRET_KEY='PRIVATE_TEST_SECRET'\n"
        post = """
if(($sshArgs -join ' ') -match 'PRIVATE_TEST'){throw 'Secret in arguments'}
$payload=$envelope|ConvertFrom-Json
if($payload.sources.PSObject.Properties.Name.Count -ne 4){throw 'Wrong source bundle'}
$PSNativeCommandArgumentPassing='Legacy'
& python3 -c 'import base64,sys;print(base64.b64encode(sys.argv[1].encode()).decode())' $remote
"""
        with tempfile.NamedTemporaryFile('w', suffix='.ps1') as file:
            file.write(pre + section + post)
            file.flush()
            ps = subprocess.run([os.environ['POWERSHELL_TEST_BINARY'], '-NoProfile', '-File', file.name], cwd=ROOT.parents[1], capture_output=True, text=True, timeout=20)
        self.assertEqual(ps.returncode, 0, ps.stderr)
        command = base64.b64decode(ps.stdout.strip()).decode()
        process = subprocess.run(['bash', '-c', command], input='{}', capture_output=True, text=True, timeout=10)
        self.assertEqual(process.returncode, 1)
        self.assertEqual(json.loads(process.stdout)['status'], 'PRIVATE_INPUT_OR_NETWORK_GATE')
        self.assertFalse(process.stderr)
