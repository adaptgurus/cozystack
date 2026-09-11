#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
central=/tmp/layersentry-execution-control-20260910
expected=ab55a25f4b1421a63718242d8a8f99359d2ab24e
state=/home/opc/.local/state/layersentry-runner
run=d5db2181-14e4-4ab0-8464-493b643130b9
[[ $(git -C "$central" rev-parse HEAD) == "$expected" ]] || { echo CENTRAL_HEAD_MISMATCH; exit 21; }
[[ -z $(git -C "$central" status --porcelain --untracked-files=no) ]] || { echo CENTRAL_TRACKED_SOURCE_DIRTY; exit 22; }
[[ $(git -C "$central" remote get-url origin) == https://github.com/adaptgurus/codexagentlogic.git ]] || exit 23
python3 - "$state" "$run" <<'PRECHECK'
import hashlib,json,pathlib,sys,subprocess
root=pathlib.Path(sys.argv[1]);rid=sys.argv[2];state=json.loads((root/'state.json').read_text());run=state['capability_runs'][rid]
assert run['capability']=='P1-RKE2'
assert run['state'] in ['PUBLICATION_UNKNOWN','VERIFIED','PUBLISHING','PUBLISHED_STOPPED']
expected={'adaptgurus/one':'6746b9e22d63a0d7ef64154fd22a8161087e7b68','adaptgurus/one-apps':'e1bd9602c8bd0aea7839fe9e4a4356a11af4daad','adaptgurus/layersentry-platform':'8b5fa534008c0a517fa924ddca3e8a52ab4e3dfc'}
assert set(run['selected'])==set(expected)
for name,sha in expected.items():
 p=pathlib.Path(run['selected'][name]['worktree'])
 assert p==root/'capabilities'/rid/'source'/name.split('/')[1]
 assert subprocess.check_output(['git','-C',str(p),'rev-parse','HEAD'],text=True).strip()==sha
 assert not subprocess.check_output(['git','-C',str(p),'status','--porcelain'],text=True).strip()
 assert run['publication'][name]['commit']==sha
review=json.loads((root/run['final_review']['path']).read_text())
assert review['decision']=='ACCEPT'
print('PUBLISH_RESUME_PRECHECK=PASS; RUN='+rid+'; PRIOR_STATE='+run['state'])
PRECHECK
cd "$central"
echo 'EXECUTION_MODE=NATIVE_SUPERVISOR_PUBLICATION_ONLY; PAID_MODEL_CALLS=0; LAB_MUTATIONS_REQUESTED=false; MERGE_REQUESTED=false'
set +e
timeout --signal=TERM --kill-after=15s 480s python3 -B tools/dispatch_task.py --authority "$central" --state-dir "$state" publish-capability --run "$run"
code=$?
set -e
python3 - "$state" "$run" <<'REPORT'
import json,pathlib,sys
r=json.loads((pathlib.Path(sys.argv[1])/'state.json').read_text())['capability_runs'][sys.argv[2]]
print('NATIVE_PUBLICATION_FINAL_STATE='+json.dumps({'id':r['id'],'state':r['state'],'reason':r.get('reason'),'publication':{name:{k:p.get(k) for k in ['state','branch','commit','url']} for name,p in r.get('publication',{}).items()}}))
REPORT
printf 'PUBLISH_RESUME_EXIT=%s\n' "$code"
echo 'SERVER_MUTATIONS=false; MANUAL_SUPERVISOR_STATE_EDITS=false; FORCE_PUSH=false; MERGE=false'
exit "$code"
