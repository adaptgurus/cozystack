#!/usr/bin/env python3
"""Publication-only transport adapter for the bound GitHub CLI 2.4.

The pinned central supervisor owns every integrity, source, review, push, PR and
STOP decision. Only its unsupported PR-list JSON read is translated to a real
GitHub REST GET using the same unchanged, approved gh executable. No bindings,
source, tools or publication state are manually changed.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlencode

AUTHORITY = Path('/tmp/layersentry-execution-control-20260910')
STATE = Path('/home/opc/.local/state/layersentry-runner')
CENTRAL_SHA = 'ab55a25f4b1421a63718242d8a8f99359d2ab24e'
RUN_ID = 'd5db2181-14e4-4ab0-8464-493b643130b9'
EXPECTED = {
    'adaptgurus/one': '6746b9e22d63a0d7ef64154fd22a8161087e7b68',
    'adaptgurus/one-apps': 'e1bd9602c8bd0aea7839fe9e4a4356a11af4daad',
    'adaptgurus/layersentry-platform': '8b5fa534008c0a517fa924ddca3e8a52ab4e3dfc',
}


def normalize_prs(payload: object, repo: str, branch: str, base: str) -> list[dict]:
    """Fail closed on truncation, wrong repository/ref, malformed IDs or SHAs."""
    if not isinstance(payload, list) or len(payload) >= 100:
        raise ValueError('Invalid or potentially truncated REST PR result')
    result = []
    for item in payload:
        if not isinstance(item, dict):
            raise ValueError('Malformed PR result')
        head, target = item.get('head', {}), item.get('base', {})
        if (not isinstance(head, dict) or not isinstance(target, dict) or
                head.get('ref') != branch or target.get('ref') != base or
                (head.get('repo') or {}).get('full_name') != repo or
                (target.get('repo') or {}).get('full_name') != repo):
            raise ValueError('REST PR repository/ref mismatch')
        sha = head.get('sha', '')
        number = item.get('number')
        url = item.get('html_url')
        if (not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{40}', sha) or
                type(number) is not int or number < 1 or
                url != f'https://github.com/{repo}/pull/{number}'):
            raise ValueError('REST PR identity mismatch')
        state = item.get('state')
        body = item.get('body')
        if state not in ('open', 'closed') or (body is not None and not isinstance(body, str)):
            raise ValueError('Malformed REST PR state/body')
        result.append({'url': url, 'body': body or '', 'headRefOid': sha,
                       'state': 'MERGED' if item.get('merged_at') else state.upper()})
    return result


def legacy_request(args: tuple[str, ...]) -> tuple[str, str, str, str] | None:
    """Translate just the exact unsupported native PR-list operation."""
    if args[:2] != ('pr', 'list'):
        return None
    if (len(args) != 12 or args[2] != '--repo' or args[4] != '--head' or
            args[6] != '--base' or args[8:12] != ('--state', 'all', '--json', 'url,body,headRefOid,state')):
        raise ValueError('Unexpected native PR-list signature')
    repo, branch, base = args[3], args[5], args[7]
    if repo not in EXPECTED or branch != 'layersentry/p1-rke2-provisioning':
        raise ValueError('Unbound publication target')
    expected_base = {'adaptgurus/one': 'one-7.4', 'adaptgurus/one-apps': 'master',
                     'adaptgurus/layersentry-platform': 'main'}[repo]
    if base != expected_base:
        raise ValueError('Unbound publication base')
    query = urlencode({'state': 'all', 'head': repo.split('/')[0] + ':' + branch,
                       'base': base, 'per_page': 100})
    return repo, branch, base, f'repos/{repo}/pulls?{query}'


def main() -> int:
    if subprocess.check_output(['id', '-un'], text=True).strip() != 'opc':
        raise ValueError('Wrong execution user')
    if subprocess.check_output(['hostname', '-s'], text=True).strip() != 'testser':
        raise ValueError('Wrong execution host')
    def git(path: Path, *args: str) -> str:
        return subprocess.check_output(['git', '-C', str(path), *args], text=True, timeout=30).strip()
    if git(AUTHORITY, 'rev-parse', 'HEAD') != CENTRAL_SHA or git(AUTHORITY, 'status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Central authority changed')
    if git(AUTHORITY, 'remote', 'get-url', 'origin') != 'https://github.com/adaptgurus/codexagentlogic.git':
        raise ValueError('Wrong authority repository')
    sys.path.insert(0, str(AUTHORITY / 'tools'))
    from capability_control import CapabilitySupervisor
    from execution_control import digest, require

    class LegacyGhReadAdapter(CapabilitySupervisor):
        def gh(self, state: dict, run: dict, *args: str) -> str:
            request = legacy_request(args)
            if request is None:
                return super().gh(state, run, *args)
            repo, branch, base, endpoint = request
            tool = self.integrity(run)['binding']['tools']['gh']['path']
            result, out = self.record_process(state, run, 'github-rest-pr-read',
                [tool, 'api', '--method', 'GET', endpoint], Path(run['workspace']), 120)
            require(result['exit_code'] == 0, 'GitHub REST PR read failed; reconcile before retry')
            return json.dumps(normalize_prs(json.loads(out.read_text()), repo, branch, base))

    supervisor = LegacyGhReadAdapter(AUTHORITY, STATE)
    # Preflight retains the native shared lock and all of the original gates.
    with supervisor.locked() as state:
        run = state['capability_runs'][RUN_ID]
        require(run['capability'] == 'P1-RKE2' and run['state'] == 'PUBLICATION_UNKNOWN', 'Unexpected run/state')
        supervisor.integrity(run)
        snapshot = supervisor.read_artifact(run['verified_snapshot'])
        review = supervisor.read_artifact(run['final_review'])
        require(review['decision'] == 'ACCEPT' and review['subject_sha256'] == digest(snapshot), 'Review mismatch')
        require(supervisor.source_snapshot(run, require_uncommitted=False) == snapshot, 'Source snapshot changed')
        require(set(run['selected']) == set(EXPECTED), 'Selected repositories changed')
        for name, expected_sha in EXPECTED.items():
            path = Path(run['selected'][name]['worktree'])
            require(path == STATE / 'capabilities' / RUN_ID / 'source' / name.split('/')[1], 'Wrong worktree')
            require(git(path, 'rev-parse', 'HEAD') == expected_sha and not git(path, 'status', '--porcelain'), 'Source drift')
            require(run['publication'][name]['commit'] == expected_sha, 'Publication commit drift')
        # Archive this exact adapter through the native evidence recorder, not by
        # modifying prior artifacts or manually editing the publication journal.
        script = Path(__file__).resolve()
        sha = hashlib.sha256(script.read_bytes()).hexdigest()
        result, _ = supervisor.record_process(state, run, 'operator-publication-adapter-provenance',
            [sys.executable, '-B', '-c',
             'import hashlib,pathlib,sys; p=pathlib.Path(sys.argv[1]); print(p.read_text()); '
             'assert hashlib.sha256(p.read_bytes()).hexdigest()==sys.argv[2]; print("ADAPTER_SHA256="+sys.argv[2])',
             str(script), sha], Path(run['workspace']), 15)
        require(result['exit_code'] == 0, 'Adapter provenance recording failed')
    print(f'COMPATIBILITY_ADAPTER_SHA256={sha}; CENTRAL_AUTHORITY={CENTRAL_SHA}', flush=True)
    print('MODE=NATIVE_PUBLICATION_WITH_LEGACY_GH_READ_ADAPTER; BINDINGS_CHANGED=false; MODEL_CALLS=0', flush=True)
    result = supervisor.resume_publication(RUN_ID)
    print('NATIVE_PUBLICATION_RESULT=' + json.dumps(result), flush=True)
    print('SERVER_MUTATIONS=false; MANUAL_STATE_EDITS=false; FORCE_PUSH=false; MERGE=false', flush=True)
    return 0 if result['state'] == 'PUBLISHED_STOPPED' else 2


if __name__ == '__main__':
    raise SystemExit(main())
