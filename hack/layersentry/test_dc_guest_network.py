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

    def test_complete_bridge_and_label_path_retains_management_and_reconciles_repeat(self):
        state = {'profiles': {}, 'active': False, 'label': None, 'mutations': []}
        def command(args):
            if args[:3] == ['ip', '-j', '-4'] and 'route' in args:
                return json.dumps([{'dst': 'default', 'gateway': '10.10.10.1', 'dev': 'cloudbr0'}])
            if args[0] == 'ip' and 'address' in args:
                info = [{'local': '10.10.10.14', 'prefixlen': 24}] if args[-1] == 'cloudbr0' else []
                return json.dumps([{'addr_info': info}])
            if args[0] == 'ip':
                links = [{'ifname': 'cloudbr0', 'ifindex': 4}, {'ifname': 'eth0', 'ifindex': 2, 'master': 'cloudbr0', 'address': '00:15:5d:00:39:0a'}, {'ifname': 'ens8', 'ifindex': 8, 'address': network.MAC}]
                if state['active']:
                    links[-1]['master'] = network.BRIDGE
                    links.append({'ifname': network.BRIDGE, 'ifindex': 9, 'linkinfo': {'info_kind': 'bridge'}, 'flags': ['UP']})
                return json.dumps(links)
            if args[:3] == ['nmcli', '-g', 'UUID']:
                return '\n'.join(state['profiles'])
            if args[:2] == ['nmcli', '-g']:
                return state['profiles'][args[-1]][args[2]]
            state['mutations'].append(args)
            if args[:3] == ['nmcli', 'connection', 'add']:
                fields = dict(zip(args[5::2], args[6::2]))
                fields['connection.type'] = 'bridge' if args[4] == 'bridge' else '802-3-ethernet'
                state['profiles'][fields['connection.uuid']] = fields
                return ''
            if args == ['nmcli', '--wait', '20', 'connection', 'up', 'uuid', network.PORT_UUID]:
                state['active'] = True
                return ''
            raise AssertionError(args)
        def api(command, **params):
            self.assertEqual(command, 'updateTrafficType')
            self.assertEqual(params, {'id': network.GUEST, 'kvmnetworklabel': network.BRIDGE})
            state['mutations'].append(command)
            state['label'] = network.BRIDGE
            return {}
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            with patch.object(network, 'run', side_effect=command), patch.object(network, 'api_scope', side_effect=lambda _: state['label']):
                result = network.execute(api, journal, 'Bridge')
                self.assertTrue(result['managementPreserved'])
                self.assertFalse(state['active'])
                self.assertIsNone(state['label'])
                result = network.execute(api, journal, 'Label')
                self.assertEqual(result['guestLabel'], network.BRIDGE)
                self.assertTrue(result['managementPreserved'])
                count = len(state['mutations'])
                network.execute(api, journal, 'Label')
                self.assertEqual(len(state['mutations']), count)
            journal.close()

    def test_exact_unused_default_profile_disable_is_journaled_and_preserved(self):
        properties = {'connection.id': 'Wired connection 1', 'connection.uuid': network.DEFAULT_UUID,
                      'connection.type': '802-3-ethernet', 'connection.interface-name': 'eth1',
                      'connection.master': '', 'connection.slave-type': '', '802-3-ethernet.mac-address': '',
                      'ipv4.method': 'auto', 'ipv6.method': 'auto', 'connection.timestamp': '0',
                      'GENERAL.STATE': '', 'GENERAL.DEVICES': '', 'connection.autoconnect': 'yes'}
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            calls = []
            def command(args):
                self.assertEqual(json.loads((Path(directory) / 'journal.json').read_text())['operations'][network.DEFAULT_OPERATION]['state'], 'SUBMITTING')
                self.assertEqual(args, ['nmcli', 'connection', 'modify', 'uuid', network.DEFAULT_UUID, 'connection.autoconnect', 'no'])
                calls.append(args)
                properties['connection.autoconnect'] = 'no'
            with patch.object(network, 'profiles', return_value=[network.DEFAULT_UUID]), patch.object(network, 'prop', side_effect=lambda _, field: properties[field]), patch.object(network, 'run', side_effect=command):
                network.disable_default_autoconnect('eth1', journal)
                network.disable_default_autoconnect('eth1', journal)
                self.assertEqual(len(calls), 1)
                self.assertEqual(properties['connection.id'], 'Wired connection 1')
                for field, value in [('GENERAL.STATE', 'activated'), ('connection.timestamp', '1'), ('connection.interface-name', 'eth0')]:
                    original = properties[field]
                    properties[field] = value
                    with self.assertRaisesRegex(GateError, 'IDENTITY_OR_ACTIVITY_CHANGED'):
                        network.disable_default_autoconnect('eth1', journal)
                    properties[field] = original
                self.assertEqual(len(calls), 1)
            journal.close()

    def test_default_profile_failed_modify_is_not_replayed(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            with patch.object(network, 'profiles', return_value=[network.DEFAULT_UUID]), patch.object(network, 'default_profile_autoconnect', return_value='yes'), patch.object(network, 'run') as command:
                for _ in range(2):
                    with self.assertRaisesRegex(GateError, 'NO_REPLAY'):
                        network.disable_default_autoconnect('eth1', journal)
                self.assertEqual(command.call_count, 1)
            journal.close()

    def test_journaled_default_profile_disappearance_stops_without_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = self.journal(directory)
            journal.data['operations'][network.DEFAULT_OPERATION] = {'state': 'RECONCILED'}
            journal.save()
            with patch.object(network, 'profiles', return_value=[]), patch.object(network, 'run') as command:
                with self.assertRaisesRegex(GateError, 'JOURNALED_DEFAULT_PROFILE_DISAPPEARED'):
                    network.disable_default_autoconnect('eth1', journal)
                command.assert_not_called()
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
