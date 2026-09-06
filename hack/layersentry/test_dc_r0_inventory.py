import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('dc_inventory', ROOT / 'collect-dc-r0-readonly.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class InventoryTests(unittest.TestCase):
    def test_commands_have_timeout_and_never_publish_stderr(self):
        with patch.object(collector.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, 'password=private', 'private')) as run:
            result = collector.command(['rpm', '-q', 'cloudstack-agent'])
        self.assertEqual(result, {'status': 'UNAVAILABLE', 'exitCode': 1})
        self.assertEqual(run.call_args.kwargs['timeout'], 8)
        self.assertNotIn('private', json.dumps(result))

    def test_timeout_and_missing_command_are_explicit(self):
        for exception, expected in [(subprocess.TimeoutExpired('rpm', 8), 'TIMEOUT'), (FileNotFoundError(), 'UNAVAILABLE')]:
            with self.subTest(expected=expected), patch.object(collector.subprocess, 'run', side_effect=exception):
                self.assertEqual(collector.command(['rpm'])['status'], expected)

    def test_output_limit(self):
        with patch.object(collector.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'x' * 1048577, '')):
            self.assertEqual(collector.command(['rpm']), {'status': 'OUTPUT_LIMIT'})

    def test_json_projection_omits_unrequested_fields_and_credentials(self):
        data = {'filesystems': [{'target': '/export/secondary', 'source': '10.10.10.20:/export/secondary', 'fstype': 'nfs4', 'options': 'password=private'},
                                {'source': '//user:private@server/share', 'fstype': 'cifs'}]}
        with patch.object(collector, 'command', return_value={'status': 'OK', 'output': json.dumps(data)}):
            result = collector.json_inventory(['findmnt'], {'filesystems', 'target', 'source', 'fstype'})
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(result['data']['filesystems'][0]['source'], '10.10.10.20:/export/secondary')
        self.assertEqual(result['data']['filesystems'][1]['source'], '[OMITTED]')

    def test_invalid_json_and_control_character_names_are_not_published(self):
        with patch.object(collector, 'command', return_value={'status': 'OK', 'output': 'private not json'}):
            self.assertEqual(collector.json_inventory([], set()), {'status': 'INVALID_OUTPUT'})
        with patch.object(collector, 'command', return_value={'status': 'OK', 'output': 'host\x1b[31mprivate'}):
            self.assertEqual(collector.text_inventory([]), {'status': 'INVALID_OUTPUT'})

    def test_wrong_host_or_nonroot_stops_before_inventory(self):
        for uid, local in [(0, '10.10.10.20'), (1000, '10.10.10.14')]:
            with self.subTest(uid=uid, local=local), patch.object(collector.os, 'geteuid', return_value=uid), \
                    patch.object(collector, 'json_inventory', return_value={'status': 'OK', 'data': [{'addr_info': [{'local': local}]}]}), \
                    patch.object(collector, 'text_inventory') as text:
                result = collector.collect()
                self.assertEqual(result['status'], 'TARGET_BINDING_FAILED')
                text.assert_not_called()

    def test_bound_host_collects_named_readonly_libvirt_and_services(self):
        with patch.object(collector.os, 'geteuid', return_value=0), \
                patch.object(collector, 'json_inventory', return_value={'status': 'OK', 'data': [{'addr_info': [{'local': '10.10.10.14'}]}]}), \
                patch.object(collector, 'text_inventory', return_value={'status': 'OK', 'values': ['active']}) as text, \
                patch.object(collector, 'path_inventory', return_value={}), \
                patch.object(collector, 'templates', return_value={}):
            result = collector.collect()
        self.assertEqual(result['status'], 'COLLECTED')
        self.assertFalse(result['mutationPerformed'])
        commands = [call.args[0] for call in text.call_args_list]
        self.assertIn(['virsh', '--readonly', '-c', 'qemu:///system', 'list', '--all', '--name'], commands)
        self.assertIn(['systemctl', 'show', '--property=ActiveState', '--value', 'cloudstack-agent'], commands)

    def test_template_presence_without_reading_contents_or_following_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'template.properties').write_text('private metadata')
            (root / 'disk.qcow2').write_bytes(b'fake image')
            (root / 'linked.qcow2').symlink_to(root / 'disk.qcow2')
            result = collector.templates(root)
        self.assertEqual({item['name'] for item in result['files']}, {'template.properties', 'disk.qcow2'})
        self.assertNotIn('private', json.dumps(result))

    def test_template_missing_and_scan_limit_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(collector.templates(root / 'missing')['status'], 'ABSENT_OR_SYMLINK')
            for number in range(129):
                (root / f'{number}.qcow2').touch()
            result = collector.templates(root)
        self.assertEqual(result['status'], 'TRUNCATED')
        self.assertEqual(len(result['files']), 128)

    def test_workflow_requires_explicit_request_and_pinned_target_trust(self):
        workflow = (ROOT.parents[1] / '.github/workflows/layersentry-dc-r0-host-inventory.yml').read_text()
        wrapper = (ROOT / 'invoke-dc-r0-host-inventory.ps1').read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertIn('branches: [codex/dr-dc-trust]', workflow)
        self.assertIn('Exactly one new immutable inventory request is required.', workflow)
        self.assertIn('DC-R0-READ-ONLY-INVENTORY', workflow)
        self.assertIn('ref: ${{ github.sha }}', workflow)
        self.assertIn('StrictHostKeyChecking=yes', wrapper)
        self.assertIn('LAYERSENTRY_DC_SSH_KNOWN_HOSTS', workflow)
        self.assertLess(wrapper.index('SSH_TRUST_PREREQUISITE_MISSING'), wrapper.index('& ssh.exe'))
        self.assertIn("$env:ROCKY_HOST -cne '10.10.10.14'", wrapper)
        self.assertIn("$env:ROCKY_USERNAME -cne 'root'", wrapper)
        for forbidden in ('StrictHostKeyChecking=no', 'accept-new', 'ssh-keyscan', 'authorized_keys', 'SendKeys', 'echo %ROCKY_PASSWORD%'):
            self.assertNotIn(forbidden, wrapper)


if __name__ == '__main__':
    unittest.main()
