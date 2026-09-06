import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from prepare_artifact import prepare


class ArtifactCase(unittest.TestCase):
    def fixture(self, extra=None):
        folder = Path(self.addCleanupTemporary())
        config = {'appTitle': 'LayerSentry', 'productProfile': 'layersentry-kvm', 'brandLocked': True, 'logo': 'assets/layersentry-logo.svg', 'minilogo': 'assets/layersentry-icon.svg', 'apiBase': '/client/api'}
        with tarfile.open(folder / 'ui-dist.tar.gz', 'w:gz') as tar:
            for name, data in [('ui-dist/index.html', b'<html/>'), ('ui-dist/assets/layersentry-logo.svg', b'<svg/>'), ('ui-dist/config.json', json.dumps(config).encode())]:
                item = tarfile.TarInfo(name); item.size = len(data); tar.addfile(item, io.BytesIO(data))
            if extra:
                item = tarfile.TarInfo(extra[0]); item.type = extra[1]; tar.addfile(item)
        sha = hashlib.sha256((folder / 'ui-dist.tar.gz').read_bytes()).hexdigest()
        (folder / 'build-manifest.json').write_text(json.dumps({'schemaVersion': '1.0', 'product': 'LayerSentry', 'component': 'cloudstack-ui', 'cloudstackUiCommit': 'a'*40, 'artifact': 'ui-dist.tar.gz', 'artifactSha256': sha, 'builtOnManagementNode': False}))
        return folder, sha

    def addCleanupTemporary(self):
        obj = tempfile.TemporaryDirectory(); self.addCleanup(obj.cleanup); return obj.name

    def test_config_runtime_is_separate_and_assets_bind_exact_bytes(self):
        folder, sha = self.fixture(); result = prepare(folder, 'a'*40, sha)
        self.assertEqual(len(result['assets']), 2)
        self.assertNotIn('apiBase', result['branding'])
        self.assertEqual(result['assets'][1]['sha256'], hashlib.sha256(b'<html/>').hexdigest())

    def test_wrong_archive_or_commit_is_rejected(self):
        folder, sha = self.fixture()
        for commit, digest in [('b'*40, sha), ('a'*40, '0'*64)]:
            with self.assertRaises(ValueError): prepare(folder, commit, digest)

    def test_traversal_links_duplicates_and_backend_are_rejected(self):
        for item in [('ui-dist/../secret', tarfile.REGTYPE), ('ui-dist/link', tarfile.SYMTYPE), ('ui-dist/hard', tarfile.LNKTYPE), ('ui-dist/index.html', tarfile.REGTYPE), ('ui-dist/WEB-INF/a', tarfile.REGTYPE)]:
            with self.subTest(item=item):
                folder, sha = self.fixture(item)
                with self.assertRaises(ValueError): prepare(folder, 'a'*40, sha)


if __name__ == '__main__': unittest.main()
