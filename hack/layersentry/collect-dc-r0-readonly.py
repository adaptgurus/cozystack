#!/usr/bin/env python3
"""Bounded, allowlisted DC host inventory; no config contents or service logs."""

import json
import os
from pathlib import Path
import re
import subprocess
import time


TARGET = '10.10.10.14'
PATHS = ('/export/primary', '/export/secondary', '/var/lib/libvirt/images',
         '/usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt')


def command(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=8)
        if result.returncode != 0:
            return {'status': 'UNAVAILABLE', 'exitCode': result.returncode}
        if len(result.stdout) > 1048576:
            return {'status': 'OUTPUT_LIMIT'}
        return {'status': 'OK', 'output': result.stdout}
    except subprocess.TimeoutExpired:
        return {'status': 'TIMEOUT'}
    except (OSError, UnicodeError):
        return {'status': 'UNAVAILABLE'}


def text_inventory(args):
    result = command(args)
    if result['status'] == 'OK':
        # Names/versions only. Never return raw errors, logs or config contents.
        lines = result.pop('output').splitlines()
        if len(lines) > 128 or any(not re.fullmatch(r'[A-Za-z0-9_.:/+*, -]{1,256}', line) for line in lines if line):
            return {'status': 'INVALID_OUTPUT'}
        result['values'] = [line.strip() for line in lines if line.strip()]
    return result


def json_inventory(args, keys):
    result = command(args)
    if result['status'] != 'OK':
        return result
    try:
        data = json.loads(result['output'])
    except (ValueError, TypeError):
        return {'status': 'INVALID_OUTPUT'}

    truncated = False

    def project(value):
        nonlocal truncated
        if isinstance(value, dict):
            return {key: ('[OMITTED]' if key == 'source' and isinstance(item, str)
                          and (item.startswith('//') or '@' in item) else project(item))
                    for key, item in value.items() if key in keys}
        if isinstance(value, list):
            truncated = truncated or len(value) > 128
            return [project(item) for item in value[:128]]
        if isinstance(value, str):
            truncated = truncated or len(value) > 256
            return value[:256] if re.fullmatch(r'[A-Za-z0-9_.:/@+% -]*', value) else '[OMITTED]'
        return value if value is None or isinstance(value, (bool, int, float)) else None

    projected = project(data)
    return {'status': 'OK', 'data': projected, 'truncated': truncated}


def path_inventory(path):
    item = {'path': str(path), 'exists': path.exists(), 'symlink': path.is_symlink()}
    if item['exists'] and not item['symlink']:
        try:
            stat = path.stat()
            item.update(directory=path.is_dir(), sizeBytes=stat.st_size)
            if path.is_dir():
                space = os.statvfs(path)
                item.update(freeBytes=space.f_bavail * space.f_frsize, totalBytes=space.f_blocks * space.f_frsize)
        except OSError:
            item['status'] = 'UNAVAILABLE'
    return item


def templates(root):
    """Inspect names and sizes only; never follow links or read template metadata."""
    result = {'root': str(root), 'files': [], 'status': 'OK'}
    if not root.is_dir() or root.resolve() != root.absolute():
        result['status'] = 'ABSENT_OR_SYMLINK'
        return result
    pending = [(root, 0)]
    visited = 0
    deadline = time.monotonic() + 8
    try:
        while pending:
            directory, depth = pending.pop()
            with os.scandir(directory) as entries:
                for entry in entries:
                    visited += 1
                    if visited > 1024 or len(result['files']) >= 128 or time.monotonic() > deadline:
                        result['status'] = 'TRUNCATED'
                        return result
                    if entry.is_symlink():
                        continue
                    if entry.is_dir(follow_symlinks=False):
                        if depth < 4:
                            pending.append((Path(entry.path), depth + 1))
                        else:
                            result['status'] = 'TRUNCATED'
                    elif entry.is_file(follow_symlinks=False) and (entry.name == 'template.properties' or entry.name.endswith(('.qcow2', '.qcow2.bz2', '.qcow2.gz'))):
                        relative = str(Path(entry.path).relative_to(root))
                        if re.fullmatch(r'[A-Za-z0-9_./ -]{1,256}', relative):
                            result['files'].append({'name': relative, 'sizeBytes': entry.stat(follow_symlinks=False).st_size})
    except OSError:
        result['status'] = 'UNAVAILABLE'
    return result


def collect():
    addresses = json_inventory(['ip', '-j', '-4', 'address', 'show'],
                               {'ifname', 'operstate', 'master', 'addr_info', 'local', 'prefixlen', 'scope'})
    local_addresses = [addr.get('local') for link in addresses.get('data', [])
                       for addr in link.get('addr_info', [])] if isinstance(addresses.get('data'), list) else []
    if os.geteuid() != 0 or TARGET not in local_addresses:
        return {'schemaVersion': '1.0', 'target': TARGET, 'status': 'TARGET_BINDING_FAILED', 'mutationPerformed': False}
    services = ('cloudstack-management', 'cloudstack-agent', 'libvirtd', 'virtqemud', 'nfs-server', 'rpcbind')
    packages = ('cloudstack-management', 'cloudstack-agent', 'cloudstack-common', 'libvirt', 'qemu-kvm', 'nfs-utils')
    return {
        'schemaVersion': '1.0', 'target': TARGET, 'status': 'COLLECTED', 'mutationPerformed': False,
        'hostname': text_inventory(['hostname', '-f']),
        'rockyRelease': text_inventory(['rpm', '-q', '--qf', '%{NAME} %{VERSION}', 'rocky-release']),
        'kernel': text_inventory(['uname', '-r']),
        'addresses': addresses,
        'bridges': json_inventory(['ip', '-j', 'link', 'show', 'type', 'bridge'], {'ifname', 'operstate', 'mtu', 'master', 'link_type'}),
        'bridgePorts': json_inventory(['bridge', '-j', 'link', 'show'], {'ifname', 'master', 'state', 'operstate'}),
        'filesystems': json_inventory(['findmnt', '--json', '--output', 'TARGET,SOURCE,FSTYPE'], {'filesystems', 'children', 'target', 'source', 'fstype'}),
        'blockDevices': json_inventory(['lsblk', '--json', '--bytes', '--output', 'NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT'], {'blockdevices', 'children', 'name', 'type', 'size', 'fstype', 'mountpoint'}),
        'nfsExports': text_inventory(['showmount', '--no-headers', '--exports', '127.0.0.1']),
        'services': {name: text_inventory(['systemctl', 'show', '--property=ActiveState', '--value', name]) for name in services},
        'packages': {name: text_inventory(['rpm', '-q', '--qf', '%{NAME} %{VERSION} %{RELEASE}', name]) for name in packages},
        'libvirtDomains': text_inventory(['virsh', '--readonly', '-c', 'qemu:///system', 'list', '--all', '--name']),
        'libvirtPools': text_inventory(['virsh', '--readonly', '-c', 'qemu:///system', 'pool-list', '--all', '--name']),
        'paths': [path_inventory(Path(path)) for path in PATHS],
        'systemVmTemplates': templates(Path('/export/secondary/template/tmpl')),
    }


if __name__ == '__main__':
    evidence = collect()
    print(json.dumps(evidence, sort_keys=True))
    raise SystemExit(0 if evidence['status'] == 'COLLECTED' else 1)
