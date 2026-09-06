#!/usr/bin/env python3
"""Versioned private stdin loader; no credentials written or printed."""
import base64
import hashlib
import json
import os
import sys
import types

SOURCES = ('dr_recovery_acceptance', 'dc_native_storage_registration', 'dc_storage_loader', 'dc_guest_network')
JOURNAL = '/var/lib/layersentry/native-dc-guest-network-r0'


def parse_payload(raw):
    if len(raw) > 524288:
        raise ValueError('INPUT_LIMIT')
    data = json.loads(raw)
    if set(data) != {'schema', 'target', 'mode', 'sources', 'proof', 'apiKey', 'apiSecret'}:
        raise ValueError('INPUT_FIELDS')
    if data['schema'] != 1 or data['target'] != '10.10.10.14' or data['mode'] not in ('Plan', 'Bridge', 'Label'):
        raise ValueError('INPUT_SCOPE')
    if set(data['sources']) != set(SOURCES):
        raise ValueError('SOURCE_SCOPE')
    for value in data['sources'].values():
        if set(value) != {'base64', 'sha256'} or len(value['base64']) > 131072:
            raise ValueError('SOURCE_SIZE')
        code = base64.b64decode(value['base64'], validate=True)
        if len(code) > 65536 or hashlib.sha256(code).hexdigest() != value['sha256']:
            raise ValueError('SOURCE_DIGEST')
    proof = base64.b64decode(data['proof'], validate=True)
    if hashlib.sha256(proof).hexdigest() != 'f268bcf25a51e28d33fe475607252d2c8219b51fa9b1f70ea35450c775f2d3a1':
        raise ValueError('PROOF_DIGEST')
    for field in ('apiKey', 'apiSecret'):
        if not isinstance(data[field], str) or not 1 <= len(data[field]) <= 4096 or '\x00' in data[field]:
            raise ValueError('CREDENTIAL_SHAPE')
    return data


def main():
    journal = None
    try:
        payload = parse_payload(sys.stdin.buffer.read(524289))
        for name in SOURCES:
            module = types.ModuleType(name)
            sys.modules[name] = module
            code = base64.b64decode(payload['sources'][name]['base64'], validate=True).decode('utf-8')
            exec(compile(code, '<reviewed-' + name + '>', 'exec'), module.__dict__)
        storage = sys.modules['dc_native_storage_registration']
        storage.local_dc_binding()
        native = sys.modules['dr_recovery_acceptance']
        network = sys.modules['dc_guest_network']
        api = native.Client(storage.ENDPOINT, payload.pop('apiKey'), payload.pop('apiSecret'))
        if payload['mode'] != 'Plan':
            fd = sys.modules['dc_storage_loader'].private_directory(JOURNAL)
            os.close(fd)
            journal = native.Journal(JOURNAL, {'schema': 1, 'vmId': '29ba176b-b81a-4f47-8f51-ecec869f247f',
                'mac': network.MAC, 'bridge': network.BRIDGE, 'physical': network.PHYSICAL}, storage.ENDPOINT)
        print(json.dumps(network.execute(api, journal, payload['mode']), sort_keys=True))
        return 0
    except Exception as exc:
        gate = sys.modules.get('dr_recovery_acceptance')
        status = str(exc) if gate and isinstance(exc, gate.GateError) else 'PRIVATE_INPUT_OR_NETWORK_GATE'
        import re
        if not re.fullmatch(r'[A-Z_]{1,100}', status):
            status = 'PRIVATE_INPUT_OR_NETWORK_GATE'
        print(json.dumps({'status': status, 'automaticReplay': False}))
        return 1
    finally:
        if journal:
            journal.close()


if __name__ == '__main__':
    raise SystemExit(main())
