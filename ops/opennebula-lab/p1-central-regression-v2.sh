#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == opc && $(hostname -s) == testser ]] || exit 20
work=${1:?Provide this job's temporary working directory}
case "$work" in /mnt/c/ProgramData/LayerSentry/CentralRegression/run-*) ;; *) exit 21;; esac
trap 'rc=$?; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT
expected=ab55a25f4b1421a63718242d8a8f99359d2ab24e
source=/home/opc/.local/state/layersentry-runner/worktrees/bca780bd-53af-435b-ab1d-a7a80ad5818c
py=/tmp/layersentry-python-runtime/cpython-3.12.14-linux-x86_64-gnu/bin/python3.12
[[ $(git -C "$source" remote get-url origin) == https://github.com/adaptgurus/codexagentlogic.git ]] || exit 22
git -C "$source" cat-file -e "$expected^{commit}"
"$py" -c 'import sys,tomllib; assert sys.version_info >= (3,11); print("REGRESSION_PYTHON="+sys.version.split()[0])'
scratch=$(mktemp -d /tmp/layersentry-central-regression-v2.XXXXXXXX)
trap 'rc=$?; rm -rf -- "$scratch"; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT
mkdir "$scratch/home" "$scratch/tmp"
git clone --quiet --no-hardlinks --no-checkout "$source" "$scratch/repo"
git -C "$scratch/repo" checkout --quiet --detach "$expected"
[[ $(git -C "$scratch/repo" rev-parse HEAD) == "$expected" ]] || exit 23
cd "$scratch/repo"
printf 'CENTRAL_TESTED_COMMIT=%s\n' "$expected"
echo 'TEST_SCOPE=complete existing central unit suite; LIVE_TESTS=false; REAL_MODEL_CALLS=0'
set +e
timeout --signal=TERM --kill-after=10s 480s env -i HOME="$scratch/home" TMPDIR="$scratch/tmp" PATH="${py%/*}:/usr/local/bin:/usr/bin:/bin" PYTHONDONTWRITEBYTECODE=1 "$py" -B -m unittest discover -s tests -p 'test_*.py' -v >"$scratch/tests.log" 2>&1
code=$?
set -e
tail -n 165 "$scratch/tests.log"
printf 'CENTRAL_FULL_UNIT_SUITE_EXIT=%s\n' "$code"
echo 'SERVER_MUTATIONS=false; CENTRAL_SOURCE_CHANGED=false; ALL_TEMPORARY_TEST_FILES_REMOVED_ON_EXIT=true'
exit "$code"
