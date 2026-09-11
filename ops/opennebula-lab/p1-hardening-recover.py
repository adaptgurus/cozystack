#!/usr/bin/env python3
"""Recover exact P1 sources and run an isolated, unchanged baseline.

Only Git fetch, exact-SHA safety refs and an isolated test worktree are written.
No guest operation, source replacement or supervisor-state edit is permitted.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import stat
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


def emit(label, value):
    print(label + '=' + json.dumps(value, sort_keys=True), flush=True)


def command(argv, cwd=None, seconds=90):
    p = subprocess.run(['timeout', '--signal=TERM', '--kill-after=10s', str(seconds) + 's', *argv],
                       cwd=cwd, env=ENV, capture_output=True, text=True, timeout=seconds + 15)
    if p.returncode and argv[0] != 'git':
        # Diagnostics are bounded; never emit Git credential-helper output.
        text = (p.stdout + '\n' + p.stderr)[-16000:]
        print(re.sub(r'(?i)(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)', '[REDACTED]', text), flush=True)
    require(p.returncode == 0, 'Command failed: ' + argv[0] + ' exit=' + str(p.returncode))
    return p.stdout.strip()


def git(repo, *args):
    return command(['git', '-C', str(repo), *args])


def evidence(path):
    p = (STATE / path).resolve(strict=True)
    require(p.is_relative_to(STATE.resolve()), 'Evidence escaped state root')
    require(p.is_file() and p.stat().st_size < 16 * 1024 * 1024, 'Invalid evidence size')
    return p.read_bytes()


def find_go():
    candidates = []
    direct = shutil.which('go')
    if direct:
        candidates.append(Path(direct))
    roots = [Path('/tmp'), Path('/opt'), Path('/usr/local'), Path('/home/opc/sdk'),
             Path('/home/opc/.local'), Path('/home/opc/go/pkg/mod')]
    for root in roots:
        if not root.is_dir():
            continue
        for directory, dirs, files in os.walk(root, followlinks=False):
            relative = Path(directory).relative_to(root)
            dirs[:] = [d for d in dirs if len(relative.parts) < 5 and d not in
                       ('.git', '.ssh', '.kube', '.codex', 'node_modules', 'datastores', 'source', 'artifacts')]
            if Path(directory).name == 'bin' and 'go' in files:
                p = Path(directory) / 'go'
                if p not in candidates:
                    candidates.append(p)
    emit('GO_TOOLCHAIN_CANDIDATES', [str(p) for p in candidates])
    for candidate in candidates:
        version = command([str(candidate), 'version'], seconds=30)
        match = re.search(r'go1\.(\d+)', version)
        if match and int(match.group(1)) >= 24:
            emit('GO_TOOLCHAIN_SELECTED', {'path': str(candidate), 'version': version,
                                          'sha256': hashlib.sha256(candidate.read_bytes()).hexdigest()})
            return str(candidate)
    for name in ('0009-verify-rke2-build.record.json', '0010-verify-rke2-unit.record.json'):
        rec = json.loads(evidence('artifacts/' + RUN + '/' + name))
        process = rec.get('process', {})
        emit('BASELINE_RECEIPT_PROCESS_KEYS', {'file': name, 'keys': list(process)})
        for key in ('argv', 'command', 'cwd'):
            if key in process:
                emit('BASELINE_RECEIPT_COMMAND', {key: process[key]})
    raise RuntimeError('No existing Go >=1.24 toolchain found; no source changed')


def main():
    os.umask(0o077)
    require(pwd.getpwuid(os.geteuid()).pw_name == 'opc', 'Wrong WSL user')
    require(socket.gethostname().split('.')[0].lower() == 'testser', 'Wrong WSL host')
    before = (STATE / 'state.json').read_bytes()
    run = json.loads(before)['capability_runs'][RUN]
    require(run['capability'] == 'P1-RKE2' and run['state'] == 'PUBLICATION_UNKNOWN', 'Run changed')
    require(set(run['selected']) == set(EXPECTED), 'Selected repositories changed')
    review_ref = run['final_review']
    raw_review = evidence(review_ref['path'])
    require(hashlib.sha256(raw_review).hexdigest() == review_ref['sha256'], 'Review integrity mismatch')
    review = json.loads(raw_review)
    require(review['decision'] == 'ACCEPT' and review['subject_sha256'] == SUBJECT, 'Wrong reviewed source')
    snapshot = json.loads(evidence('artifacts/' + RUN + '/verified-snapshot.json'))
    require(set(snapshot) == set(EXPECTED), 'Snapshot repositories differ')
    canonical = hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    emit('SNAPSHOT_CANONICAL_DIGEST', canonical)
    # File-by-file and mode checks are also made before the first backup push.
    repos = {}
    count = 0
    for name, (head, base) in EXPECTED.items():
        repo = STATE / 'capabilities' / RUN / 'source' / name.split('/')[1]
        require(repo.resolve() == Path(run['selected'][name]['worktree']).resolve(), 'Worktree binding changed')
        require(git(repo, 'rev-parse', 'HEAD') == head, 'Unexpected HEAD: ' + name)
        require(git(repo, 'rev-parse', 'HEAD^') == base, 'Unexpected parent: ' + name)
        require(git(repo, 'branch', '--show-current') == BRANCH, 'Unexpected branch: ' + name)
        require(not git(repo, 'status', '--porcelain=v1', '--untracked-files=all'), 'Dirty source: ' + name)
        require(run['publication'][name]['commit'] == head, 'Publication source mismatch')
        require(snapshot[name]['base'] == base, 'Snapshot base changed')
        changed = git(repo, 'diff', '--name-only', base, head).splitlines()
        records = snapshot[name]['changes']
        require(sorted(changed) == sorted(r['path'] for r in records), 'Manifest path set differs')
        for record in records:
            p = repo / record['path']
            require(p.resolve().is_relative_to(repo.resolve()) and not p.is_symlink(), 'Unsafe source path')
            require(hashlib.sha256(p.read_bytes()).hexdigest() == record['sha256'], 'File hash differs: ' + record['path'])
            require(stat.S_IMODE(p.stat().st_mode) == record['mode'], 'File mode differs')
            count += 1
        url = 'https://github.com/' + name + '.git'
        require(git(repo, 'remote', 'get-url', 'origin') == url, 'Unexpected origin')
        git(repo, 'fetch', '--all', '--no-prune')
        require(git(repo, 'rev-parse', 'HEAD') == head, 'HEAD changed during fetch')
        task_ref = git(repo, 'ls-remote', '--heads', url, 'refs/heads/' + BRANCH)
        require(not task_ref or task_ref.split()[0] == head, 'Foreign remote task HEAD')
        safety_ref = git(repo, 'ls-remote', '--heads', url, 'refs/heads/' + SAFETY)
        require(not safety_ref or safety_ref.split()[0] == head, 'Existing safety ref differs')
        repos[name] = (repo, head, base, url, bool(safety_ref))
        emit('SOURCE_RECONCILED', {'repository': name, 'head': head, 'parent': base, 'verified_files': len(records)})
    require(count == 28, 'Unexpected P1 source count')
    # The canonical source digest is independently reported alongside the pinned
    # review; per-file hashes/modes and all bases have been compared exactly.
    emit('SOURCE_MANIFEST_VERIFIED', {'files': count, 'review_subject': SUBJECT, 'canonical_digest': canonical})
    for name, (repo, head, base, url, exists) in repos.items():
        require(git(repo, 'rev-parse', 'HEAD') == head and not git(repo, 'status', '--porcelain=v1'), 'Concurrent source change')
        if not exists:
            git(repo, 'push', '--porcelain', url, head + ':refs/heads/' + SAFETY)
        require(git(repo, 'ls-remote', '--heads', url, 'refs/heads/' + SAFETY).split()[0] == head, 'Unconfirmed backup')
        emit('SAFETY_REMOTE_CONFIRMED', {'repository': name, 'branch': SAFETY, 'head': head})
    require((STATE / 'state.json').read_bytes() == before, 'Supervisor state changed concurrently')
    go = find_go()
    destination = Path(tempfile.mkdtemp(prefix='layersentry-p1-hardening-baseline-', dir='/home/opc'))
    platform = repos['adaptgurus/layersentry-platform'][0]
    target = destination / 'layersentry-platform'
    git(platform, 'worktree', 'add', '--detach', str(target), EXPECTED['adaptgurus/layersentry-platform'][0])
    emit('BASELINE_WORKTREE', str(target))
    for argv, seconds in [([go, 'version'], 30), ([go, 'test', '-race', '-count=1', '-coverprofile=' + str(destination / 'coverage.out'), './...'], 360),
                          ([go, 'vet', './...'], 90), ([go, 'build', './...'], 90)]:
        emit('BASELINE_COMMAND', argv)
        print(command(argv, cwd=target, seconds=seconds)[-18000:], flush=True)
    require(not git(target, 'status', '--porcelain=v1'), 'Baseline mutated source')
    emit('PLATFORM_BASELINE', {'result': 'PASS', 'head': EXPECTED['adaptgurus/layersentry-platform'][0], 'live_verified': False})
    emit('RECOVERY_COMPLETE', {'original_worktrees_unchanged': True, 'supervisor_state_unchanged': True, 'guest_mutations': False})


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('RECOVERY_BLOCKED=' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), flush=True)
        sys.exit(1)
