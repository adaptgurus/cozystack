#!/usr/bin/env bash
set -euo pipefail
umask 077
expected=ab55a25f4b1421a63718242d8a8f99359d2ab24e
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
source=/home/opc/.local/state/layersentry-runner/worktrees/bca780bd-53af-435b-ab1d-a7a80ad5818c
[[ -f "$source/.git" || -d "$source/.git" ]] || exit 21
remote=$(git -C "$source" remote get-url origin)
[[ "$remote" == https://github.com/adaptgurus/codexagentlogic.git ]] || exit 22
git -C "$source" cat-file -e "$expected^{commit}"
printf 'CENTRAL_REGRESSION_TARGET=%s\nCENTRAL_SOURCE_PATH=%s\n' "$expected" "$source"
scratch=$(mktemp -d /tmp/layersentry-central-regression.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/home" "$scratch/tmp"
git clone --quiet --no-hardlinks --no-checkout "$source" "$scratch/repo"
git -C "$scratch/repo" checkout --quiet --detach "$expected"
[[ $(git -C "$scratch/repo" rev-parse HEAD) == "$expected" ]] || exit 23
cd "$scratch/repo"
echo 'REGRESSION_SCOPE=existing tests/test_*.py; MODEL_SSH_GITHUB_BEHAVIOR=synthetic fixtures; SOURCE_WORKTREE_CHANGED=false'
set +e
timeout --signal=TERM --kill-after=10s 480s env -i HOME="$scratch/home" TMPDIR="$scratch/tmp" PATH=/usr/local/bin:/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s tests -p 'test_*.py' -v >"$scratch/tests.log" 2>&1
code=$?
set -e
tail -n 110 "$scratch/tests.log"
printf 'CENTRAL_FULL_UNIT_SUITE_EXIT=%s\n' "$code"
echo 'OPENNEBULA_MUTATIONS=false; GUEST_MUTATIONS=false; PAID_MODEL_CALLS=0; LIVE_RKE2_CERTIFICATION=false'
exit "$code"
