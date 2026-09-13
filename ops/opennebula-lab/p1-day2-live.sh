#!/usr/bin/env bash
set -euo pipefail
umask 077
work=${1:?working directory required}
case "$work" in /mnt/c/ProgramData/LayerSentry/P1Day2LiveV2/run-*) ;; *) exit 21;; esac
trap 'rc=$?; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT

[[ $(id -un) == opc && $(hostname -s | tr '[:upper:]' '[:lower:]') == testser ]] || exit 20

echo '=== WSL_IDENTITY ==='
id
uname -a
printf 'wsl_host=%s\n' "$(hostname -s)"

GO=/tmp/layersentry-go1.27.1/go/bin/go
test -x "$GO"
test "$(sha256sum "$GO" | awk '{print $1}')" = '30969f97169d7f43fe6a085873d75613adc21e30818a8c61d95bd27275df4624'
"$GO" version

echo '=== DAY2_PLATFORM_SOURCE_GATE ==='
state=/home/opc/.local/state/layersentry-runner
repo="$state/capabilities/d5db2181-14e4-4ab0-8464-493b643130b9/source/layersentry-platform"
test -d "$repo/.git"
expected=aa47337fb5141ade8bcacb9d5251e917d055b740
git -C "$repo" fetch --no-prune origin layersentry/p1-rke2-day2-production-20260913
test "$(git -C "$repo" rev-parse 'origin/layersentry/p1-rke2-day2-production-20260913^{commit}')" = "$expected"
tmp=$(mktemp -d -p /home/opc layersentry-day2-live-XXXXXX)
cleanup() {
  git -C "$repo" worktree remove --force "$tmp/platform" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap 'rc=$?; cleanup; printf "%s\n" "$rc" > "$work/shell-exit-code.txt"' EXIT
git -C "$repo" worktree add --detach "$tmp/platform" "$expected"
test -z "$(git -C "$tmp/platform" status --porcelain=v1 --untracked-files=all)"
(cd "$tmp/platform" && "$GO" test -race -count=1 ./...)
(cd "$tmp/platform" && "$GO" vet ./...)
(cd "$tmp/platform" && "$GO" build ./...)
test -z "$(git -C "$tmp/platform" status --porcelain=v1 --untracked-files=all)"
echo "PLATFORM_DAY2_SOURCE_GATE=PASS head=$expected"

echo '=== SSH_ALIAS_RESOLUTION ==='
for host in rocky-01 rocky-02 rocky-03; do
  echo "--- $host ---"
  ssh -G "$host" 2>/dev/null | awk '$1=="hostname" || $1=="user" || $1=="port" || $1=="proxyjump" {print}'
done

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

echo '=== ROCKY01_OPENNEBULA_READONLY ==='
ssh "${ssh_opts[@]}" rocky-01 'set -eu
hostname
echo "-- version --"
oneversion || true
echo "-- hosts --"
onehost list
echo "-- vms --"
onevm list
echo "-- clusters --"
onecluster list
echo "-- images --"
oneimage list
echo "-- datastores --"
onedatastore list
echo "-- flow templates --"
oneflow-template list
echo "-- flows --"
oneflow list
echo "-- oneks processes --"
ps -ef | grep -E "[o]neks|[o]ne-server|[o]ned" || true
echo "-- listeners --"
ss -lnt | grep -E ":(2633|2616|2617|2618|9869|80|443)[[:space:]]" || true'

echo '=== ROCKY02_COMPUTE_READONLY ==='
ssh "${ssh_opts[@]}" rocky-02 'set -eu
hostname
sudo -n virsh list --all
echo "-- datastore --"
df -hT /var/lib/one/datastores || true
echo "-- addresses --"
ip -brief address'

echo '=== ROCKY03_COMPUTE_READONLY ==='
ssh "${ssh_opts[@]}" rocky-03 'set -eu
hostname
sudo -n virsh list --all
echo "-- datastore --"
df -hT /var/lib/one/datastores || true
echo "-- addresses --"
ip -brief address'

echo 'LIVE_READONLY_LAB_ACCESS=PASS'
