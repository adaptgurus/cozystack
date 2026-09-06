#!/usr/bin/env python3
"""Pinned root runner around one retained, networkless DR provider fixture."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid
import zipfile

SOURCE = '8f94ee6e2ac1e360e39b71b8247e64b62187ef0d'
IMAGE = '7580d64a5b9f27d930d7a5f5688f67063db042252dd43c7cf280fdb3e101a34d'
BASE = Path('/var/lib/layersentry-validation')
FILES = ('dr_cpu_capture_acceptance.py', 'dr_libvirt_capture.py', 'dr_file_replication.py',
         'dr_replication.py', 'dr_replication_transport.py', 'dr_state_machine.py',
         'k8s/image/boot_qga_acceptance.py')
BOOT_FILES = {'result.json', 'guest-checks.json', 'domain-request.xml', 'domain-actual.xml',
              'source-image-info.json', 'failure.txt', 'console.log', 'ownership.json', 'cleanup.json'}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def regular(path, limit):
    info = path.lstat()
    check(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0
          and not info.st_mode & 0o022 and info.st_size <= limit, 'untrusted or oversized file: ' + path.name)
    return info


def trusted_directory(path, private=False):
    for parent in [path, *path.parents]:
        info = parent.lstat()
        check(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022,
              'untrusted directory ancestry')
    if private:
        check(not path.stat().st_mode & 0o077, 'private workspace required')


def save(path, data):
    temporary = path.with_suffix(path.suffix + '.new')
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream, sort_keys=True, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def command(argv, timeout=30):
    return subprocess.check_output(argv, timeout=timeout, text=True, stderr=subprocess.STDOUT).strip()


def validate_request(request, root):
    check(request['cloudStackSource'] == SOURCE and request['imageSha256'] == IMAGE, 'source/image pin mismatch')
    for name in ['runId', 'runAttempt', 'bootRunId', 'bootArtifactId']:
        check(re.fullmatch(r'[0-9]{1,20}', request[name]) is not None, 'invalid run/artifact identity')
    check(re.fullmatch(r'[0-9a-f]{40}', request['bootRunnerCommit']) is not None, 'invalid boot runner commit')
    check(root == BASE / ('dr-capture-' + request['runId'] + '-' + request['runAttempt']), 'workspace binding mismatch')
    ownership = request['ownership']
    identity = str(uuid.UUID(ownership['domainUuid']))
    check(identity == ownership['domainUuid'], 'noncanonical fixture UUID')
    expected = '/var/lib/libvirt/images/layersentry-cpuqc-' + identity
    check(ownership['domainName'] == 'layersentry-cpuqc-' + identity
          and ownership['diskPath'] == expected + '/runtime.qcow2'
          and ownership['seedPath'] == expected + '/seed.iso'
          and request['ownershipManifest'] == expected + '/ownership.json'
          and ownership['sourceSha256'] == IMAGE and ownership['retainForDrQualification'] is True,
          'retained ownership/image mismatch')
    check(set(request['sourceHashes']) == set(FILES), 'source bundle must contain exactly the reviewed module closure')
    for name, expected_hash in request['sourceHashes'].items():
        check(re.fullmatch(r'[0-9a-f]{64}', expected_hash) is not None, 'invalid source hash')
        path = root / 'source' / name
        regular(path, 2 * 1024**2)
        check(hashlib.sha256(path.read_bytes()).hexdigest() == expected_hash, 'source checksum mismatch: ' + name)
    return identity


def collect(root):
    """Allowlist public harness evidence; reject symlinks, unknown files and size overflow."""
    selected = []
    for name in ['runner-result.json', 'runner-progress.json', 'request.json']:
        if (root / name).exists():
            selected.append((root / name, name, 1024**2))
    evidence = root / 'evidence'
    if evidence.exists():
        trusted_directory(evidence, private=True)
        for path in sorted(evidence.rglob('*')):
            if path.is_dir() and not path.is_symlink():
                continue
            relative = path.relative_to(evidence)
            parts = relative.parts
            allowed = (len(parts) == 1 and parts[0] in {'result.json', 'progress.json'})
            allowed |= len(parts) == 2 and parts[0] in {'recovery-inc1', 'recovery-inc2'} and parts[1] in BOOT_FILES
            allowed |= (len(parts) >= 2 and parts[0] == 'journals' and parts[-1].endswith('.json')
                        and all(re.fullmatch(r'[A-Za-z0-9_.-]+', item) and item not in {'.', '..'} for item in parts))
            check(allowed, 'unexpected evidence file; refusing broad collection')
            trusted_directory(path.parent)
            selected.append((path, 'evidence/' + str(relative), 2 * 1024**2 if path.name == 'console.log' else 1024**2))
    log = root / 'capture.log'
    if log.exists():
        regular(log, 64 * 1024**2)
        with log.open('rb') as stream:
            size = log.stat().st_size
            stream.seek(max(0, size - 2 * 1024**2))
            tail = stream.read(2 * 1024**2)
        target = root / 'capture-tail.log'
        with target.open('xb') as stream:
            os.chmod(target, 0o600)
            stream.write(tail)
        save(root / 'capture-log-bound.json', {'originalBytes': size, 'retainedBytes': len(tail), 'truncated': size > len(tail)})
        selected.extend([(target, target.name, 2 * 1024**2), (root / 'capture-log-bound.json', 'capture-log-bound.json', 1024)])
    check(len(selected) <= 140, 'public evidence file limit exceeded')
    total = 0
    manifest = []
    for path, name, limit in selected:
        info = regular(path, limit)
        total += info.st_size
        check(total <= 32 * 1024**2, 'public evidence byte limit exceeded')
        manifest.append({'path': name, 'bytes': info.st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    archive = root / 'public-evidence.zip'
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as output:
        os.chmod(archive, 0o600)
        for path, name, _ in selected:
            output.write(path, name)
        output.writestr('collection-manifest.json', json.dumps(manifest, sort_keys=True, indent=2))
    return {'archiveSha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'archiveBytes': archive.stat().st_size,
            'fileCount': len(manifest), 'uncompressedBytes': total}


def execute(root):
    check(os.geteuid() == 0, 'approved root runner required')
    trusted_directory(BASE, private=True)
    trusted_directory(root, private=True)
    regular(root / 'request.json', 65536)
    request = json.loads((root / 'request.json').read_text())
    identity = validate_request(request, root)
    state = {'schemaVersion': '1.0', 'status': 'PENDING', 'stage': 'HOST_PREFLIGHT', 'startedAt': now(),
             'sourceDomainUuid': identity, 'sourceOwnershipManifest': request['ownershipManifest'],
             'sourceCommit': SOURCE, 'imageSha256': IMAGE, 'captureAttempted': False,
             'captureReplay': 'PROHIBITED_WITHOUT_RECONCILIATION', 'productionQualified': False,
             'sourceFixtureRetained': None, 'replicationWorkspaceCleanupAttempted': False}
    lock = None
    exit_code = 1
    try:
        save(root / 'runner-progress.json', state)
        lock = os.open('/run/lock/layersentry-dr-deployment.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(lock)
        check(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and not info.st_mode & 0o022, 'untrusted live lock')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        check(command(['hostname', '-f']) == 'layersentry-dr-mgmt1', 'host identity mismatch')
        osdata = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
        check(osdata['ID'].strip('"') == 'rocky' and osdata['VERSION_ID'].strip('"') == '9.8', 'exact Rocky version required')
        addresses = json.loads(command(['ip', '-j', '-4', 'address', 'show']))
        check('10.10.10.20' in [a.get('local') for link in addresses for a in link.get('addr_info', [])], 'host IP mismatch')
        check(command(['getenforce']) == 'Enforcing', 'SELinux must remain Enforcing')
        for unit in ['firewalld', 'cloudstack-management']:
            check(command(['systemctl', 'is-active', unit]) == 'active', 'required service inactive: ' + unit)
        check(command(['virsh', '--readonly', '-c', 'qemu:///system', 'list', '--all', '--uuid']).splitlines() == [identity], 'unexpected other domain; runtime reservation conflict')
        disk = os.statvfs('/var/lib/libvirt/images')
        state['freeBytesBefore'] = disk.f_bavail * disk.f_frsize
        check(state['freeBytesBefore'] >= 30 * 1024**3, 'at least 30 GiB free required')
        sys.path.insert(0, str(root / 'source'))
        import dr_cpu_capture_acceptance as harness
        import libvirt
        connection = libvirt.open('qemu:///system')
        check(connection is not None, 'local libvirt unavailable')
        try:
            actual, _ = harness.fixture(Path(request['ownershipManifest']), connection)
            check(actual == request['ownership'], 'live ownership changed since successful boot artifact')
            state['sourceFixtureRetained'] = True
            check(connection.getLibVersion() == 11010000 and connection.getVersion() == 10001000, 'libvirt/QEMU pin mismatch')
        finally:
            connection.close()
        attempt = BASE / ('dr-capture-once-' + identity + '.json')
        with attempt.open('x') as stream:
            os.chmod(attempt, 0o600)
            json.dump({'runId': request['runId'], 'runAttempt': request['runAttempt'], 'workspace': str(root), 'startedAt': now()}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        descriptor = os.open(BASE, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        state.update(stage='CAPTURE_ONCE', captureAttempted=True)
        save(root / 'runner-progress.json', state)
        with (root / 'capture.log').open('xb') as log:
            os.chmod(root / 'capture.log', 0o600)
            result = subprocess.run(['timeout', '--signal=TERM', '--kill-after=90', '2400', 'python3',
                                     str(root / 'source/dr_cpu_capture_acceptance.py'), '--ownership-manifest', request['ownershipManifest'],
                                     '--evidence', str(root / 'evidence'), '--libvirt-version', '11010000', '--qemu-version', '10001000',
                                     '--source-commit', SOURCE], stdout=log, stderr=subprocess.STDOUT, timeout=2530)
        state['captureExitCode'] = result.returncode
        receipt_path = root / 'evidence/result.json'
        if receipt_path.exists():
            regular(receipt_path, 1024**2)
            receipt = json.loads(receipt_path.read_text())
            state['replicationOwnershipManifest'] = receipt.get('ownershipManifest')
            state['replicationWorkspace'] = receipt.get('workspace')
            state['captureStatus'] = receipt.get('status')
            check(result.returncode == 0 and receipt['status'] == 'LIVE_VERIFIED'
                  and receipt['sourceCommit'] == SOURCE and receipt['sourceImageSha256'] == IMAGE
                  and receipt['sourceDomainUuid'] == identity and receipt['productionQualified'] is False,
                  'capture did not pass exact provider acceptance')
        else:
            raise ValueError('capture produced no final receipt; reconcile before any retry')
        check(command(['getenforce']) == 'Enforcing', 'host SELinux changed')
        check(command(['virsh', '--readonly', '-c', 'qemu:///system', 'list', '--all', '--uuid']).splitlines() == [identity], 'recovery domain cleanup not proven')
        state.update(status='LIVE_VERIFIED', stage='CAPTURE_COMPLETE', scope='same-host networkless libvirt QCOW2 provider acceptance')
        exit_code = 0
    except BaseException as error:
        state.update(status='PARTIAL' if state['captureAttempted'] else 'BLOCKED', failureType=type(error).__name__, failure=str(error)[:16384])
    finally:
        state['finishedAt'] = now()
        save(root / 'runner-result.json', state)
        try:
            state['collection'] = collect(root)
        except BaseException as error:
            state.update(status='PARTIAL', collectionFailure=str(error)[:4096])
            exit_code = 1
        if lock is not None:
            os.close(lock)
        print(json.dumps(state, sort_keys=True))
    return exit_code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    raise SystemExit(execute(parser.parse_args().root))
