#!/usr/bin/env bash
set -euo pipefail
umask 077
work=${1:?working directory required}
case "$work" in /mnt/c/ProgramData/LayerSentry/P1Day2Source/run-*) ;; *) exit 21;; esac
trap 'rc=$?; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT
[[ $(id -un) == opc && $(hostname -s | tr '[:upper:]' '[:lower:]') == testser ]] || exit 20

selected=''
shopt -s nullglob
for p in /tmp/layersentry-go*/go/bin/go /usr/local/go/bin/go /home/opc/.local/go/bin/go /home/opc/sdk/go*/bin/go /home/opc/go/pkg/mod/golang.org/toolchain@*/bin/go; do
  [[ -x "$p" ]] || continue
  v=$($p version 2>/dev/null || true)
  if [[ "$v" =~ go1\.([0-9]+)\. ]] && (( BASH_REMATCH[1] >= 24 )); then
    selected=$p
    printf 'GO_SELECTED path=%q version=%q sha256=%s\n' "$p" "$v" "$(sha256sum "$p" | awk '{print $1}')"
    break
  fi
done
[[ -n "$selected" ]] || { echo 'NO_GO_GE_1_24'; exit 42; }

state=/home/opc/.local/state/layersentry-runner
repo="$state/capabilities/d5db2181-14e4-4ab0-8464-493b643130b9/source/layersentry-platform"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null
expected=aa47337fb5141ade8bcacb9d5251e917d055b740
printf 'LOCAL_HEAD=%s LOCAL_BRANCH=%s\n' "$(git -C "$repo" rev-parse HEAD)" "$(git -C "$repo" branch --show-current)"
git -C "$repo" fetch --no-prune origin layersentry/p1-rke2-day2-production-20260913
test "$(git -C "$repo" rev-parse 'origin/layersentry/p1-rke2-day2-production-20260913^{commit}')" = "$expected"
tmp=$(mktemp -d -p /home/opc layersentry-day2-source-XXXXXX)
cleanup() {
  git -C "$repo" worktree remove --force "$tmp/platform" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap 'rc=$?; cleanup; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT
git -C "$repo" worktree add --detach "$tmp/platform" "$expected"
test -z "$(git -C "$tmp/platform" status --porcelain=v1 --untracked-files=all)"
(cd "$tmp/platform" && "$selected" test -race -count=1 ./...)
(cd "$tmp/platform" && "$selected" vet ./...)
(cd "$tmp/platform" && "$selected" build ./...)
test -z "$(git -C "$tmp/platform" status --porcelain=v1 --untracked-files=all)"
echo "PLATFORM_DAY2_SOURCE_GATE=PASS head=$expected"
