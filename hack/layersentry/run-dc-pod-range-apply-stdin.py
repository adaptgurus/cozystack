#!/usr/bin/env python3
"""Versioned private stdin loader; no credentials written or printed."""
import base64
import fcntl
import hashlib
import json
import os
import stat
import sys
import types

PLAN_SHA256 = '240e1b1f9c28e703643ef21d0cf4aecb01ac87ccc4b166978e19a8b0b5bdf665'
JOURNAL = '/var/lib/layersentry/native-dc-pod-range-r0'
SOURCES = ('dr_recovery_acceptance', 'dc_native_storage_registration', 'dc_storage_loader', 'dc_pod_range')


def parse_payload(raw):
    if len(raw) > 524288:
        raise ValueError('INPUT_LIMIT')
    data = json.loads(raw)
    if set(data) != {'schema', 'target', 'mode', 'sources', 'proof', 'apiKey', 'apiSecret', 'labReceipts', 'reservation', 'reviewedPlan'}:
        raise ValueError('INPUT_FIELDS')
    if data['schema'] != 1 or data['target'] != '10.10.10.14' or data['mode'] not in ('Apply', 'Observe'):
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
    plan = base64.b64decode(data['reviewedPlan'], validate=True)
    if len(plan) > 65536 or hashlib.sha256(plan).hexdigest() != PLAN_SHA256:
        raise ValueError('REVIEWED_PLAN_DIGEST')
    for field in ('apiKey', 'apiSecret'):
        if not isinstance(data[field], str) or not 1 <= len(data[field]) <= 4096 or '\x00' in data[field]:
            raise ValueError('CREDENTIAL_SHAPE')
    return data


def fixture_binding(controller):
    return {'schema': 1, 'target': '10.10.10.14', 'planSha256': PLAN_SHA256,
            'zone': controller.ZONE, 'pod': controller.POD, 'parameters': controller.PARAMS,
            'receiptSha256': controller.LAB_RECEIPTS, 'reservation': controller.LAB_RESERVATION}


class ReadOnlyJournal:
    """Observe an existing root-private journal without creating/chmodding anything."""
    def __init__(self, path, binding, endpoint, native):
        self.directory_fd = None
        self.lock = None
        self.exists = False
        self.data = {'binding': native.digest({'fixture': binding, 'endpoint': endpoint}), 'operations': {}}
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in path.split('/')[1:]:
                native.require(component not in ('', '.', '..'), 'PRIVATE_JOURNAL_PATH_INVALID')
                next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            meta = os.fstat(fd)
            native.require(meta.st_uid == os.geteuid() and meta.st_mode & 0o077 == 0, 'PRIVATE_JOURNAL_DIRECTORY_REQUIRED')
            self.directory_fd = fd
            fd = None
            try:
                self.lock = os.open('lock', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.directory_fd)
            except FileNotFoundError:
                # If creation stopped before the lock existed, there must not be a journal.
                try:
                    os.stat('journal.json', dir_fd=self.directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    return
                raise ValueError('JOURNAL_WITHOUT_LOCK')
            lock_meta = os.fstat(self.lock)
            native.require(stat.S_ISREG(lock_meta.st_mode) and lock_meta.st_nlink == 1
                           and lock_meta.st_uid == os.geteuid() and lock_meta.st_mode & 0o077 == 0, 'PRIVATE_JOURNAL_LOCK_REQUIRED')
            fcntl.flock(self.lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            try:
                file_fd = os.open('journal.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.directory_fd)
            except FileNotFoundError:
                return
            with os.fdopen(file_fd, 'rb') as stream:
                before = os.fstat(stream.fileno())
                native.require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1
                               and before.st_uid == os.geteuid() and before.st_mode & 0o077 == 0
                               and before.st_size <= 65536, 'PRIVATE_JOURNAL_FILE_REQUIRED')
                raw = stream.read(65537)
                after = os.fstat(stream.fileno())
            native.require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                           (after.st_size, after.st_mtime_ns, after.st_ctime_ns), 'JOURNAL_CHANGED_DURING_OBSERVE')
            data = json.loads(raw)
            native.require(data.get('binding') == self.data['binding'], 'JOURNAL_BINDING_MISMATCH')
            native.require(isinstance(data.get('operations'), dict), 'JOURNAL_OPERATIONS_INVALID')
            self.data = data
            self.exists = True
        except FileNotFoundError:
            # A missing directory is a public absence observation, never created here.
            pass
        except Exception:
            self.close()
            raise
        finally:
            if fd is not None:
                os.close(fd)

    def close(self):
        if self.lock is not None:
            os.close(self.lock)
            self.lock = None
        if self.directory_fd is not None:
            os.close(self.directory_fd)
            self.directory_fd = None


def public_operation(journal, controller, native):
    operations = journal.data['operations']
    native.require(set(operations).issubset({'pod-range'}), 'JOURNAL_OPERATION_SCOPE_CHANGED')
    operation = operations.get('pod-range')
    if not operation:
        return {'state': 'NOT_SUBMITTED'}
    native.require(operation.get('params') == controller.PARAMS and operation.get('mode') == 'exclusive-disabled-dc-lab',
                   'RANGE_INTENT_CHANGED')
    state = operation.get('state')
    native.require(state in ('SUBMITTING', 'ASYNC_SUBMITTED', 'SUBMISSION_UNCERTAIN', 'RECONCILED'), 'JOURNAL_STATE_UNKNOWN')
    result = {'state': state}
    if operation.get('job_id') is not None:
        result['jobId'] = native.identifier(operation['job_id'])
    return result


def observe_result(api, journal, receipts, reservation, controller, native):
    operation = public_operation(journal, controller, native)
    result = controller.execute_lab(api, receipts, reservation, journal, apply=False)
    if 'jobId' in operation:
        status = api('queryAsyncJobResult', jobid=operation['jobId']).get('jobstatus')
        native.require(type(status) is int and status in (0, 1, 2, 3), 'NATIVE_JOB_STATUS_UNKNOWN')
        operation['nativeJobStatus'] = status
    current = (result['currentStart'], result['currentEnd'])
    if current == controller.NEW:
        native.require(operation['state'] != 'NOT_SUBMITTED', 'UNJOURNALED_RANGE_CHANGE')
        result['status'] = 'LAB_RANGE_OBSERVED_USAGE_UNKNOWN_NOT_SYSTEMVM_READY'
    else:
        result['status'] = 'LAB_RANGE_OLD_OBSERVED_NO_AUTOMATIC_REPLAY'
    result['journalOperation'] = operation
    result['journalWritesPerformed'] = False
    return result


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
        network = sys.modules['dc_pod_range']
        api = native.Client(storage.ENDPOINT, payload.pop('apiKey'), payload.pop('apiSecret'))
        receipts = {name: base64.b64decode(value, validate=True) for name, value in payload['labReceipts'].items()}
        network.verify_lab_receipts(receipts, payload['reservation'])
        binding = fixture_binding(network)
        if payload['mode'] == 'Apply':
            fd = sys.modules['dc_storage_loader'].private_directory(JOURNAL)
            os.close(fd)
            journal = native.Journal(JOURNAL, binding, storage.ENDPOINT)
            public_operation(journal, network, native)
            result = network.execute_lab(api, receipts, payload['reservation'], journal, apply=True)
            result['journalOperation'] = public_operation(journal, network, native)
            result['journalWritesPerformed'] = True
        else:
            journal = ReadOnlyJournal(JOURNAL, binding, storage.ENDPOINT, native)
            result = observe_result(api, journal, receipts, payload['reservation'], network, native)
        result['phase'] = payload['mode']
        result['reviewedPlanSha256'] = PLAN_SHA256
        result['automaticReplay'] = False
        print(json.dumps(result, sort_keys=True))
        return 0
    except Exception as exc:
        gate = sys.modules.get('dr_recovery_acceptance')
        status = str(exc) if gate and isinstance(exc, gate.GateError) else 'PRIVATE_INPUT_OR_NETWORK_GATE'
        import re
        if not re.fullmatch(r'[A-Z_]{1,100}', status):
            status = 'PRIVATE_INPUT_OR_NETWORK_GATE'
        result = {'status': status, 'automaticReplay': False}
        if journal and gate:
            try:
                result['journalOperation'] = public_operation(journal, sys.modules['dc_pod_range'], gate)
            except Exception:
                result['journalObservation'] = 'UNAVAILABLE_OR_INVALID'
        print(json.dumps(result))
        return 1
    finally:
        if journal:
            journal.close()


if __name__ == '__main__':
    raise SystemExit(main())
