#!/usr/bin/env bash
set -euo pipefail

TALOS_VERSION=${TALOS_VERSION:-v1.13.6}
EXTENSIONS_COMMIT=${EXTENSIONS_COMMIT:-f16e62f2d5927589f62643332dae9c07489cbf47}
LOCAL_REGISTRY=${LOCAL_REGISTRY:-127.0.0.1:5005}
BUILD_TAG=${BUILD_TAG:-v1.13.6-layersentry-prod1}
PKGS_PREFIX=${PKGS_PREFIX:-${LOCAL_REGISTRY}/layersentry/pkgs}
OUT_DIR=${1:-../../../_out/extensions}
WORK_DIR=${EXTENSIONS_WORK_DIR:-${RUNNER_TEMP:-/tmp}/layersentry-extension-build}
EXT_DIR="$WORK_DIR/extensions"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

git clone --filter=blob:none https://github.com/siderolabs/extensions.git "$EXT_DIR"
git -C "$EXT_DIR" checkout --detach "$EXTENSIONS_COMMIT"
test "$(git -C "$EXT_DIR" rev-parse HEAD)" = "$EXTENSIONS_COMMIT"

KERNEL_EXTENSIONS="amdgpu bnx2-bnx2x i915 drbd zfs nfsd nvidia-open-gpu-kernel-modules-production nvidia-gdrdrv-device"

export_extension() {
  target=$1
  local_image="layersentry/${target}:${BUILD_TAG}"
  raw_tar="$OUT_DIR/layersentry-${target}.tar"

  make -C "$EXT_DIR" "docker-${target}" \
    PLATFORM=linux/amd64 \
    PKGS_PREFIX="$PKGS_PREFIX" \
    PKGS="$BUILD_TAG" \
    TARGET_ARGS="--tag=${local_image} --load"

  docker image inspect "$local_image" >/dev/null
  cid=$(docker create "$local_image" /bin/true)
  docker export "$cid" > "$raw_tar"
  docker rm "$cid" >/dev/null

  test -s "$raw_tar"
  tar -tf "$raw_tar" | sed 's#^\./##' | grep -Fxq 'manifest.yaml'
}

for target in $KERNEL_EXTENSIONS; do
  export_extension "$target"
done

# The stock v1.13.6 ZFS extension runs `zpool import -fal` on boot. Remove only
# that service definition; retain the custom-kernel ZFS module and userspace so
# explicit LayerSentry storage reconciliation can manage approved pools.
ZFS_TAR="$OUT_DIR/layersentry-zfs.tar"
ZFS_ROOT="$WORK_DIR/zfs-safe"
mkdir -p "$ZFS_ROOT"
tar -C "$ZFS_ROOT" -xf "$ZFS_TAR"
rm -f "$ZFS_ROOT/rootfs/usr/local/etc/containers/zfs-service.yaml"
if find "$ZFS_ROOT/rootfs/usr/local/etc/containers" -maxdepth 1 -type f -name '*zfs*service*.yaml' -print 2>/dev/null | grep -q .; then
  echo 'unsafe automatic ZFS service definition survived sanitization' >&2
  exit 1
fi
mkdir -p "$ZFS_ROOT/rootfs/usr/local/share/layersentry"
cat > "$ZFS_ROOT/rootfs/usr/local/share/layersentry/storage-ownership-policy.txt" <<'EOF'
LayerSentry universal storage ownership policy:
- never import, format, export, or claim a disk/LUN because it is merely visible;
- ZFS pool lifecycle must be explicitly reconciled by LayerSentry;
- SAN destructive actions require WWID/WWN/NQN/serial identity validation;
- the upstream automatic `zpool import -fal` service is intentionally absent.
EOF
tar --sort=name --mtime='UTC 2026-08-30' --owner=0 --group=0 --numeric-owner \
  -C "$ZFS_ROOT" -cf "$ZFS_TAR" manifest.yaml rootfs

for target in amdgpu bnx2-bnx2x i915 drbd zfs nfsd nvidia-open-gpu-kernel-modules-production; do
  tarball="$OUT_DIR/layersentry-${target}.tar"
  test -s "$tarball"
  tar -tf "$tarball" | grep -E '\.ko$' >/dev/null || {
    echo "rebuilt kernel extension ${target} contains no kernel module" >&2
    exit 1
  }
done

tar -tf "$ZFS_TAR" | grep -E '/zpool$' >/dev/null
tar -tf "$ZFS_TAR" | grep -E '/zfs$' >/dev/null
if tar -tf "$ZFS_TAR" | grep -Fq 'rootfs/usr/local/etc/containers/zfs-service.yaml'; then
  echo 'unsafe upstream ZFS auto-import service is still present' >&2
  exit 1
fi

(
  cd "$OUT_DIR"
  # shellcheck disable=SC2046
  sha256sum $(printf 'layersentry-%s.tar ' $KERNEL_EXTENSIONS) > layersentry-kernel-extensions.sha256
)

printf '%s\n' "rebuilt kernel extensions from ${EXTENSIONS_COMMIT} against ${PKGS_PREFIX}:${BUILD_TAG}"
cat "$OUT_DIR/layersentry-kernel-extensions.sha256"
