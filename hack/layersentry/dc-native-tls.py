#!/usr/bin/env python3
"""Native DC HTTPS prerequisite. Secrets stay target-local; uncertain issuance never replays."""
import grp
import hashlib
import json
import ipaddress
import ssl
import urllib.request
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import subprocess

from dr_recovery_acceptance import Client, NoRedirect, GateError, require, identifier, digest
from dc_native_storage_registration import preflight, rows, local_dc_binding, ENDPOINT

TARGET = '10.10.10.14'
VM_ID = '29ba176b-b81a-4f47-8f51-ecec869f247f'
BIOS_UUID = 'ccbcac90-c8e3-4091-90a0-7e2e8cf2f7e5'
IDENTITY_EVIDENCE = {'runId': '34062671636', 'source': '591272077e47d52d52aaf54b3f012bcf4a776520'}
CONFIG = Path('/etc/cloudstack/management/server.properties')
KEYSTORE = Path('/etc/cloudstack/management/layersentry-dc-native-tls.jks')
ALIAS = 'layersentry-dc-native-tls'


def sha(data): return hashlib.sha256(data).hexdigest()


def run(args, data=None):
    try:
        output = subprocess.run(args, input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=45, env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL': 'C'})
        require(output.returncode == 0 and len(output.stdout) <= 65536, 'TLS_NATIVE_COMMAND_FAILED')
        return output.stdout
    except (OSError, subprocess.TimeoutExpired):
        raise GateError('TLS_NATIVE_COMMAND_FAILED') from None


def read_file(path, private=False, maximum=65536):
    path = Path(path)
    require(path.is_absolute(), 'TLS_ABSOLUTE_PATH_REQUIRED')
    for parent in (path, *path.parents):
        require(not parent.is_symlink(), 'TLS_PATH_SYMLINK')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= maximum,
                'TLS_UNSAFE_FILE')
        if private:
            require(info.st_uid == os.geteuid() and info.st_mode & 0o077 == 0, 'TLS_PRIVATE_FILE_REQUIRED')
        return os.read(fd, maximum + 1)
    finally:
        os.close(fd)


def create_once(path, data, mode=0o600):
    if path.exists() or path.is_symlink():
        require(read_file(path, private=True) == data, 'TLS_IMMUTABLE_FILE_CHANGED')
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as handle:
            handle.write(data); handle.flush(); os.fsync(fd)
    finally:
        os.close(fd)
    sync_directory(path.parent)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def properties(raw):
    """Conservative native Java Properties subset; preserve bytes, reject ambiguous escaping."""
    require(len(raw) <= 65536 and b'\x00' not in raw, 'TLS_CONFIG_SIZE_OR_NUL')
    result = {}
    for line in raw.decode('latin1').splitlines():
        value = line.lstrip(' \t\f')
        if not value or value.startswith(('#', '!')): continue
        require('\\' not in value, 'TLS_ESCAPED_PROPERTIES_REQUIRE_REVIEW')
        match = re.fullmatch(r'([A-Za-z0-9_.-]+)(?:\s*[:=]\s*|\s+)(.*)', value)
        require(match is not None, 'TLS_PROPERTIES_FORMAT_REQUIRES_REVIEW')
        result[match[1]] = match[2].strip()
    return result


def config_candidate(original, password, keystore=KEYSTORE):
    require(re.fullmatch(r'[0-9a-f]{64}', password) is not None, 'TLS_PASSWORD_SHAPE')
    require(str(keystore) == str(KEYSTORE), 'TLS_KEYSTORE_SCOPE')
    parsed = properties(original)
    require(parsed.get('password.encryption.type', 'none') in ('none', 'file', 'env'), 'TLS_INTERACTIVE_ENCRYPTION_REQUIRES_REVIEW')
    require(parsed.get('http.enable', 'true').lower() == 'true' and parsed.get('http.port', '8080') == '8080', 'TLS_HTTP_BASELINE_CHANGED')
    require(parsed.get('https.enable', 'false').lower() == 'false', 'TLS_EXISTING_HTTPS_UNOWNED')
    require(parsed.get('context.path', '/client') == '/client' and parsed.get('bind.interface', '') in ('', '0.0.0.0', TARGET), 'TLS_SERVER_BINDING_CHANGED')
    suffix = ('\n# LayerSentry owned native DC HTTPS; original bytes retained above.\n'
              'https.enable=true\nhttps.port=8443\nhttps.keystore=' + str(keystore) +
              '\nhttps.keystore.password=' + password + '\n').encode('ascii')
    return original + suffix


def pem_certificate(value):
    require(isinstance(value, str) and len(value) <= 16384 and value.count('-----BEGIN CERTIFICATE-----') == 1
            and value.count('-----END CERTIFICATE-----') == 1 and 'PRIVATE KEY' not in value,
            'TLS_SINGLE_PUBLIC_CERTIFICATE_REQUIRED')
    return value.encode('ascii')


def cert_der(pem): return run(['openssl', 'x509', '-outform', 'DER'], pem)


def ca_read(api):
    response = api('listCaCertificate', provider='root')
    obj = response.get('cacertificates')
    require(isinstance(obj, dict) and not obj.get('privatekey'), 'TLS_NATIVE_CA_RESPONSE_REQUIRED')
    pem = pem_certificate(obj.get('certificate'))
    return pem, sha(cert_der(pem))


def observe_guest_identity():
    # Public observation only: never treat Hyper-V VMId as a BIOS UUID.
    local_dc_binding()
    value = read_file(Path('/sys/devices/virtual/dmi/id/product_uuid')).decode('ascii').strip().lower()
    require(re.fullmatch('[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', value) is not None,
            'TLS_GUEST_UUID_SHAPE')
    return {'status': 'PARTIAL', 'guestProductUuid': value, 'mutationPerformed': False,
            'identityBindingEstablished': False}


def require_guest_bios(value):
    require(value == BIOS_UUID, 'TLS_DC_BIOS_UUID_MISMATCH')


def native_identity(api):
    local_dc_binding()
    require_guest_bios(read_file(Path('/sys/devices/virtual/dmi/id/product_uuid')).decode().strip().lower())
    links = json.loads(run(['ip', '-j', 'link', 'show', 'eth0']))
    require(isinstance(links, list) and len(links) == 1 and links[0].get('address', '').lower() == '00:15:5d:00:39:0a'
            and links[0].get('master') == 'cloudbr0', 'TLS_MANAGEMENT_NIC_CHANGED')
    hostname = socket.getfqdn().lower()
    require(re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', hostname) and hostname not in ('localhost', 'localhost.localdomain')
            and not hostname.endswith('.') and '..' not in hostname, 'TLS_HOSTNAME_REQUIRES_REVIEW')
    preflight(api)
    require(not rows(api, 'listVirtualMachines', 'virtualmachine', listall='true'), 'TLS_GUEST_VMS_PRESENT')
    require(not rows(api, 'listSystemVms', 'systemvm'), 'TLS_SYSTEM_VMS_PRESENT')
    return hostname


def plan(api, config=CONFIG, firewall_sources=()):
    sources = validate_sources(firewall_sources)
    hostname = native_identity(api)
    original = read_file(config)
    config_candidate(original, '0' * 64)
    info = config.stat()
    require(info.st_uid == 0 and not (info.st_mode & 0o022), 'TLS_CONFIG_OWNERSHIP_UNSAFE')
    require(not KEYSTORE.exists() and not KEYSTORE.is_symlink(), 'TLS_UNOWNED_KEYSTORE_EXISTS')
    ca, fingerprint = ca_read(api)
    return {'schema': 1, 'target': TARGET, 'vmId': VM_ID, 'biosUuid': BIOS_UUID, 'identityEvidence': dict(IDENTITY_EVIDENCE), 'hostname': hostname,
            'caSha256': fingerprint, 'caCertificate': ca.decode('ascii'), 'firewallSources': sources, 'serverPropertiesSha256': sha(original),
            'originalMetadata': {'uid': info.st_uid, 'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)},
            'httpPort': 8080, 'httpsPort': 8443, 'caProvider': 'root', 'durationDays': 30,
            'zoneEnabled': False, 'guestVmCount': 0, 'systemVmCount': 0, 'productionCertified': False}


def validate_plan(value):
    require(isinstance(value, dict) and value.get('schema') == 1 and value.get('target') == TARGET
            and value.get('vmId') == VM_ID and value.get('biosUuid') == BIOS_UUID and value.get('identityEvidence') == IDENTITY_EVIDENCE and value.get('httpPort') == 8080 and value.get('httpsPort') == 8443
            and value.get('caProvider') == 'root' and value.get('durationDays') == 30
            and value.get('zoneEnabled') is False and value.get('guestVmCount') == 0
            and value.get('systemVmCount') == 0 and value.get('productionCertified') is False, 'TLS_PLAN_SCOPE')
    require(value.get('firewallSources') == validate_sources(value.get('firewallSources', [])), 'TLS_FIREWALL_PLAN_CHANGED')
    require(sha(cert_der(pem_certificate(value.get('caCertificate')))) == value['caSha256'], 'TLS_PLAN_CA_BINDING')
    require(all(re.fullmatch('[0-9a-f]{64}', value.get(k, '')) for k in ('caSha256', 'serverPropertiesSha256')), 'TLS_PLAN_FINGERPRINTS_REQUIRED')
    require(re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?', value.get('hostname', '')) is not None
            and value['hostname'] not in ('localhost', 'localhost.localdomain') and '..' not in value['hostname'], 'TLS_PLAN_HOSTNAME')


def verify_key_csr(directory, hostname):
    key, csr = directory / 'server.key', directory / 'server.csr'
    read_file(key, private=True); read_file(csr, private=True)
    run(['openssl', 'req', '-in', str(csr), '-verify', '-noout'])
    a = run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'])
    public = run(['openssl', 'req', '-in', str(csr), '-pubkey', '-noout'])
    b = run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], public)
    require(a == b, 'TLS_CSR_PRIVATE_KEY_MISMATCH')
    details = run(['openssl', 'req', '-in', str(csr), '-noout', '-text']).decode()
    require('DNS:' + hostname in details and 'IP Address:' + TARGET in details, 'TLS_CSR_SAN_MISMATCH')
    return {'csrSha256': sha(read_file(csr, private=True)), 'publicKeySha256': sha(a)}


def key_prepare(journal, expected):
    directory = journal.directory
    operation = journal.data['operations'].get('key')
    if operation is None:
        require(not any((directory / n).exists() for n in ('server.key', 'server.csr', 'keystore.password')), 'TLS_UNJOURNALED_KEY_MATERIAL')
        journal.data['operations']['key'] = {'state': 'SUBMITTING'}; journal.save()
        create_once(directory / 'keystore.password', secrets.token_hex(32).encode())
        run(['openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-keyout', str(directory / 'server.key'),
             '-out', str(directory / 'server.csr'), '-subj', '/CN=' + expected['hostname'],
             '-addext', 'subjectAltName=DNS:' + expected['hostname'] + ',IP:' + TARGET])
        for name in ('server.key', 'server.csr'):
            os.chmod(directory / name, 0o600)
            fd = os.open(directory / name, os.O_RDONLY | os.O_NOFOLLOW)
            try: os.fsync(fd)
            finally: os.close(fd)
        sync_directory(directory)
    # Partial key creation is never replaced with a new key on resume.
    observed = verify_key_csr(directory, expected['hostname'])
    observed['passwordSha256'] = sha(read_file(directory / 'keystore.password', private=True))
    require(re.fullmatch(b'[0-9a-f]{64}', read_file(directory / 'keystore.password', private=True)), 'TLS_PASSWORD_FILE_CHANGED')
    if operation and operation.get('state') == 'RECONCILED':
        require(all(operation.get(k) == v for k, v in observed.items()), 'TLS_KEY_MATERIAL_CHANGED')
    journal.data['operations']['key'] = {'state': 'RECONCILED', **observed}; journal.save()
    return observed


def issue_observe(api, journal, expected, key):
    operations = journal.data['operations']
    spec = {'csrSha256': key['csrSha256'], 'caSha256': expected['caSha256'], 'hostname': expected['hostname'], 'ip': TARGET, 'duration': 30, 'provider': 'root'}
    operation = operations.get('issue')
    if operation is None:
        operation = {'state': 'SUBMITTING', 'specification': spec}
        operations['issue'] = operation; journal.save()
        try:
            response = api('issueCertificate', csr=read_file(journal.directory / 'server.csr', private=True).decode('ascii'),
                           domain=expected['hostname'], ipaddress=TARGET, duration=30, provider='root')
            operation['jobId'] = identifier(response.get('jobid'))
            operation['state'] = 'SUBMITTED'; journal.save()
        except Exception:
            operation['state'] = 'SUBMISSION_UNCERTAIN'; journal.save()
            raise GateError('TLS_CERTIFICATE_ISSUANCE_UNCERTAIN_NO_REPLAY') from None
    require(operation.get('specification') == spec, 'TLS_ISSUANCE_BINDING_CHANGED')
    require(operation.get('jobId'), 'TLS_CERTIFICATE_ISSUANCE_UNCERTAIN_NO_REPLAY')
    if operation['state'] == 'RECONCILED':
        return True
    response = api('queryAsyncJobResult', jobid=identifier(operation['jobId']))
    require(type(response.get('jobstatus')) is int and response['jobstatus'] in (0, 1, 2), 'TLS_INVALID_ASYNC_STATUS')
    if response['jobstatus'] == 0: return False
    require(response['jobstatus'] == 1, 'TLS_ISSUANCE_FAILED_NO_REPLAY')
    cert = response.get('jobresult', {}).get('certificates')
    require(isinstance(cert, dict) and not cert.get('privatekey'), 'TLS_CSR_RESPONSE_MUST_NOT_CONTAIN_PRIVATE_KEY')
    pem = pem_certificate(cert.get('certificate'))
    ca = pem_certificate(cert.get('cacertificates'))
    require(sha(cert_der(ca)) == expected['caSha256'], 'TLS_ISSUED_CA_CHANGED')
    create_once(journal.directory / 'server.crt', pem)
    operation['certificateSha256'] = sha(cert_der(pem)); operation['state'] = 'RECONCILED'; journal.save()
    return True


def verify_certificate(directory, expected):
    ca, cert, key = directory / 'original-ca.pem', directory / 'server.crt', directory / 'server.key'
    require(sha(cert_der(read_file(ca, private=True))) == expected['caSha256'], 'TLS_ORIGINAL_CA_CHANGED')
    run(['openssl', 'verify', '-CAfile', str(ca), '-no-CApath', '-no-CAstore', '-check_ss_sig', str(ca)])
    run(['openssl', 'verify', '-CAfile', str(ca), '-no-CApath', '-no-CAstore', '-purpose', 'sslserver', '-verify_ip', TARGET, str(cert)])
    run(['openssl', 'verify', '-CAfile', str(ca), '-no-CApath', '-no-CAstore', '-purpose', 'sslserver', '-verify_hostname', expected['hostname'], str(cert)])
    san = run(['openssl', 'x509', '-in', str(cert), '-noout', '-ext', 'subjectAltName']).decode().splitlines()
    require(len(san) == 2 and set(v.strip() for v in san[1].split(',')) == {'DNS:' + expected['hostname'], 'IP Address:' + TARGET}, 'TLS_CERTIFICATE_SAN_MISMATCH')
    public = run(['openssl', 'x509', '-in', str(cert), '-pubkey', '-noout'])
    a = run(['openssl', 'pkey', '-pubin', '-outform', 'DER'], public)
    b = run(['openssl', 'pkey', '-in', str(key), '-pubout', '-outform', 'DER'])
    require(a == b, 'TLS_CERTIFICATE_PRIVATE_KEY_MISMATCH')
    return {'certificateSha256': sha(cert_der(read_file(cert, private=True))), 'publicKeySha256': sha(a)}


def keystore_prepare(journal, expected):
    directory = journal.directory
    verified = verify_certificate(directory, expected)
    require(verified['certificateSha256'] == journal.data['operations'].get('issue', {}).get('certificateSha256'), 'TLS_ISSUED_CERTIFICATE_CHANGED')
    operation = journal.data['operations'].get('keystore')
    jks, p12, password = directory / 'server.jks', directory / 'server.p12', directory / 'keystore.password'
    if operation is None:
        require(not jks.exists() and not p12.exists(), 'TLS_UNJOURNALED_KEYSTORE')
        journal.data['operations']['keystore'] = {'state': 'SUBMITTING', **verified}; journal.save()
        run(['openssl', 'pkcs12', '-export', '-inkey', str(directory / 'server.key'), '-in', str(directory / 'server.crt'),
             '-certfile', str(directory / 'original-ca.pem'), '-name', ALIAS, '-out', str(p12), '-passout', 'file:' + str(password)])
        os.chmod(p12, 0o600)
        run(['keytool', '-importkeystore', '-srckeystore', str(p12), '-srcstoretype', 'PKCS12', '-srcstorepass:file', str(password),
             '-destkeystore', str(jks), '-deststoretype', 'JKS', '-deststorepass:file', str(password), '-destkeypass:file', str(password), '-noprompt'])
        os.chmod(jks, 0o600)
        fd = os.open(jks, os.O_RDONLY | os.O_NOFOLLOW)
        try: os.fsync(fd)
        finally: os.close(fd)
        sync_directory(directory)
    elif operation.get('state') == 'RECONCILED':
        require(all(operation.get(k) == v for k, v in verified.items()), 'TLS_KEYSTORE_CERTIFICATE_CHANGED')
    contents = read_file(jks, private=True)
    require(contents[:4] == bytes.fromhex('feedfeed'), 'TLS_NATIVE_JKS_REQUIRED')
    if operation and operation.get('state') == 'RECONCILED':
        require(sha(contents) == operation['keystoreSha256'], 'TLS_KEYSTORE_BYTES_CHANGED')
    listing = run(['keytool', '-list', '-v', '-keystore', str(jks), '-storepass:file', str(password)]).decode()
    require('Your keystore contains 1 entry' in listing and 'Entry type: PrivateKeyEntry' in listing and 'Certificate chain length: 2' in listing, 'TLS_KEYSTORE_ENTRY_SHAPE')
    exported = run(['keytool', '-exportcert', '-rfc', '-alias', ALIAS, '-keystore', str(jks), '-storepass:file', str(password)])
    require(sha(cert_der(exported)) == verified['certificateSha256'], 'TLS_KEYSTORE_LEAF_MISMATCH')
    candidate = config_candidate(read_file(directory / 'original-server.properties', private=True), read_file(password, private=True).decode())
    create_once(directory / 'server.properties.candidate', candidate)
    journal.data['operations']['keystore'] = {'state': 'RECONCILED', **verified, 'keystoreSha256': sha(read_file(jks, private=True)), 'candidateSha256': sha(candidate)}
    journal.save()
    return journal.data['operations']['keystore']


def prepare_tools():
    # Check the exact execution PATH before an irreversible native issuance.
    for command in ('openssl', 'keytool'):
        require(shutil.which(command, path='/usr/sbin:/usr/bin:/sbin:/bin') is not None, 'TLS_PREPARE_TOOL_MISSING')
    require(re.match(rb'OpenSSL 3\.', run(['openssl', 'version'])) is not None, 'TLS_OPENSSL_VERSION_UNSUPPORTED')
    require(b'default' in run(['openssl', 'list', '-providers']), 'TLS_OPENSSL_PROVIDER_MISSING')
    run(['keytool', '-J-version'])
    run(['keytool', '-importkeystore', '-help'])
    run(['keytool', '-list', '-help'])


def prepare(api, journal, expected):
    validate_plan(expected)
    prepare_tools()
    require(native_identity(api) == expected['hostname'], 'TLS_HOSTNAME_CHANGED')
    ca, fingerprint = ca_read(api)
    require(fingerprint == expected['caSha256'], 'TLS_ROOT_CA_PLAN_CHANGED')
    original = read_file(CONFIG)
    require(sha(original) == expected['serverPropertiesSha256'], 'TLS_SERVER_CONFIG_PLAN_CHANGED')
    info = CONFIG.stat()
    require({'uid': info.st_uid, 'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)} == expected['originalMetadata'], 'TLS_ORIGINAL_CONFIG_METADATA_CHANGED')
    create_once(journal.directory / 'original-server.properties', original)
    create_once(journal.directory / 'original-ca.pem', ca)
    run(['openssl', 'verify', '-CAfile', str(journal.directory / 'original-ca.pem'), '-no-CApath', '-no-CAstore', '-check_ss_sig', str(journal.directory / 'original-ca.pem')])
    key = key_prepare(journal, expected)
    if not issue_observe(api, journal, expected, key):
        return {'status': 'PENDING', 'phase': 'Prepare', 'certificateJobPending': True, 'productionCertified': False}
    receipt = keystore_prepare(journal, expected)
    return {'status': 'PARTIAL', 'phase': 'Prepare', 'target': TARGET, 'planSha256': digest(expected),
            'certificateSha256': receipt['certificateSha256'], 'caSha256': fingerprint,
            'configurationInstalled': False, 'serviceRestarted': False, 'firewallChanged': False, 'productionCertified': False}


def validate_sources(values):
    require(isinstance(values, (list, tuple)) and len(values) <= 8, 'TLS_FIREWALL_SOURCE_LIMIT')
    result = []
    for value in values:
        require(isinstance(value, str), 'TLS_FIREWALL_SOURCE_INVALID')
        try: network = ipaddress.ip_network(value, strict=True)
        except ValueError: raise GateError('TLS_FIREWALL_SOURCE_INVALID') from None
        require(network.version == 4 and network.prefixlen == 32 and network.network_address in ipaddress.ip_network('10.10.10.0/24')
                and str(network) == value and value not in result, 'TLS_FIREWALL_SOURCE_INVALID')
        result.append(value)
    return sorted(result)


def install(api, journal, expected):
    validate_plan(expected)
    require(native_identity(api) == expected['hostname'], 'TLS_HOSTNAME_CHANGED')
    require(ca_read(api)[1] == expected['caSha256'], 'TLS_ROOT_CA_PLAN_CHANGED')
    key = journal.data['operations'].get('keystore', {})
    require(key.get('state') == 'RECONCILED', 'TLS_PREPARATION_REQUIRED')
    require(verify_certificate(journal.directory, expected)['certificateSha256'] == key['certificateSha256'], 'TLS_PREPARED_CERTIFICATE_CHANGED')
    original = read_file(journal.directory / 'original-server.properties', private=True)
    candidate = read_file(journal.directory / 'server.properties.candidate', private=True)
    store = read_file(journal.directory / 'server.jks', private=True)
    require(sha(original) == expected['serverPropertiesSha256'] and sha(candidate) == key['candidateSha256']
            and sha(store) == key['keystoreSha256'], 'TLS_PREPARED_ARTIFACT_CHANGED')
    owner = grp.getgrnam('cloud').gr_gid
    for name, destination, data in [('install-keystore', KEYSTORE, store), ('install-config', CONFIG, candidate)]:
        prior = journal.data['operations'].get(name)
        spec = {'path': str(destination), 'sha256': sha(data), 'uid': 0, 'gid': owner, 'mode': 0o640}
        if prior: require(prior.get('specification') == spec, 'TLS_INSTALL_BINDING_CHANGED')
        exists = destination.exists() or destination.is_symlink()
        if exists and read_file(destination) == data:
            require(prior is not None, 'TLS_UNJOURNALED_INSTALL')
            info = destination.stat()
            require((info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (0, owner, 0o640), 'TLS_INSTALLED_PERMISSIONS_CHANGED')
            run(['restorecon', str(destination)]); run(['matchpathcon', '-V', str(destination)])
            prior['state'] = 'RECONCILED'; journal.save(); continue
        require(prior is None, 'TLS_INSTALL_UNCERTAIN_NO_REPLAY')
        if name == 'install-config':
            require(exists and read_file(destination) == original, 'TLS_SERVER_CONFIG_PLAN_CHANGED')
            info = destination.stat()
            require({'uid': info.st_uid, 'gid': info.st_gid, 'mode': stat.S_IMODE(info.st_mode)} == expected['originalMetadata'], 'TLS_ORIGINAL_CONFIG_METADATA_CHANGED')
        else: require(not exists, 'TLS_UNOWNED_KEYSTORE_EXISTS')
        temporary = destination.with_name(destination.name + '.layersentry-pending')
        require(not temporary.exists() and not temporary.is_symlink(), 'TLS_STAGING_PATH_EXISTS')
        journal.data['operations'][name] = {'state': 'SUBMITTING', 'specification': spec}; journal.save()
        create_once(temporary, data)
        os.chown(temporary, 0, owner); os.chmod(temporary, 0o640)
        fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW)
        try: os.fsync(fd)
        finally: os.close(fd)
        os.replace(temporary, destination); sync_directory(destination.parent)
        run(['restorecon', str(destination)]); run(['matchpathcon', '-V', str(destination)])
        journal.data['operations'][name]['state'] = 'RECONCILED'; journal.save()
    return {'status': 'PARTIAL', 'phase': 'Install', 'target': TARGET, 'httpPreserved': True,
            'serviceRestarted': False, 'firewallChanged': False, 'productionCertified': False}


def https_observed(directory, expected, api=None):
    try:
        context = ssl.create_default_context(cadata=read_file(directory / 'original-ca.pem', private=True).decode('ascii'))
        with socket.create_connection(('127.0.0.1', 8443), timeout=5) as connection:
            with context.wrap_socket(connection, server_hostname=expected['hostname']) as tls:
                require(sha(tls.getpeercert(binary_form=True)) == sha(cert_der(read_file(directory / 'server.crt', private=True))), 'TLS_SERVED_CERTIFICATE_CHANGED')
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open('http://127.0.0.1:8080/client/', timeout=10) as response:
            require(response.status == 200 and response.url == 'http://127.0.0.1:8080/client/', 'TLS_HTTP_LISTENER_CHANGED')
        if api is not None:
            secure_api = Client('https://10.10.10.14:8443/client/api', api.key, api.secret)
            secure_api.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context))
            require(ca_read(secure_api)[1] == expected['caSha256'], 'TLS_AUTHENTICATED_API_CA_CHANGED')
        return True
    except (OSError, ssl.SSLError): return False


def activate(api, journal, expected):
    validate_plan(expected)
    require(native_identity(api) == expected['hostname'], 'TLS_HOSTNAME_CHANGED')
    require(ca_read(api)[1] == expected['caSha256'], 'TLS_ROOT_CA_PLAN_CHANGED')
    for key, destination in [('install-config', CONFIG), ('install-keystore', KEYSTORE)]:
        state = journal.data['operations'].get(key, {})
        require(state.get('state') == 'RECONCILED' and sha(read_file(destination)) == state['specification']['sha256'], 'TLS_INSTALLED_ARTIFACT_CHANGED')
    operation = journal.data['operations'].get('restart')
    if https_observed(journal.directory, expected, api):
        require(operation is not None, 'TLS_UNJOURNALED_RESTART')
        operation['state'] = 'RECONCILED'; journal.save()
    else:
        require(operation is None, 'TLS_RESTART_UNCERTAIN_NO_REPLAY')
        journal.data['operations']['restart'] = {'state': 'SUBMITTING'}; journal.save()
        run(['systemctl', 'restart', 'cloudstack-management'])
        # Root may re-invoke Activate to observe startup; restart is never replayed.
        if not https_observed(journal.directory, expected, api):
            return {'status': 'PENDING', 'phase': 'Activate', 'target': TARGET, 'automaticReplay': False, 'productionCertified': False}
        journal.data['operations']['restart']['state'] = 'RECONCILED'; journal.save()
    return {'status': 'PARTIAL', 'phase': 'Activate', 'target': TARGET, 'httpsVerified': True, 'authenticatedApiTlsVerified': True,
            'httpPreserved': True, 'firewallChanged': False, 'productionCertified': False}


def firewall(api, journal, expected):
    validate_plan(expected)
    require(native_identity(api) == expected['hostname'], 'TLS_HOSTNAME_CHANGED')
    require(ca_read(api)[1] == expected['caSha256'], 'TLS_ROOT_CA_PLAN_CHANGED')
    require(journal.data['operations'].get('restart', {}).get('state') == 'RECONCILED'
            and https_observed(journal.directory, expected, api), 'TLS_LOCAL_HTTPS_NOT_VERIFIED')
    sources = expected['firewallSources']; require(sources, 'TLS_EXACT_FIREWALL_SOURCES_REQUIRED')
    zone = run(['firewall-cmd', '--get-zone-of-interface=cloudbr0']).decode().strip()
    require(re.fullmatch('[A-Za-z0-9_-]{1,64}', zone) is not None, 'TLS_FIREWALL_ZONE_INVALID')
    for source in sources:
        rule = 'rule family="ipv4" source address="' + source + '" port port="8443" protocol="tcp" accept'
        for permanent in (True, False):
            key = 'firewall-' + source.replace('/', '-') + ('-permanent' if permanent else '-runtime')
            spec = {'zone': zone, 'rule': rule, 'permanent': permanent}
            base = ['firewall-cmd', '--zone=' + zone] + (['--permanent'] if permanent else [])
            existing = run(base + ['--list-rich-rules']).decode().splitlines()
            prior = journal.data['operations'].get(key)
            if prior: require(prior.get('specification') == spec, 'TLS_FIREWALL_BINDING_CHANGED')
            if rule in existing:
                require(prior is not None, 'TLS_UNOWNED_FIREWALL_RULE')
                prior['state'] = 'RECONCILED'; journal.save(); continue
            require(prior is None, 'TLS_FIREWALL_UNCERTAIN_NO_REPLAY')
            journal.data['operations'][key] = {'state': 'SUBMITTING', 'specification': spec}; journal.save()
            run(base + ['--add-rich-rule=' + rule])
            require(rule in run(base + ['--list-rich-rules']).decode().splitlines(), 'TLS_FIREWALL_NOT_OBSERVED')
            journal.data['operations'][key]['state'] = 'RECONCILED'; journal.save()
    return {'status': 'PARTIAL', 'phase': 'Firewall', 'target': TARGET, 'sourceRules': sources,
            'externalHttpsVerification': 'NOT_TESTED', 'productionCertified': False}
