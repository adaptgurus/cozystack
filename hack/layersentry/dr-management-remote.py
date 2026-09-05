#!/usr/bin/env python3
"""Single DR target adapter. Never publish subprocess output or secret input."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

INPUTS = Path('/run/layersentry-dr-management-inputs')
RECEIPTS = Path('/var/lib/layersentry/dr-deployment')
JOURNAL = Path('/var/lib/layersentry/installation/journal.json')
STAGES = ('checkpoint', 'packages', 'database', 'management', 'backups')
SERVICES = ('mysqld', 'cloudstack-management', 'firewalld', 'layersentry-db-backup.timer')
CONFIG_KEYS = {'schema_version', 'mode', 'management_package', 'java_package',
               'mysql_client_package', 'mysql_server_package', 'mysql_series',
               'db_host', 'hostname', 'management_ip', 'initialize_database',
               'backup_retention', 'management_nodes', 'backup_db_user',
               'ui_cidr', 'agent_cidr', 'firewall_zone'}


def require(condition):
    if not condition:
        raise ValueError('deployment input or prerequisite rejected')


def validate_request(request, action):
    require(set(request) == {'request_id', 'source_sha', 'configuration', 'repositories'})
    require(isinstance(request['request_id'], str)
            and re.fullmatch('[a-z0-9-]{1,64}', request['request_id']))
    require(isinstance(request['source_sha'], str)
            and re.fullmatch('[0-9a-f]{40}', request['source_sha']))
    require(set(action) == {'request', 'phase', 'authorization'})
    require(action['phase'] in ('Preflight', 'Apply', 'Status'))
    require(action['authorization'] == (request['request_id'] + ':Apply'
                                       if action['phase'] == 'Apply' else ''))
    config = request['configuration']
    require(isinstance(config, dict) and set(config) <= CONFIG_KEYS)
    require(config.get('management_ip') == '10.10.10.20'
            and config.get('mode') == 'combined' and config.get('db_host') == 'localhost'
            and config.get('initialize_database') is True)
    repositories = request['repositories']
    require(isinstance(repositories, dict) and 1 <= len(repositories) <= 8)
    for name, content in repositories.items():
        require(re.fullmatch('[a-z0-9-]+\\.repo', name)
                and isinstance(content, str) and 0 < len(content) < 32768)
    return config


def fingerprint(request, certificate):
    return hashlib.sha256(json.dumps(request, sort_keys=True).encode() + certificate).hexdigest()


def validate_receipt(receipt, digest, now):
    require(receipt.get('fingerprint') == digest
            and 0 <= now - receipt.get('passed_at', 0) <= 86400)


def journal_stages():
    if not JOURNAL.exists():
        return {}
    parsed = json.loads(JOURNAL.read_text()).get('stages', {})
    return {key: value for key, value in parsed.items()
            if key in STAGES and value in ('applied', 'in_progress')}


def probe(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None


def status(result):
    states = {}
    for service in SERVICES:
        check = probe(['systemctl', 'is-active', service])
        states[service] = 'active' if check and check.returncode == 0 else 'not_active'
    result['services'] = states
    check = probe(['getenforce'])
    result['selinux'] = 'Enforcing' if check and check.stdout.strip() == 'Enforcing' else 'not_enforcing'
    check = probe(['curl', '--noproxy', '*', '--max-time', '10', '-s', '-o', '/dev/null',
                   '-w', '%{http_code}', 'http://127.0.0.1:8080/client/'])
    result['ui_http_status'] = (int(check.stdout) if check and check.returncode == 0
                                and re.fullmatch('[1-5][0-9]{2}', check.stdout) else 0)
    result['journal_stages'] = journal_stages()


def execute(bundle, result):
    import fcntl
    require(os.geteuid() == 0)
    require(re.fullmatch('/run/layersentry-dr-deploy-[0-9]+-[0-9]+/bundle', str(bundle)))
    require(bundle.is_dir() and not bundle.is_symlink())
    request = json.loads((bundle / 'request.json').read_text())
    action = json.loads((bundle / 'action.json').read_text())
    config = dict(validate_request(request, action))
    result.update(request_id=request['request_id'], source_sha=request['source_sha'], phase=action['phase'])
    result['failure_stage'] = 'lock'
    with open('/run/lock/layersentry-dr-deployment.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result['failure_stage'] = 'runtime_inputs'
        # Stable paths keep the installer's journal fingerprint stable between runs.
        # An existing directory indicates interrupted execution and requires inspection.
        INPUTS.mkdir(mode=0o700)
        try:
            for name, content in sorted(request['repositories'].items()):
                (INPUTS / name).write_text(content)
            certificate = (bundle / 'recipient.pem').read_bytes()
            (INPUTS / 'recipient.pem').write_bytes(certificate)
            config['repo_files'] = [str(INPUTS / name) for name in sorted(request['repositories'])]
            config['backup_recipient_certificate'] = str(INPUTS / 'recipient.pem')
            (INPUTS / 'config.json').write_text(json.dumps(config))
            shutil.copyfile(bundle / 'secrets.json', INPUTS / 'secrets.json')
            for path in INPUTS.iterdir():
                path.chmod(0o600)
            digest = fingerprint(request, certificate)
            command = [sys.executable, str(bundle / 'install-rocky9.py'),
                       '--config', str(INPUTS / 'config.json'), '--secrets', str(INPUTS / 'secrets.json')]
            if action['phase'] == 'Status':
                result['failure_stage'] = 'status'
                status(result)
                result['outcome'] = 'passed'
                return
            result['failure_stage'] = 'preflight'
            check = subprocess.run(command + ['--action', 'preflight'], capture_output=True, timeout=180)
            result['installer_exit_code'] = check.returncode
            require(check.returncode == 0)
            receipt = RECEIPTS / (request['request_id'] + '.json')
            if action['phase'] == 'Preflight':
                RECEIPTS.mkdir(mode=0o700, parents=True, exist_ok=True)
                require(not receipt.is_symlink())
                receipt.write_text(json.dumps({'fingerprint': digest, 'passed_at': int(time.time())}))
                receipt.chmod(0o600)
            else:
                result['failure_stage'] = 'preflight_receipt'
                require(receipt.is_file() and not receipt.is_symlink())
                passed = json.loads(receipt.read_text())
                validate_receipt(passed, digest, time.time())
                result['failure_stage'] = 'apply'
                check = subprocess.run(command + ['--action', 'apply'], capture_output=True, timeout=6600)
                result['installer_exit_code'] = check.returncode
                require(check.returncode == 0)
            result['failure_stage'] = 'status'
            status(result)
            if action['phase'] == 'Apply':
                deadline = time.monotonic() + 180
                while result['ui_http_status'] not in (200, 301, 302, 303, 307, 308) and time.monotonic() < deadline:
                    time.sleep(5)
                    status(result)
                require(all(state == 'active' for state in result['services'].values())
                        and result['selinux'] == 'Enforcing'
                        and result['ui_http_status'] in (200, 301, 302, 303, 307, 308))
            result['outcome'] = 'passed'
        finally:
            shutil.rmtree(INPUTS)


def main():
    os.umask(0o077)
    result = {'schema_version': 1, 'outcome': 'failed', 'failure_stage': 'validation',
              'acceptance': 'API authentication, browser, restart and isolated restore acceptance remain required',
              'cleanup_complete': False}
    bundle = Path(sys.argv[1])
    try:
        execute(bundle, result)
        result['failure_stage'] = None
    except Exception:
        # Tool output, exception messages, config and credentials never enter evidence.
        try:
            result['journal_stages'] = journal_stages()
        except Exception:
            pass
    finally:
        if re.fullmatch('/run/layersentry-dr-deploy-[0-9]+-[0-9]+/bundle', str(bundle)):
            for name in ('secrets.json', 'recipient.pem'):
                try:
                    (bundle / name).unlink(missing_ok=True)
                except OSError:
                    pass
            result['cleanup_complete'] = not (bundle / 'secrets.json').exists() and not INPUTS.exists()
    if not result['cleanup_complete']:
        result['outcome'] = 'failed'
    print(json.dumps(result, sort_keys=True))
    return 0 if result['outcome'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
