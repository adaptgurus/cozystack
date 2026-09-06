import importlib.util
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT))
spec = importlib.util.spec_from_file_location('dc_registration', ROOT / 'register-dc-native-storage.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

PRIMARY = runner.NATIVE_PRIMARY_UUID
IMAGE = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'


def resource(key):
    s = runner.RESOURCES[key]
    r = {'id': PRIMARY if key == 'primary' else IMAGE, 'name': s['params']['name'], 'zoneid': runner.ZONE}
    if key == 'primary':
        r.update(ipaddress=runner.DC, path='/export/primary', podid=runner.POD, clusterid=runner.CLUSTER,
                 scope='CLUSTER', type='NetworkFilesystem', state='Up')
    else:
        r.update(url=s['params']['url'], protocol='nfs', providername='NFS', scope='ZONE')
    return r


class Api:
    def __init__(self, directory):
        self.directory = directory
        self.storage = {'primary': [], 'image': []}
        self.mutations = []
        self.timeout = False
        self.apply = True
        self.zone_state = 'Disabled'
        self.report_count = None

    def __call__(self, command, **params):
        fixtures = {
            'listZones': ('zone', {'id': runner.ZONE, 'networktype': 'Basic', 'allocationstate': self.zone_state}),
            'listPods': ('pod', {'id': runner.POD, 'zoneid': runner.ZONE, 'allocationstate': 'Enabled'}),
            'listClusters': ('cluster', {'id': runner.CLUSTER, 'zoneid': runner.ZONE, 'podid': runner.POD,
                                         'hypervisortype': 'KVM', 'allocationstate': 'Enabled'}),
            'listHosts': ('host', {'id': runner.HOST, 'zoneid': runner.ZONE, 'podid': runner.POD,
                                  'clusterid': runner.CLUSTER, 'hypervisor': 'KVM', 'state': 'Up', 'resourcestate': 'Enabled'})}
        if command in fixtures:
            kind, row = fixtures[command]
            return {kind: [row], 'count': 1}
        for key, spec in runner.RESOURCES.items():
            if command == spec['list']:
                return {spec['kind']: list(self.storage[key]), 'count': len(self.storage[key]) if self.report_count is None else self.report_count}
            if command == spec['create']:
                # Actual filesystem journal must contain the exact intent before API invocation.
                persisted = json.loads((self.directory / 'journal.json').read_text())['operations'][key]
                assert persisted['state'] == 'SUBMITTING'
                assert persisted['command'] == command and persisted['params'] == params
                self.mutations.append(command)
                if self.apply:
                    self.storage[key] = [resource(key)]
                if self.timeout:
                    raise TimeoutError('private API response must not escape')
                return {spec['kind']: resource(key)}
        raise AssertionError('Unapproved command ' + command)


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        os.chmod(self.directory, 0o700)
        self.api = Api(self.directory)
        self.journal = runner.Journal(self.directory, {'fixed': 'fixture'}, runner.ENDPOINT)

    def tearDown(self):
        self.journal.close()
        self.temp.cleanup()

    def test_read_only_proposal_and_existing_identity_do_not_create(self):
        self.assertEqual(runner.register_one(self.api, self.journal, 'primary')['status'], 'PROPOSED')
        self.api.storage['primary'] = [resource('primary')]
        self.assertEqual(runner.register_one(self.api, self.journal, 'primary', True)['status'], 'OBSERVED_EXISTING')
        self.assertEqual(self.api.mutations, [])

    def test_real_durable_intent_before_two_exact_native_calls(self):
        guard = Mock()
        for key in ('primary', 'image'):
            self.assertEqual(runner.register_one(self.api, self.journal, key, True, guard)['status'], 'RECONCILED')
        self.assertEqual(self.api.mutations, ['createStoragePool', 'addImageStore'])
        self.assertEqual(guard.call_count, 4)

    def test_timeout_with_effect_reconciles_without_second_submission(self):
        self.api.timeout = True
        result = runner.register_one(self.api, self.journal, 'primary', True)
        self.assertEqual(result['id'], PRIMARY)
        runner.register_one(self.api, self.journal, 'primary', True)
        self.assertEqual(self.api.mutations, ['createStoragePool'])

    def test_uncertain_empty_result_survives_process_restart_without_replay(self):
        self.api.timeout, self.api.apply = True, False
        with self.assertRaisesRegex(runner.GateError, 'NO_REPLAY'):
            runner.register_one(self.api, self.journal, 'primary', True)
        self.journal.close()
        self.journal = runner.Journal(self.directory, {'fixed': 'fixture'}, runner.ENDPOINT)
        with self.assertRaisesRegex(runner.GateError, 'NO_REPLAY'):
            runner.register_one(self.api, self.journal, 'primary', True)
        self.api.storage['primary'] = [resource('primary')]
        self.assertEqual(runner.register_one(self.api, self.journal, 'primary', True)['status'], 'RECONCILED')
        self.assertEqual(self.api.mutations, ['createStoragePool'])

    def test_conflicting_scope_duplicate_and_truncated_inventory_stop_creation(self):
        for mode in ('scope', 'duplicate', 'truncated'):
            with self.subTest(mode=mode):
                row = resource('primary')
                if mode == 'scope':
                    row['clusterid'] = IMAGE
                self.api.storage['primary'] = [row, dict(row)] if mode == 'duplicate' else [row]
                self.api.report_count = 2 if mode == 'truncated' else None
                with self.assertRaises(runner.GateError):
                    runner.register_one(self.api, self.journal, 'primary', True)
                self.assertEqual(self.api.mutations, [])

    def test_replaced_registered_id_and_changed_source_zone_stop(self):
        runner.register_one(self.api, self.journal, 'primary', True)
        self.api.storage['primary'][0]['id'] = IMAGE
        with self.assertRaisesRegex(runner.GateError, 'NATIVE_UUID_CONFLICT'):
            runner.register_one(self.api, self.journal, 'primary', True)
        self.api.zone_state = 'Enabled'
        with self.assertRaisesRegex(runner.GateError, 'SOURCE_ZONE_CHANGED'):
            runner.register_one(self.api, self.journal, 'image', True)
        self.assertEqual(self.api.mutations, ['createStoragePool'])

    def test_failed_durable_write_never_submits(self):
        self.journal.save = Mock(side_effect=OSError('disk full'))
        with self.assertRaises(OSError):
            runner.register_one(self.api, self.journal, 'primary', True)
        self.assertEqual(self.api.mutations, [])

    def test_changed_pool_guard_never_submits(self):
        with self.assertRaisesRegex(runner.GateError, 'POOL_CHANGED'):
            runner.register_one(self.api, self.journal, 'primary', True,
                                Mock(side_effect=runner.GateError('POOL_CHANGED')))
        self.assertEqual(self.api.mutations, [])

    def test_equivalent_nfs_endpoint_does_not_create_duplicate(self):
        row = resource('image')
        row['url'] = 'nfs://10.10.10.14:2049/export/secondary/'
        row['name'] = 'existing-different-label'
        self.api.storage['image'] = [row]
        self.assertEqual(runner.register_one(self.api, self.journal, 'image', True)['status'], 'OBSERVED_EXISTING')
        self.assertEqual(self.api.mutations, [])

    def test_native_uuid_and_driver_collision_gate(self):
        self.assertEqual(runner.NATIVE_PRIMARY_UUID, '3ec8a7ea-ebbe-3c45-9f9c-f67d840318b7')
        pool = {'uuid': runner.PRESERVED_POOL, 'type': 'netfs', 'sourceHost': runner.DC,
                'sourceDirectory': '/export/primary', 'targetPath': '/mnt/' + runner.PRESERVED_POOL}
        with self.assertRaisesRegex(runner.GateError, 'NFS_SOURCE_UUID_COLLISION'):
            runner.check_native_pool_compatibility(pool)
        pool['sourceDirectory'] = '/unrelated'
        pool['targetPath'] = '/export/primary'
        with self.assertRaisesRegex(runner.GateError, 'REDEFINE_EXISTING_TARGET'):
            runner.check_native_pool_compatibility(pool)
        pool['targetPath'] = '/unrelated-mount'
        runner.check_native_pool_compatibility(pool)

    def test_preserves_directory_pool_and_only_allows_own_new_native_pool_after_intent(self):
        identity = {'uuid': runner.PRESERVED_POOL, 'name': runner.PRESERVED_POOL, 'type': 'dir',
                    'targetPath': '/var/lib/libvirt/images'}
        proof = {'pool': {'identity': identity}}
        old_xml = '<pool type="dir"><name>' + runner.PRESERVED_POOL + '</name><uuid>' + runner.PRESERVED_POOL + '</uuid><target><path>/var/lib/libvirt/images</path></target></pool>'
        new_xml = '<pool type="netfs"><uuid>' + runner.NATIVE_PRIMARY_UUID + '</uuid><source><host name="10.10.10.14"/><dir path="/export/primary"/></source></pool>'
        names = runner.PRESERVED_POOL + '\n' + runner.NATIVE_PRIMARY_UUID
        def done(text):
            return subprocess.CompletedProcess([], 0, text, '')
        with patch.object(runner.subprocess, 'run', side_effect=[done(names), done(old_xml), done(new_xml)]):
            runner.preserve_live_pool(proof, primary_intent_recorded=True)
        with patch.object(runner.subprocess, 'run', return_value=done(names)):
            with self.assertRaisesRegex(runner.GateError, 'POOL_SET_CHANGED'):
                runner.preserve_live_pool(proof, primary_intent_recorded=False)


if __name__ == '__main__':
    unittest.main()
