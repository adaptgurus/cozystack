#!/usr/bin/env bash
set -euo pipefail
umask 077
work=${1:?working directory required}
case "$work" in /mnt/c/ProgramData/LayerSentry/P1Day2Inventory/run-*) ;; *) exit 21;; esac
trap 'rc=$?; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT

[[ $(id -un) == opc && $(hostname -s | tr '[:upper:]' '[:lower:]') == testser ]] || exit 20

echo 'WSL_IDENTITY=PASS'
printf 'wsl_user=%s wsl_host=%s\n' "$(id -un)" "$(hostname -s)"

# Discover only known/safe Go installation locations. Do not install or mutate.
echo '=== GO_TOOLCHAIN_DISCOVERY ==='
selected=''
shopt -s nullglob
candidates=(
  /tmp/layersentry-go*/go/bin/go
  /usr/local/go/bin/go
  /home/opc/.local/go/bin/go
  /home/opc/sdk/go*/bin/go
  /home/opc/go/pkg/mod/golang.org/toolchain@*/bin/go
)
for p in "${candidates[@]}"; do
  [[ -x "$p" ]] || continue
  v=$($p version 2>/dev/null || true)
  sha=$(sha256sum "$p" | awk '{print $1}')
  printf 'GO_CANDIDATE path=%q version=%q sha256=%s\n' "$p" "$v" "$sha"
  if [[ -z "$selected" && "$v" =~ go1\.([0-9]+)\. ]]; then
    minor=${BASH_REMATCH[1]}
    if (( minor >= 24 )); then selected=$p; fi
  fi
done
printf 'GO_SELECTED=%q\n' "$selected"

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

echo '=== SSH_CONNECTIVITY ==='
for host in rocky-01 rocky-02 rocky-03; do
  printf '%s=' "$host"
  ssh "${ssh_opts[@]}" "$host" 'hostname -s' | tr -d '\r'
done

echo '=== ROCKY01_OPENNEBULA_READONLY ==='
ssh "${ssh_opts[@]}" rocky-01 'set -eu
printf "HOST=%s\n" "$(hostname -s)"
printf "ONEVERSION="; oneversion 2>/dev/null || true
echo "-- onehost --"; onehost list
echo "-- onevm --"; onevm list
echo "-- onecluster --"; onecluster list
echo "-- oneimage --"; oneimage list
echo "-- onedatastore --"; onedatastore list
echo "-- oneflow-template --"; oneflow-template list
echo "-- oneflow --"; oneflow list
echo "-- OneKS binaries/processes --"
command -v oneks-server || true
command -v one-server || true
ps -eo pid,user,comm,args | grep -E "[o]neks|[o]ne-server|[o]ned" || true
echo "-- relevant units --"
systemctl list-unit-files --type=service 2>/dev/null | grep -E "opennebula|oneks" || true'

echo '=== ROCKY02_COMPUTE_READONLY ==='
ssh "${ssh_opts[@]}" rocky-02 'set -eu
printf "HOST=%s\n" "$(hostname -s)"
sudo -n virsh list --all
df -hT /var/lib/one/datastores || true'

echo '=== ROCKY03_COMPUTE_READONLY ==='
ssh "${ssh_opts[@]}" rocky-03 'set -eu
printf "HOST=%s\n" "$(hostname -s)"
sudo -n virsh list --all
df -hT /var/lib/one/datastores || true'

echo 'LIVE_READONLY_LAB_ACCESS=PASS'

# Run exact PR #40 source gate if a suitable existing Go toolchain is present.
if [[ -z "$selected" ]]; then
  echo 'PLATFORM_DAY2_SOURCE_GATE=BLOCKED_NO_GO_TOOLCHAIN'
  exit 42
fi

echo '=== DAY2_PLATFORM_SOURCE_GATE ==='
state=/home/opc/.local/state/layersentry-runner
repo="$state/capabilities/d5db2181-14e4-4ab0-8464-493b643130b9/source/layersentry-platform"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null
printf 'PLATFORM_LOCAL_HEAD=%s\n' "$(git -C "$repo" rev-parse HEAD)"
printf 'PLATFORM_LOCAL_BRANCH=%s\n' "$(git -C "$repo" branch --show-current)"
expected=aa47337fb5141ade8bcacb9d5251e917d055b740
git -C "$repo" fetch --no-prune origin layersentry/p1-rke2-day2-production-20260913
test "$(git -C "$repo" rev-parse 'origin/layersentry/p1-rke2-day2-production-20260913^{commit}')" = "$expected"
tmp=$(mktemp -d -p /home/opc layersentry-day2-inventory-XXXXXX)
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
