"""Bind immutable deployed UI archive to a bounded public asset digest inventory."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import sys


def prepare(bundle, commit, expected_sha):
    if not re.fullmatch('[0-9a-f]{40}', commit) or not re.fullmatch('[0-9a-f]{64}', expected_sha):
        raise ValueError('INVALID_ARTIFACT_BINDING')
    archive = bundle / 'ui-dist.tar.gz'
    if archive.is_symlink() or not archive.is_file() or archive.stat().st_size > 256 * 1024 * 1024:
        raise ValueError('INVALID_UI_ARCHIVE')
    hasher = hashlib.sha256()
    with archive.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(block)
    digest = hasher.hexdigest()
    if digest != expected_sha:
        raise ValueError('UI_ARCHIVE_DIGEST_MISMATCH')
    manifest = json.loads((bundle / 'build-manifest.json').read_text(encoding='utf-8'))
    if manifest != {'schemaVersion': '1.0', 'product': 'LayerSentry', 'component': 'cloudstack-ui',
                    'cloudstackUiCommit': commit, 'artifact': archive.name,
                    'artifactSha256': expected_sha, 'builtOnManagementNode': False}:
        raise ValueError('UI_BUILD_MANIFEST_MISMATCH')
    assets = []
    seen = set()
    total = 0
    branding = None
    with tarfile.open(archive, 'r:gz') as tar:
        for item in tar:
            path = PurePosixPath(item.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'ui-dist'
                    or '\\' in item.name or not re.fullmatch(r'[A-Za-z0-9_./@+ -]+', item.name)
                    or path.as_posix() != item.name.rstrip('/') or item.name in seen or len(seen) >= 10000):
                raise ValueError('UNSAFE_UI_ARCHIVE_MEMBER')
            seen.add(item.name)
            if item.isdir():
                continue
            if not item.isfile() or len(path.parts) < 2 or path.parts[1] in {'WEB-INF', 'META-INF'}:
                raise ValueError('UNSAFE_UI_ARCHIVE_TYPE')
            total += item.size
            if item.size > 32 * 1024 * 1024 or total > 512 * 1024 * 1024:
                raise ValueError('UI_ARCHIVE_SIZE_LIMIT')
            data = tar.extractfile(item).read(item.size + 1)
            if len(data) != item.size:
                raise ValueError('TRUNCATED_UI_ARCHIVE')
            name = '/'.join(path.parts[1:])
            if name == 'config.json':
                config = json.loads(data)
                # Deployer intentionally merges runtime API/module policy. Bind
                # branding only; never publish runtime configuration contents.
                branding = {k: config[k] for k in ('appTitle', 'productProfile', 'brandLocked', 'logo', 'minilogo')}
                if branding['productProfile'] != 'layersentry-kvm':
                    raise ValueError('WRONG_PRODUCT_PROFILE')
            else:
                assets.append({'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    if not branding or not {'index.html', 'assets/layersentry-logo.svg'} <= {a['path'] for a in assets}:
        raise ValueError('REQUIRED_UI_ASSETS_MISSING')
    return {'schema': 1, 'cloudstackUiCommit': commit, 'artifactSha256': expected_sha,
            'assets': sorted(assets, key=lambda a: a['path']), 'branding': branding}


if __name__ == '__main__':
    try:
        bundle, commit, sha, output = sys.argv[1:]
        result = prepare(Path(bundle), commit, sha)
        with open(output, 'x', encoding='utf-8') as stream:
            json.dump(result, stream, sort_keys=True)
    except Exception:
        # No raw JSON/parser/path errors in public runner logs.
        print('UI_ARTIFACT_PREPARATION_FAILED', file=sys.stderr)
        sys.exit(1)
