#!/usr/bin/env python3
"""Private SSH-stdin launcher for the exact reviewed DC storage registration."""
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import types

PROOF_SHA256 = 'f268bcf25a51e28d33fe475607252d2c8219b51fa9b1f70ea35450c775f2d3a1'
JOURNAL = '/var/lib/layersentry/native-dc-storage-r0'
SOURCES = ('dr_recovery_acceptance', 'dc_native_storage_registration')


def require(condition):
    if not condition:
        raise ValueError('PRIVATE_INPUT_OR_JOURNAL_GATE')


def decode(value, limit):
    require(isinstance(value, str) and len(value) <= limit * 2)
    data = base64.b64decode(value, validate=True)
    require(len(data) <= limit)
    return data


def parse_payload(raw):
    require(len(raw) <= 262144)
    data = json.loads(raw)
    require(set(data) == {'schema', 'target', 'mode', 'sources', 'proof', 'apiKey', 'apiSecret'})
    require(data['schema'] == 1 and data['target'] == '10.10.10.14' and data['mode'] in ('Plan', 'Register'))
    for key in ('apiKey', 'apiSecret'):
        require(isinstance(data[key], str) and 1 <= len(data[key]) <= 4096 and '\x00' not in data[key])
    require(set(data['sources']) == set(SOURCES))
    for source in data['sources'].values():
        require(set(source) == {'base64', 'sha256'})
        code = decode(source['base64'], 65536)
        require(hashlib.sha256(code).hexdigest() == source['sha256'])
    proof = decode(data['proof'], 65536)
    require(hashlib.sha256(proof).hexdigest() == PROOF_SHA256)
    return data, proof


def private_directory(path=JOURNAL):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            try:
                next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                os.mkdir(component, 0o700, dir_fd=fd)
                os.fsync(fd)
                next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            metadata = os.fstat(fd)
            require(metadata.st_uid in (0, os.geteuid()) and stat.S_IMODE(metadata.st_mode) & 0o022 == 0)
        metadata = os.fstat(fd)
        require(metadata.st_uid == os.geteuid() and stat.S_IMODE(metadata.st_mode) & 0o077 == 0)
        return fd
    except BaseException:
        os.close(fd)
        raise


def install_public_proof(directory_fd, proof):
    try:
        fd = os.open('public-proof.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
    except FileExistsError:
        fd = os.open('public-proof.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
        with os.fdopen(fd, 'rb') as stream:
            metadata = os.fstat(stream.fileno())
            require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_size <= 65536)
            require(stream.read(65537) == proof)
        return
    with os.fdopen(fd, 'wb') as stream:
        stream.write(proof)
        stream.flush()
        os.fsync(stream.fileno())
    os.fsync(directory_fd)


def main():
    try:
        payload, proof = parse_payload(sys.stdin.buffer.read(262145))
        for name in SOURCES:
            module = types.ModuleType(name)
            sys.modules[name] = module
            code = decode(payload['sources'][name]['base64'], 65536).decode('utf-8')
            exec(compile(code, '<reviewed-' + name + '>', 'exec'), module.__dict__)
        registration = sys.modules[SOURCES[1]]
        registration.local_dc_binding()
        registration.validate_proof(json.loads(proof.decode('utf-8-sig')))
        # Public evidence and journal only are persisted; credentials remain memory/environment only.
        directory_fd = private_directory()
        try:
            install_public_proof(directory_fd, proof)
        finally:
            os.close(directory_fd)
        os.environ['CLOUDSTACK_API_KEY'] = payload.pop('apiKey')
        os.environ['CLOUDSTACK_SECRET_KEY'] = payload.pop('apiSecret')
        sys.argv = ['register-dc-native-storage.py', '--journal', JOURNAL,
                    '--proof-file', JOURNAL + '/public-proof.json', '--proof-sha256', PROOF_SHA256]
        if payload['mode'] == 'Register':
            sys.argv.append('--execute')
        return registration.main()
    except Exception:
        print(json.dumps({'status': 'PRIVATE_INPUT_OR_JOURNAL_GATE', 'automaticReplay': False}))
        return 1
    finally:
        os.environ.pop('CLOUDSTACK_API_KEY', None)
        os.environ.pop('CLOUDSTACK_SECRET_KEY', None)


if __name__ == '__main__':
    raise SystemExit(main())
