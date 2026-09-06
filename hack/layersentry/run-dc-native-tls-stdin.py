#!/usr/bin/env python3
"""Exact native TLS private-stdin loader; no API credentials or private keys in evidence."""
import base64
import hashlib
import json
import os
import re
import sys
import types

SOURCES = ('dr_recovery_acceptance', 'dc_native_storage_registration', 'dc_storage_loader', 'dc_native_tls')
JOURNAL = '/var/lib/layersentry/native-dc-tls-r0'
PROOF_SHA256 = 'f268bcf25a51e28d33fe475607252d2c8219b51fa9b1f70ea35450c775f2d3a1'


def parse_payload(raw):
    if len(raw) > 524288: raise ValueError('INPUT_LIMIT')
    data = json.loads(raw)
    if set(data) != {'schema', 'target', 'mode', 'sources', 'proof', 'apiKey', 'apiSecret', 'plan', 'planSha256', 'firewallSources'}: raise ValueError('INPUT_FIELDS')
    if data['schema'] != 1 or data['target'] != '10.10.10.14' or data['mode'] not in ('Plan', 'Prepare', 'Install', 'Activate', 'Firewall'): raise ValueError('INPUT_SCOPE')
    if set(data['sources']) != set(SOURCES): raise ValueError('SOURCE_SCOPE')
    for value in data['sources'].values():
        if set(value) != {'base64', 'sha256'} or len(value['base64']) > 131072: raise ValueError('SOURCE_SIZE')
        source = base64.b64decode(value['base64'], validate=True)
        if len(source) > 65536 or hashlib.sha256(source).hexdigest() != value['sha256']: raise ValueError('SOURCE_DIGEST')
    proof = base64.b64decode(data['proof'], validate=True)
    if hashlib.sha256(proof).hexdigest() != PROOF_SHA256: raise ValueError('PROOF_DIGEST')
    for key in ('apiKey', 'apiSecret'):
        if not isinstance(data[key], str) or not 1 <= len(data[key]) <= 4096 or '\x00' in data[key]: raise ValueError('CREDENTIAL_SHAPE')
    if data['mode'] != 'Plan' and not re.fullmatch('[0-9a-f]{64}', data['planSha256']): raise ValueError('PLAN_FINGERPRINT_REQUIRED')
    return data


def main():
    journal = None
    try:
        os.umask(0o077)
        payload = parse_payload(sys.stdin.buffer.read(524289))
        for name in SOURCES:
            module = types.ModuleType(name); sys.modules[name] = module
            source = base64.b64decode(payload['sources'][name]['base64'], validate=True).decode('utf-8')
            exec(compile(source, '<reviewed-' + name + '>', 'exec'), module.__dict__)
        native = sys.modules['dr_recovery_acceptance']; storage = sys.modules['dc_native_storage_registration']; tls = sys.modules['dc_native_tls']
        storage.local_dc_binding()
        api = native.Client(storage.ENDPOINT, payload.pop('apiKey'), payload.pop('apiSecret'))
        mode = payload['mode']
        if mode == 'Plan':
            expected = tls.plan(api, firewall_sources=payload['firewallSources'])
            result = {'status': 'PARTIAL', 'plan': expected, 'planSha256': native.digest(expected)}
        else:
            expected = payload['plan']; tls.validate_plan(expected)
            native.require(native.digest(expected) == payload['planSha256'] and expected['firewallSources'] == payload['firewallSources'], 'TLS_REVIEWED_PLAN_BINDING_REQUIRED')
            fd = sys.modules['dc_storage_loader'].private_directory(JOURNAL); os.close(fd)
            journal = native.Journal(JOURNAL, expected, storage.ENDPOINT)
            operation = {'Prepare': tls.prepare, 'Install': tls.install, 'Activate': tls.activate, 'Firewall': tls.firewall}[mode]
            result = operation(api, journal, expected)
        result.update(schema=1, target='10.10.10.14', phase=mode, productionCertified=False, automaticReplay=False)
        print(json.dumps(result, sort_keys=True))
        return 0
    except Exception as error:
        native = sys.modules.get('dr_recovery_acceptance')
        code = str(error) if native and isinstance(error, native.GateError) else 'TLS_PRIVATE_INPUT_OR_NATIVE_GATE'
        if not re.fullmatch('[A-Z_]{1,100}', code): code = 'TLS_PRIVATE_INPUT_OR_NATIVE_GATE'
        print(json.dumps({'schema': 1, 'target': '10.10.10.14', 'status': 'BLOCKED', 'reason': code, 'automaticReplay': False, 'productionCertified': False}))
        return 1
    finally:
        if journal: journal.close()


if __name__ == '__main__': raise SystemExit(main())
