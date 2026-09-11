#!/usr/bin/env python3
"""Owner-scoped P1 source recovery. No guest operations or supervisor edits.

Fetch existing remotes, preserve exact committed sources under safety refs,
report the retained manifest and run an unchanged platform baseline in a new
worktree. Never replace existing refs or original working files.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import socket
import subprocess
import sys
import tempfile

RUN = 'd5db2181-14e4-4ab0-8464-493b643130b9'
SUBJECT = '86b0fe62098a959f74cdd42af3d08b2519dbbfa2659416b7f9b948c98c1761e4'
STATE = Path('/home/opc/.local/state/layersentry-runner')
SAFETY = 'safety/p1-rke2-preprod-20260911'
BRANCH = 'layersentry/p1-rke2-provisioning'
EXPECTED = {
    'adaptgurus/one': ('6746b9e22d63a0d7ef64154fd22a8161087e7b68', '0fea39ec3bca95aed9d126adc9b1ce401cc819a3'),
    'adaptgurus/one-apps': ('e1bd9602c8bd0aea7839fe9e4a4356a11af4daad', 'cc93b4f4af763ba29bcbf64d22a1d09130ad94bd'),
    'adaptgurus/layersentry-platform': ('8b5fa534008c0a517fa924ddca3e8a52ab4e3dfc', 'de86df337cedd3177697fd6c7c0da568eb0819a5'),
}
ENV = dict(os.environ, GIT_TERMINAL_PROMPT='0')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def command(argv, cwd=None, seconds=90):
    p = subprocess.run(['timeout', '--signal=TERM', '--kill-after=10s', str(seconds) + 's', *argv],
                       cwd=cwd, env=ENV, capture_output=True, text=True, timeout=seconds + 15)
    # Never include Git stderr: credential helpers may include credentials.
    require(p.returncode == 0, 'Command failed: ' + argv[0] + ' exit=' + str(p.returncode))
    return p.stdout.strip()


def git(repo, *args):
    return command(['git', '-C', str(repo), *args])


def emit(label, value):
    print(label + '=' + json.dumps(value, sort_keys=True), flush=True)


def evidence(path):
    p = (STATE / path).resolve(strict=True)
    require(p.is_relative_to(STATE.resolve()), 'Evidence escaped state root')
    require(p.is_file() and p.stat().st_size < 16 * 1024 * 1024, 'Invalid evidence size')
    return p.read_bytes()


def safe_manifest(value, key=''):
    # Only hashes, identities, paths and primitive metadata may enter Actions logs.
    if isinstance(value, dict):
        return {k: safe_manifest(v, k) for k, v in value.items()
                if not re.search(r'(?i)content|credential|password|token|secret|authorization', k)}
    if isinstance(value, list):
        return [safe_manifest(v, key) for v in value]
    if isinstance(value, str):
        if re.fullmatch(r'[a-f0-9]{40,64}', value):
            return value
        if key in ('path', 'worktree', 'repository', 'repo', 'branch', 'status', 'mode', 'kind', 'type', 'capability', 'operation', 'base_branch'):
            return value[:600]
        return '<string>'
    return value


def main():
    os.umask(0o077)
    require(pwd.getpwuid(os.geteuid()).pw_name == 'opc', 'Wrong WSL user')
    require(socket.gethostname().split('.')[0].lower() == 'testser', 'Wrong WSL host')
    before = (STATE / 'state.json').read_bytes()
    run = json.loads(before)['capability_runs'][RUN]
    require(run['capability'] == 'P1-RKE2', 'Wrong capability')
    require(run['state'] == 'PUBLICATION_UNKNOWN', 'Reconcile changed run status first')
    require(set(run['selected']) == set(EXPECTED), 'Selected repositories changed')
    review_ref = run['final_review']
    raw_review = evidence(review_ref['path'])
    require(hashlib.sha256(raw_review).hexdigest() == review_ref['sha256'], 'Review integrity mismatch')
    review = json.loads(raw_review)
    require(review['decision'] == 'ACCEPT' and review['subject_sha256'] == SUBJECT, 'Wrong reviewed source')
    raw_snapshot = evidence('artifacts/' + RUN + '/verified-snapshot.json')
    snapshot = json.loads(raw_snapshot)
    emit('REVIEW_IDENTITY', {'source': SUBJECT, 'review_sha256': review_ref['sha256'], 'production_certified': False})
    emit('VERIFIED_SNAPSHOT', safe_manifest(snapshot))
    repos = {}
    for name, (head, base) in EXPECTED.items():
        repo = STATE / 'capabilities' / RUN / 'source' / name.split('/')[1]
        require(repo.resolve() == Path(run['selected'][name]['worktree']).resolve(), 'Worktree binding changed')
        require(git(repo, 'rev-parse', 'HEAD') == head, 'Unexpected HEAD: ' + name)
        require(git(repo, 'rev-parse', 'HEAD^') == base, 'Unexpected parent: ' + name)
        require(git(repo, 'branch', '--show-current') == BRANCH, 'Unexpected branch: ' + name)
        require(not git(repo, 'status', '--porcelain=v1', '--untracked-files=all'), 'Dirty source: ' + name)
        require(run['publication'][name]['commit'] == head, 'Publication source mismatch')
        url = 'https://github.com/' + name + '.git'
        require(git(repo, 'remote', 'get-url', 'origin') == url, 'Unexpected origin: ' + name)
        # Capture ref identity before and after fetch without resetting any local branch.
        git(repo, 'fetch', '--all', '--no-prune')
        require(git(repo, 'rev-parse', 'HEAD') == head, 'HEAD changed during fetch')
        task_ref = git(repo, 'ls-remote', '--heads', url, 'refs/heads/' + BRANCH)
        require(not task_ref or task_ref.split()[0] == head, 'Foreign remote task HEAD')
        safety_ref = git(repo, 'ls-remote', '--heads', url, 'refs/heads/' + SAFETY)
        require(not safety_ref or safety_ref.split()[0] == head, 'Existing safety ref differs')
        repos[name] = (repo, head, base, url, bool(safety_ref))
        emit('SOURCE_RECONCILED', {'repository': name, 'head': head, 'parent': base, 'task_remote_exists': bool(task_ref),
                                  'changes': git(repo, 'diff', '--name-status', base, head).splitlines()})
    # All targets were checked before the first backup push. This does not publish
    # a capability or alter its sealed publication state.
    for name, (repo, head, base, url, exists) in repos.items():
        require(git(repo, 'rev-parse', 'HEAD') == head and not git(repo, 'status', '--porcelain=v1'), 'Concurrent source change')
        if not exists:
            git(repo, 'push', '--porcelain', url, head + ':refs/heads/' + SAFETY)
        actual = git(repo, 'ls-remote', '--heads', url, 'refs/heads/' + SAFETY)
        require(actual.split()[0] == head, 'Backup not remotely confirmed')
        emit('SAFETY_REMOTE_CONFIRMED', {'repository': name, 'branch': SAFETY, 'head': head})
        files = git(repo, 'ls-tree', '-r', '--name-only', head).splitlines()
        emit('AGENT_FILES', {'repository': name, 'paths': [p for p in files if p.rsplit('/', 1)[-1].lower() in ('agents.md', 'agent.md')]})
        changed = git(repo, 'diff', '--name-only', base, head).splitlines()
        emit('SOURCE_FILE_HASHES', {'repository': name, 'files': [
            {'path': p, 'sha256': hashlib.sha256(subprocess.check_output(['git', '-C', str(repo), 'show', head + ':' + p])).hexdigest(),
             'entry': git(repo, 'ls-tree', head, '--', p)} for p in changed]})
    require((STATE / 'state.json').read_bytes() == before, 'Supervisor state changed concurrently')
    emit('SOURCE_RECOVERY_COMPLETE', {'original_worktrees_unchanged': True, 'supervisor_state_unchanged': True, 'guest_mutations': False})
    # Unchanged baseline, isolated from retained verified worktrees.
    destination = Path(tempfile.mkdtemp(prefix='layersentry-p1-hardening-baseline-', dir='/home/opc'))
    platform = repos['adaptgurus/layersentry-platform'][0]
    target = destination / 'layersentry-platform'
    git(platform, 'worktree', 'add', '--detach', str(target), EXPECTED['adaptgurus/layersentry-platform'][0])
    emit('BASELINE_WORKTREE', str(target))
    for argv, seconds in [(['go', 'version'], 30), (['go', 'test', '-race', '-count=1', '-coverprofile=' + str(destination / 'coverage.out'), './...'], 360),
                          (['go', 'vet', './...'], 90), (['go', 'build', './...'], 90)]:
        emit('BASELINE_COMMAND', argv)
        output = command(argv, cwd=target, seconds=seconds)
        print(output[-18000:], flush=True)
    require(not git(target, 'status', '--porcelain=v1'), 'Baseline mutated tracked or untracked source')
    emit('PLATFORM_BASELINE', {'result': 'PASS', 'head': EXPECTED['adaptgurus/layersentry-platform'][0], 'live_verified': False})


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('RECOVERY_BLOCKED=' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), flush=True)
        sys.exit(1)
