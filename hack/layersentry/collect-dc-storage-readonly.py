#!/usr/bin/env python3
"""Read only the exact previously observed DC SystemVM image and pool identity."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import time
import xml.etree.ElementTree as ET

TARGET = '10.10.10.14'
DIRECTORY = '/export/secondary/template/tmpl/1/3'
IMAGE = '13f22f9c-61e2-4d88-93c0-5735212bccd0.qcow2'
POOL = '9c9fbd8f-e4ee-4e02-9767-6d1cc7a2b8c9'
PUBLIC_PROPERTIES = {
    'id': r'[0-9]{1,12}', 'public': r'true|false', 'qcow2': r'true|false',
    'uniquename': r'routing-[0-9]{1,12}', 'qcow2.filename': re.escape(IMAGE),
    'virtualsize': r'[0-9]{1,20}', 'qcow2.virtualsize': r'[0-9]{1,20}',
    'qcow2.size': r'[0-9]{1,20}',
}


def command(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=10)
        if p.returncode or len(p.stdout) > 1048576:
            return None
        return p.stdout
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return None


def open_directory(path):
    """Anchor each component without following symlinks."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('unsafe path')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def open_public_file(directory_fd, name, limit):
    if '/' in name or name in ('.', '..'):
        raise ValueError('unsafe name')
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1 or s.st_size > limit:
        os.close(fd)
        raise ValueError('unsafe file')
    return fd


def unchanged(before, after):
    return (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)


def storage_files(directory=DIRECTORY):
    result = {'directory': str(directory), 'versionEstablished': False}
    directory_fd = open_directory(directory)
    try:
        fd = open_public_file(directory_fd, 'template.properties', 16384)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            content = stream.read(16385)
            if len(content) > 16384 or not unchanged(before, os.fstat(stream.fileno())):
                raise ValueError('metadata changed')
        properties = {}
        for line in content.decode('ascii').splitlines():
            key, separator, value = line.partition('=')
            if separator and key in PUBLIC_PROPERTIES:
                if key in properties or not re.fullmatch(PUBLIC_PROPERTIES[key], value):
                    raise ValueError('invalid public metadata')
                properties[key] = value
        result['properties'] = properties
        fd = open_public_file(directory_fd, IMAGE, 2 * 1024**3)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            header = stream.read(72)
            if len(header) < 72 or header[:4] != b'QFI\xfb':
                raise ValueError('not qcow2')
            version = struct.unpack('>I', header[4:8])[0]
            if version not in (2, 3):
                raise ValueError('unsupported qcow2')
            sha = hashlib.sha256()
            stream.seek(0)
            total = 0
            deadline = time.monotonic() + 60
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                total += len(chunk)
                if total > 2 * 1024**3 or time.monotonic() > deadline:
                    raise ValueError('hash limit')
                sha.update(chunk)
            if total != before.st_size or not unchanged(before, os.fstat(stream.fileno())):
                raise ValueError('image changed')
        result['image'] = {'name': IMAGE, 'sizeBytes': total, 'sha256': sha.hexdigest(),
                           'uid': before.st_uid, 'mode': oct(stat.S_IMODE(before.st_mode)),
                           'qcow2Version': version, 'virtualSizeBytes': struct.unpack('>Q', header[24:32])[0],
                           'hasBackingFile': bool(struct.unpack('>Q', header[8:16])[0] or struct.unpack('>I', header[16:20])[0]),
                           'encryptionMethod': struct.unpack('>I', header[32:36])[0]}
        result['status'] = 'OBSERVED_NOT_AUTHENTICATED'
        return result
    finally:
        os.close(directory_fd)


def pool_identity():
    names_raw = command(['virsh', '--readonly', '-c', 'qemu:///system', 'pool-list', '--all', '--name'])
    names = (names_raw or '').split()
    if names_raw is None or len(names) > 128 or any(not re.fullmatch(r'[A-Za-z0-9_.-]{1,64}', name) for name in names):
        return {'status': 'POOL_LIST_UNAVAILABLE'}
    raw = command(['virsh', '--readonly', '-c', 'qemu:///system', 'pool-dumpxml', POOL])
    if raw is None:
        return {'status': 'UNAVAILABLE'}
    try:
        if '<!DOCTYPE' in raw or '<!ENTITY' in raw:
            raise ValueError('unsafe xml')
        tree = ET.fromstring(raw)
        if tree.tag != 'pool' or tree.findtext('uuid') != POOL:
            raise ValueError('wrong pool')
        public = {'uuid': POOL}
        values = {'name': tree.findtext('name'), 'type': tree.get('type'),
                  'sourceHost': tree.find('source/host').get('name') if tree.find('source/host') is not None else None,
                  'sourceDirectory': tree.find('source/dir').get('path') if tree.find('source/dir') is not None else None,
                  'targetPath': tree.findtext('target/path')}
        for key, value in values.items():
            if value is not None:
                public[key] = value if re.fullmatch(r'[A-Za-z0-9_.:/-]{1,256}', value) else '[OMITTED]'
        return {'status': 'OBSERVED', 'identity': public, 'allPoolNames': sorted(names)}
    except (ValueError, ET.ParseError):
        return {'status': 'INVALID_OUTPUT'}


def public_routes():
    raw = command(['ip', '-j', '-4', 'route', 'show', 'table', 'main'])
    try:
        data = json.loads(raw or 'null')
        if not isinstance(data, list) or len(data) > 128:
            raise ValueError('invalid route list')
        values = []
        for route in data:
            if not isinstance(route, dict):
                raise ValueError('invalid route')
            values.append({k: v for k, v in route.items() if k in {'dst', 'gateway', 'dev', 'prefsrc', 'protocol', 'scope'}
                           and isinstance(v, str) and re.fullmatch(r'[A-Za-z0-9_./:-]{1,128}', v)})
        return {'status': 'OBSERVED', 'routes': values}
    except (ValueError, TypeError):
        return {'status': 'UNAVAILABLE_OR_INVALID'}


def plugin_package():
    package = command(['rpm', '-q', '--qf', '%{NAME} %{VERSION} %{RELEASE}', 'cloudstack-management'])
    files = command(['rpm', '-ql', 'cloudstack-management'])
    if package is None or files is None or not re.fullmatch(r'cloudstack-management [A-Za-z0-9_.+-]+ [A-Za-z0-9_.+-]+', package):
        return {'status': 'UNAVAILABLE'}
    names = [line for line in files.splitlines() if re.fullmatch(r'/usr/(?:share|lib)/[A-Za-z0-9_./-]+/cloud-plugin-backup-nas-[A-Za-z0-9_.-]+\.jar', line)]
    if len(names) > 16:
        return {'status': 'OUTPUT_LIMIT'}
    return {'status': 'PACKAGE_OBSERVED', 'managementPackage': package,
            'nasPluginPackagePaths': names, 'pluginLoaded': 'NOT_ESTABLISHED'}


def registration_journal(directory='/var/lib/layersentry/native-dc-storage-r0', allowed=('primary', 'image')):
    try:
        directory_fd = open_directory(directory)
    except FileNotFoundError:
        return {'status': 'DIRECTORY_ABSENT'}
    except OSError:
        return {'status': 'DIRECTORY_UNAVAILABLE'}
    try:
        try:
            fd = open_public_file(directory_fd, 'journal.json', 65536)
        except FileNotFoundError:
            return {'status': 'JOURNAL_ABSENT'}
        with os.fdopen(fd, 'rb') as stream:
            raw = stream.read(65537)
        data = json.loads(raw)
        operations = data.get('operations')
        if not isinstance(operations, dict) or not set(operations).issubset(set(allowed)):
            raise ValueError('journal shape')
        public = {}
        for name, item in operations.items():
            if not isinstance(item, dict):
                raise ValueError('journal shape')
            public[name] = {key: value for key, value in item.items() if key in {'command', 'state', 'resource_id'}
                            and isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,100}', value)}
        return {'status': 'OBSERVED', 'operations': public}
    except (OSError, ValueError, TypeError):
        return {'status': 'JOURNAL_UNAVAILABLE_OR_INVALID'}
    finally:
        os.close(directory_fd)


def guest_network_presence():
    """Public NIC/profile identity only; never request secrets or modify NM."""
    result = {'status': 'UNAVAILABLE', 'configurationChanged': False, 'profiles': []}
    raw = command(['ip', '-j', 'address', 'show'])
    try:
        links = json.loads(raw or 'null')
        if not isinstance(links, list) or len(links) > 256:
            raise ValueError('links')
        result['links'] = [{key: row[key] for key in ('ifname', 'ifindex', 'address', 'master', 'flags', 'operstate') if key in row}
                           | {'addresses': [{key: item[key] for key in ('family', 'local', 'prefixlen', 'scope') if key in item}
                                            for item in row.get('addr_info', [])]} for row in links]
        raw = command(['nmcli', '-g', 'UUID', 'connection', 'show'])
        if raw is None:
            raise ValueError('profiles')
        ids = raw.splitlines()
        if len(ids) > 128 or len(set(ids)) != len(ids) or not all(re.fullmatch(r'[0-9a-f-]{36}', item) for item in ids):
            raise ValueError('profiles')
        fields = ('connection.id', 'connection.uuid', 'connection.type', 'connection.interface-name',
                  'connection.autoconnect', 'connection.master', 'connection.slave-type',
                  '802-3-ethernet.mac-address', 'ipv4.method', 'ipv6.method',
                  'connection.timestamp', 'GENERAL.STATE', 'GENERAL.DEVICES')
        for identity in ids:
            # Ethernet settings are not valid for every NM connection type; query
            # separately so an absent property remains explicit, not guessed.
            public = {}
            for field in fields:
                value = command(['nmcli', '-g', field, '-e', 'no', 'connection', 'show', 'uuid', identity])
                public[field] = value.strip()[:256] if value is not None else None
            result['profiles'].append(public)
        result['status'] = 'OBSERVED'
    except (ValueError, TypeError, KeyError):
        result['status'] = 'INVALID_OR_UNAVAILABLE'
    result['journal'] = registration_journal('/var/lib/layersentry/native-dc-guest-network-r0',
                                              ('bridge', 'port', 'activate', 'label'))
    return result


def tls_presence():
    services = {}
    for name in ('nginx', 'httpd', 'haproxy', 'cloudstack-management'):
        value = command(['systemctl', 'show', name, '--property=LoadState,ActiveState', '--no-pager'])
        fields = {}
        for line in (value or '').splitlines():
            key, _, item = line.partition('=')
            if key in ('LoadState', 'ActiveState') and re.fullmatch(r'[a-z-]{1,30}', item):
                fields[key] = item
        services[name] = fields or {'status': 'UNAVAILABLE'}
    raw = command(['ss', '-H', '-ltn'])
    listeners = []
    for line in (raw or '').splitlines():
        fields = line.split()
        if len(fields) >= 5 and fields[0] == 'LISTEN':
            address, _, port = fields[3].rpartition(':')
            if port in ('443', '8443', '8080') and re.fullmatch(r'[0-9a-fA-F.:*\[\]]{1,64}', address):
                listeners.append({'address': address, 'port': int(port)})
    paths = {}
    for path in ('/etc/nginx/nginx.conf', '/etc/httpd/conf/httpd.conf', '/etc/haproxy/haproxy.cfg',
                 '/etc/cloudstack/management/server.properties', '/usr/share/cloudstack-management/conf/server.xml'):
        try:
            metadata = os.lstat(path)
            paths[path] = 'REGULAR_FILE_PRESENT' if stat.S_ISREG(metadata.st_mode) else 'NONREGULAR_OR_SYMLINK_PRESENT'
        except FileNotFoundError:
            paths[path] = 'ABSENT'
        except OSError:
            paths[path] = 'UNAVAILABLE'
    return {'services': services, 'listeners': listeners, 'listenerStatus': 'OBSERVED' if raw is not None else 'UNAVAILABLE',
            'configPaths': paths, 'configContentsRead': False, 'trustedHttpsEndpoint': 'NOT_ESTABLISHED'}


def collect():
    result = {'schemaVersion': '1.0', 'target': TARGET, 'mutationPerformed': False}
    raw = command(['ip', '-j', '-4', 'address', 'show'])
    try:
        addresses = json.loads(raw or '[]')
        bound = os.geteuid() == 0 and any(a.get('local') == TARGET for link in addresses for a in link.get('addr_info', []))
    except (ValueError, TypeError, AttributeError):
        bound = False
    if not bound:
        return dict(result, status='TARGET_BINDING_FAILED')
    try:
        result['systemVm'] = storage_files()
    except (OSError, ValueError, UnicodeError):
        result['systemVm'] = {'status': 'UNAVAILABLE_OR_CHANGED', 'versionEstablished': False}
    result['pool'] = pool_identity()
    result['routes'] = public_routes()
    result['managementPlugin'] = plugin_package()
    result['registrationJournal'] = registration_journal()
    result['tlsPresence'] = tls_presence()
    result['guestNetwork'] = guest_network_presence()
    return dict(result, status='COLLECTED')


if __name__ == '__main__':
    evidence = collect()
    print(json.dumps(evidence, sort_keys=True))
    raise SystemExit(0 if evidence['status'] == 'COLLECTED' else 1)
