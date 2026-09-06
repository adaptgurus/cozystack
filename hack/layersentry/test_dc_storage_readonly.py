import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('storage_proof', ROOT / 'collect-dc-storage-readonly.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class StorageProofTests(unittest.TestCase):
    def fixture(self, root):
        header = bytearray(72)
        header[:4] = b'QFI\xfb'
        struct.pack_into('>I', header, 4, 3)
        struct.pack_into('>Q', header, 24, 4294967296)
        image = bytes(header) + b'fixture image'
        (root / collector.IMAGE).write_bytes(image)
        (root / 'template.properties').write_text('id=3\npublic=true\nuniquename=routing-3\nqcow2.filename=' + collector.IMAGE + '\npassword=never-publish\ndescription=never-publish\n')
        return image

    def test_real_files_hash_and_only_allowlisted_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = self.fixture(root)
            result = collector.storage_files(root)
        self.assertEqual(result['image']['sha256'], hashlib.sha256(image).hexdigest())
        self.assertEqual(result['image']['virtualSizeBytes'], 4294967296)
        self.assertFalse(result['versionEstablished'])
        self.assertFalse(result['image']['hasBackingFile'])
        self.assertNotIn('never-publish', json.dumps(result))

    def test_image_and_parent_symlinks_and_hardlinks_refused(self):
        for mode in ('image-symlink', 'parent-symlink', 'hardlink'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                root = base / 'real'
                root.mkdir()
                self.fixture(root)
                if mode == 'image-symlink':
                    image = root / collector.IMAGE
                    image.rename(root / 'actual')
                    image.symlink_to(root / 'actual')
                elif mode == 'parent-symlink':
                    (base / 'alias').symlink_to(root, target_is_directory=True)
                    root = base / 'alias'
                else:
                    os.link(root / collector.IMAGE, root / 'alias')
                with self.assertRaises((ValueError, OSError)):
                    collector.storage_files(root)

    def test_oversized_metadata_and_non_qcow2_are_refused(self):
        for mode in ('metadata', 'image'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.fixture(root)
                if mode == 'metadata':
                    (root / 'template.properties').write_bytes(b'x' * 16385)
                else:
                    (root / collector.IMAGE).write_bytes(b'not qcow2')
                with self.assertRaises(ValueError):
                    collector.storage_files(root)

    def test_changed_image_does_not_publish_a_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            with patch.object(collector, 'unchanged', side_effect=[True, False]):
                with self.assertRaises(ValueError):
                    collector.storage_files(root)

    def test_wrong_target_does_not_read_storage(self):
        with patch.object(collector, 'command', return_value='[]'), patch.object(collector, 'storage_files') as read:
            self.assertEqual(collector.collect()['status'], 'TARGET_BINDING_FAILED')
            read.assert_not_called()

    def test_pool_identity_omits_credentials_and_rejects_wrong_uuid(self):
        xml = '<pool type="netfs"><name>' + collector.POOL + '</name><uuid>' + collector.POOL + '</uuid><source><host name="10.10.10.14"/><dir path="/export/primary"/><auth password="never-publish"/></source><target><path>/mnt/pool</path></target></pool>'
        with patch.object(collector, 'command', side_effect=[collector.POOL, xml]) as command:
            result = collector.pool_identity()
        self.assertEqual(result['identity']['sourceDirectory'], '/export/primary')
        self.assertNotIn('never-publish', json.dumps(result))
        self.assertIn('--readonly', command.call_args.args[0])
        with patch.object(collector, 'command', side_effect=[collector.POOL, xml.replace('<uuid>' + collector.POOL, '<uuid>wrong')]):
            self.assertEqual(collector.pool_identity()['status'], 'INVALID_OUTPUT')

    def test_routes_and_plugin_package_omit_unrequested_content(self):
        routes = [{'dst': '10.10.20.0/24', 'dev': 'cloudbr0', 'gateway': '10.10.10.1', 'private': 'never-publish'}]
        with patch.object(collector, 'command', return_value=json.dumps(routes)):
            result = collector.public_routes()
        self.assertEqual(result['routes'][0]['dst'], '10.10.20.0/24')
        self.assertNotIn('never-publish', json.dumps(result))

        with patch.object(collector, 'command', side_effect=['cloudstack-management 4.22.1.1 1',
                               '/usr/share/cloudstack-management/lib/cloud-plugin-backup-nas-4.22.1.1.jar\n/etc/private-never-publish']):
            result = collector.plugin_package()
        self.assertEqual(len(result['nasPluginPackagePaths']), 1)
        self.assertNotIn('never-publish', json.dumps(result))

    def test_registration_journal_observation_omits_private_parameters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'journal.json').write_text(json.dumps({'operations': {'primary': {
                'command': 'createStoragePool', 'state': 'SUBMITTING', 'params': {'private': 'never-publish'}}}}))
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            with patch.object(collector, 'open_directory', return_value=fd):
                result = collector.registration_journal()
        self.assertEqual(result['operations']['primary']['state'], 'SUBMITTING')
        self.assertNotIn('never-publish', json.dumps(result))
        with patch.object(collector, 'open_directory', side_effect=FileNotFoundError):
            self.assertEqual(collector.registration_journal()['status'], 'DIRECTORY_ABSENT')

    def test_tls_inventory_is_presence_only_and_listener_absence_is_not_trust(self):
        service = 'LoadState=loaded\nActiveState=active\nPrivateKey=never-publish'
        listeners = 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\nLISTEN 0 4096 [::]:8080 [::]:*\nLISTEN 0 10 0.0.0.0:22 0.0.0.0:*'
        with patch.object(collector, 'command', side_effect=[service] * 4 + [listeners]), patch.object(collector.os, 'lstat', side_effect=FileNotFoundError):
            result = collector.tls_presence()
        self.assertEqual([r['port'] for r in result['listeners']], [443, 8080])
        self.assertEqual(result['trustedHttpsEndpoint'], 'NOT_ESTABLISHED')
        self.assertFalse(result['configContentsRead'])
        self.assertNotIn('never-publish', json.dumps(result))



if __name__ == '__main__':
    unittest.main()
