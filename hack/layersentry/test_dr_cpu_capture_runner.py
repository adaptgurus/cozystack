import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zipfile

SPEC = importlib.util.spec_from_file_location('capture_runner', Path(__file__).with_name('run-dr-cpu-capture.py'))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class CaptureRunnerGuards(unittest.TestCase):
    def request(self, base):
        root = base / 'dr-capture-123-1'
        (root / 'source/k8s/image').mkdir(parents=True)
        hashes = {}
        for name in runner.FILES:
            path = root / 'source' / name
            path.write_text('# exact source fixture\n')
            hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        identity = str(uuid.uuid4())
        owned = '/var/lib/libvirt/images/layersentry-cpuqc-' + identity
        record = {'cloudStackSource': runner.SOURCE, 'imageSha256': runner.IMAGE,
                  'runId': '123', 'runAttempt': '1', 'bootRunId': '12', 'bootArtifactId': '34',
                  'bootRunnerCommit': 'a' * 40, 'sourceHashes': hashes,
                  'ownershipManifest': owned + '/ownership.json',
                  'ownership': {'domainUuid': identity, 'domainName': 'layersentry-cpuqc-' + identity,
                                'diskPath': owned + '/runtime.qcow2', 'seedPath': owned + '/seed.iso',
                                'sourceSha256': runner.IMAGE, 'retainForDrQualification': True}}
        return root, record

    def test_exact_bundle_accepts_and_corruption_or_identity_drift_refuses(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'regular'):
            base = Path(directory)
            root, record = self.request(base)
            with patch.object(runner, 'BASE', base):
                self.assertEqual(record['ownership']['domainUuid'], runner.validate_request(record, root))
                for key, value in [('cloudStackSource', 'a' * 40), ('imageSha256', 'b' * 64), ('runId', '../escape')]:
                    bad = copy.deepcopy(record)
                    bad[key] = value
                    with self.assertRaises(ValueError):
                        runner.validate_request(bad, root)
                for key, value in [('retainForDrQualification', False), ('diskPath', '/customer/image.qcow2')]:
                    bad = copy.deepcopy(record)
                    bad['ownership'][key] = value
                    with self.assertRaises(ValueError):
                        runner.validate_request(bad, root)
                (root / 'source/dr_replication.py').write_text('changed')
                with self.assertRaisesRegex(ValueError, 'source checksum'):
                    runner.validate_request(record, root)

    def test_collector_rejects_qcow2_and_link_instead_of_broad_upload(self):
        for name, linked in [('customer.qcow2', False), ('result.json', True)]:
            with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'trusted_directory'):
                root = Path(directory)
                (root / 'evidence').mkdir()
                path = root / 'evidence' / name
                if linked:
                    path.symlink_to('/etc/passwd')
                else:
                    path.write_bytes(b'not public evidence')
                with self.assertRaises(ValueError):
                    runner.collect(root)
                self.assertFalse((root / 'public-evidence.zip').exists())

    def test_collector_binds_only_allowlisted_public_files(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'trusted_directory'), patch.object(runner, 'regular', side_effect=lambda path, limit: path.stat()):
            root = Path(directory)
            (root / 'evidence/journals').mkdir(parents=True)
            (root / 'runner-result.json').write_text('{"status":"PARTIAL"}')
            (root / 'evidence/result.json').write_text('{"status":"PARTIAL"}')
            (root / 'evidence/journals/epoch.json').write_text('{"state":"CAPTURING"}')
            result = runner.collect(root)
            archive = root / 'public-evidence.zip'
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), result['archiveSha256'])
            with zipfile.ZipFile(archive) as stream:
                self.assertEqual({'runner-result.json', 'evidence/result.json', 'evidence/journals/epoch.json', 'collection-manifest.json'}, set(stream.namelist()))
                for entry in json.loads(stream.read('collection-manifest.json')):
                    self.assertEqual(hashlib.sha256(stream.read(entry['path'])).hexdigest(), entry['sha256'])

    def test_regular_file_guard_rejects_links_writable_and_oversized(self):
        from types import SimpleNamespace
        for change in [{'st_mode': stat.S_IFLNK | 0o777}, {'st_mode': stat.S_IFREG | 0o666}, {'st_uid': 99}, {'st_nlink': 2}, {'st_size': 4097}]:
            values = dict(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=1, st_size=1)
            values.update(change)
            with patch.object(Path, 'lstat', return_value=SimpleNamespace(**values)):
                with self.assertRaises(ValueError):
                    runner.regular(Path('/test'), 4096)


if __name__ == '__main__':
    unittest.main()
