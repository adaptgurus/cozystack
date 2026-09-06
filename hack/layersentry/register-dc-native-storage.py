#!/usr/bin/env python3
"""Bounded native DC registration; explicit execution, durable intent, no replay."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
import urllib.parse

from dr_recovery_acceptance import Client, GateError, Journal, identifier, require

ENDPOINT = 'http://127.0.0.1:8080/client/api'
DC = '10.10.10.14'
ZONE = '929d1f2c-d629-41ed-96b4-6c48a288d056'
POD = '020dc658-af4e-4e2e-bed5-0607de8a787f'
CLUSTER = '7d2bb586-6b60-4c51-aa5f-3b4903f31e51'
HOST = '3abb80a8-bc4a-48de-bc99-dedc5ac91bf9'
PRESERVED_POOL = '9c9fbd8f-e4ee-4e02-9767-6d1cc7a2b8c9'
RESOURCES = {
    'primary': {'list': 'listStoragePools', 'kind': 'storagepool', 'create': 'createStoragePool',
                'params': {'name': 'layersentry-dc-primary-r0', 'url': 'nfs://10.10.10.14/export/primary',
                           'zoneid': ZONE, 'podid': POD, 'clusterid': CLUSTER, 'scope': 'cluster'}},
    'image': {'list': 'listImageStores', 'kind': 'imagestore', 'create': 'addImageStore',
              'params': {'name': 'layersentry-dc-secondary-r0', 'url': 'nfs://10.10.10.14/export/secondary',
                         'zoneid': ZONE, 'provider': 'NFS'}},
}


def rows(api, command, kind, **params):
    payload = api(command, page=1, pagesize=1000, **params)
    result = payload.get(kind, [])
    require(isinstance(result, list) and len(result) < 1000 and all(isinstance(r, dict) for r in result), 'INVENTORY_SHAPE_OR_LIMIT')
    count = payload.get('count')
    require(count is None or (type(count) is int and count == len(result)), 'INVENTORY_INCOMPLETE')
    return result


def exact(api, command, kind, identity):
    result = rows(api, command, kind, id=identity)
    require(len(result) == 1 and result[0].get('id') == identity, 'SCOPE_IDENTITY_MISSING')
    return result[0]


def preflight(api):
    zone = exact(api, 'listZones', 'zone', ZONE)
    require(zone.get('networktype') == 'Basic' and zone.get('allocationstate') == 'Disabled', 'SOURCE_ZONE_CHANGED')
    pod = exact(api, 'listPods', 'pod', POD)
    cluster = exact(api, 'listClusters', 'cluster', CLUSTER)
    host = exact(api, 'listHosts', 'host', HOST)
    require(pod.get('zoneid') == ZONE and pod.get('allocationstate') == 'Enabled', 'POD_CHANGED')
    require(cluster.get('zoneid') == ZONE and cluster.get('podid') == POD
            and cluster.get('hypervisortype') == 'KVM' and cluster.get('allocationstate') == 'Enabled', 'CLUSTER_CHANGED')
    require(host.get('zoneid') == ZONE and host.get('podid') == POD and host.get('clusterid') == CLUSTER
            and host.get('hypervisor') == 'KVM' and host.get('state') == 'Up'
            and host.get('resourcestate') == 'Enabled', 'HOST_CHANGED')


def match_resource(api, key):
    spec = RESOURCES[key]
    # List across Zones so duplicate names/endpoints in another scope cannot be hidden.
    inventory = rows(api, spec['list'], spec['kind'])
    candidates = []
    for row in inventory:
        if key == 'primary':
            physical = row.get('ipaddress') == DC and isinstance(row.get('path'), str) and row['path'].rstrip('/') == '/export/primary'
        else:
            physical = False
            try:
                url = urllib.parse.urlsplit(row.get('url', ''))
                physical = (url.scheme == 'nfs' and url.hostname == DC and url.port in (None, 2049)
                            and not url.username and not url.password and not url.query and not url.fragment
                            and url.path.rstrip('/') == '/export/secondary')
            except (ValueError, TypeError, AttributeError):
                pass
        if physical or row.get('name') == spec['params']['name']:
            require(physical and row.get('zoneid') == ZONE, 'STORAGE_IDENTITY_CONFLICT')
            if key == 'primary':
                require(row.get('podid') == POD and row.get('clusterid') == CLUSTER
                        and row.get('scope') == 'CLUSTER' and row.get('type') == 'NetworkFilesystem', 'PRIMARY_SCOPE_CONFLICT')
            else:
                require(row.get('protocol') == 'nfs' and row.get('providername') == 'NFS'
                        and row.get('scope') == 'ZONE', 'IMAGE_SCOPE_CONFLICT')
            identifier(row.get('id'))
            candidates.append(row)
    require(len(candidates) <= 1, 'DUPLICATE_STORAGE_IDENTITY')
    return candidates[0] if candidates else None


def register_one(api, journal, key, execute=False, preserve_pool=None):
    if preserve_pool is not None:
        preserve_pool()
    preflight(api)
    spec = RESOURCES[key]
    operations = journal.data['operations']
    operation = operations.get(key)
    if operation:
        require(operation.get('command') == spec['create'] and operation.get('params') == spec['params'], 'JOURNAL_OPERATION_MISMATCH')
    current = match_resource(api, key)
    if current:
        if operation and operation.get('resource_id'):
            require(operation['resource_id'] == current['id'], 'REGISTERED_RESOURCE_REPLACED')
        state = 'RECONCILED' if operation else 'OBSERVED_EXISTING'
        operations[key] = {'command': spec['create'], 'params': spec['params'], 'state': state, 'resource_id': current['id']}
        journal.save()
        return {'status': state, 'id': current['id'], 'runtimeState': current.get('state', 'NOT_REPORTED')}
    if operation:
        # Even a timeout followed by an empty list is not permission to submit again.
        raise GateError('INTENT_WITHOUT_OBSERVED_RESOURCE_NO_REPLAY')
    if not execute:
        return {'status': 'PROPOSED', 'command': spec['create'], 'params': spec['params']}
    operations[key] = {'command': spec['create'], 'params': spec['params'], 'state': 'SUBMITTING'}
    journal.save()  # Must be durable before the API can receive a request.
    try:
        response = api(spec['create'], **spec['params'])
    except Exception:
        operations[key]['state'] = 'SUBMISSION_UNCERTAIN'
        journal.save()
        # The only follow-up is identity reconciliation. Raw response/errors are never emitted.
    else:
        operations[key]['state'] = 'RESPONSE_RECEIVED_UNRECONCILED'
        returned = response.get(spec['kind'], {}) if isinstance(response, dict) else {}
        if isinstance(returned, dict) and returned.get('id'):
            operations[key]['resource_id'] = identifier(returned['id'])
        journal.save()
    current = match_resource(api, key)
    require(current is not None, 'INTENT_WITHOUT_OBSERVED_RESOURCE_NO_REPLAY')
    if operations[key].get('resource_id'):
        require(operations[key]['resource_id'] == current['id'], 'REGISTERED_RESOURCE_REPLACED')
    if preserve_pool is not None:
        preserve_pool()
    operations[key].update(state='RECONCILED', resource_id=current['id'])
    journal.save()
    return {'status': 'RECONCILED', 'id': current['id'], 'runtimeState': current.get('state', 'NOT_REPORTED')}


def validate_proof(proof):
    require(proof.get('schemaVersion') == '1.0' and proof.get('target') == DC
            and proof.get('mutationPerformed') is False and proof.get('status') == 'COLLECTED', 'PUBLIC_PROOF_BINDING')
    pool = proof.get('pool', {})
    require(pool.get('status') == 'OBSERVED' and pool.get('identity', {}).get('uuid') == PRESERVED_POOL, 'EXISTING_POOL_PROOF_REQUIRED')
    require(pool['identity'].get('sourceHost') == DC and pool['identity'].get('sourceDirectory') == '/export/primary', 'EXISTING_POOL_SOURCE_UNRECONCILED')
    image = proof.get('systemVm', {}).get('image', {})
    require(proof.get('systemVm', {}).get('status') == 'OBSERVED_NOT_AUTHENTICATED'
            and re.fullmatch(r'[0-9a-f]{64}', str(image.get('sha256', ''))) is not None, 'IMAGE_OBSERVATION_REQUIRED')
    require(image.get('hasBackingFile') is False and image.get('encryptionMethod') == 0, 'IMAGE_CHAIN_OR_ENCRYPTION_UNSUPPORTED')
    require(proof['systemVm'].get('directory') == '/export/secondary/template/tmpl/1/3'
            and image.get('name') == '13f22f9c-61e2-4d88-93c0-5735212bccd0.qcow2', 'IMAGE_IDENTITY_MISMATCH')


def preserve_live_pool(proof):
    """Check the pre-existing pool identity without redefining, starting or deleting it."""
    try:
        p = subprocess.run(['virsh', '--readonly', '-c', 'qemu:///system', 'pool-dumpxml', PRESERVED_POOL],
                           capture_output=True, text=True, timeout=10, check=True)
        require(len(p.stdout) < 65536 and '<!DOCTYPE' not in p.stdout and '<!ENTITY' not in p.stdout, 'POOL_XML_INVALID')
        tree = ET.fromstring(p.stdout)
        expected = proof['pool']['identity']
        require(tree.tag == 'pool' and tree.findtext('uuid') == PRESERVED_POOL
                and tree.findtext('name') == expected.get('name') and tree.get('type') == expected.get('type')
                and tree.findtext('target/path') == expected.get('targetPath')
                and tree.find('source/host').get('name') == DC
                and tree.find('source/dir').get('path') == '/export/primary', 'EXISTING_POOL_CHANGED')
    except GateError:
        raise
    except Exception:
        raise GateError('EXISTING_POOL_OBSERVATION_FAILED') from None


def local_dc_binding():
    require(os.geteuid() == 0, 'DC_ROOT_REQUIRED')
    try:
        p = subprocess.run(['ip', '-j', '-4', 'address', 'show'], capture_output=True, text=True, timeout=10, check=True)
        addresses = json.loads(p.stdout)
        require(any(a.get('local') == DC for link in addresses for a in link.get('addr_info', [])), 'DC_LOCAL_ADDRESS_REQUIRED')
    except GateError:
        raise
    except Exception:
        raise GateError('DC_LOCAL_ADDRESS_REQUIRED') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--journal', required=True, help='Existing private persistent directory, preserved across executions')
    parser.add_argument('--proof-file', required=True, help='Reviewed public storage proof JSON')
    parser.add_argument('--proof-sha256', required=True, help='Independently pinned hash of the exact public proof file')
    parser.add_argument('--execute', action='store_true', help='Explicitly allow only the two native registration calls')
    args = parser.parse_args()
    journal = None
    try:
        local_dc_binding()
        path = Path(args.proof_file)
        require(not path.is_symlink() and path.is_file() and path.stat().st_size <= 65536, 'PROOF_FILE_INVALID')
        raw = path.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == args.proof_sha256, 'PROOF_HASH_MISMATCH')
        proof = json.loads(raw.decode('utf-8-sig'))
        validate_proof(proof)
        api = Client(ENDPOINT, os.environ.pop('CLOUDSTACK_API_KEY', ''), os.environ.pop('CLOUDSTACK_SECRET_KEY', ''))
        binding = {'schema': 1, 'zone': ZONE, 'resources': RESOURCES, 'preservedPool': PRESERVED_POOL, 'proofSha256': args.proof_sha256}
        journal = Journal(args.journal, binding, ENDPOINT)
        evidence = {'schema': 1, 'target': DC, 'executeRequested': args.execute, 'preservedPool': PRESERVED_POOL,
                    'zoneEnabled': False, 'templateReadiness': 'NOT_ESTABLISHED', 'recoveryReadiness': 'NOT_TESTED', 'resources': {}}
        for key in ('primary', 'image'):
            evidence['resources'][key] = register_one(api, journal, key, args.execute, lambda: preserve_live_pool(proof))
        print(json.dumps(evidence, sort_keys=True))
        return 0
    except GateError as exc:
        print(json.dumps({'status': str(exc), 'automaticReplay': False}))
        return 1
    except Exception:
        print(json.dumps({'status': 'REGISTRATION_OR_JOURNAL_FAILURE', 'automaticReplay': False}))
        return 1
    finally:
        if journal is not None:
            journal.close()


if __name__ == '__main__':
    raise SystemExit(main())
