#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
NFS_UTILS_VERSION=${NFS_UTILS_VERSION:-2.6.4-r4}
EXTENSION_VERSION=${EXTENSION_VERSION:-2.6.4-r4-layersentry.1}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

PKG_ROOT="$TMPDIR/pkg-root"
EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-nfs-server"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"

mkdir -p "$PKG_ROOT" "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

# Build a self-contained NFS userspace underneath the extension-service rootfs.
# This keeps Alpine's libraries and configuration isolated from the immutable
# Talos host while still using the Talos-version-matched nfsd kernel module.
docker run --rm \
  -e NFS_UTILS_VERSION="$NFS_UTILS_VERSION" \
  -v "$TMPDIR:/work" \
  "$ALPINE_IMAGE" \
  sh -euc '
    apk add \
      --root /work/pkg-root \
      --initdb \
      --no-cache \
      --no-scripts \
      --repositories-file /etc/apk/repositories \
      busybox \
      "nfs-utils=${NFS_UTILS_VERSION}"
  '

cp -a "$PKG_ROOT"/. "$SERVICE_ROOT"/
mkdir -p "$SERVICE_ROOT/usr/local/sbin" "$SERVICE_ROOT/etc"

# The exports file is deliberately controller-owned. The ISO starts the NFS
# engine but exports nothing until LayerSentry writes an explicit policy under
# /var/lib/layersentry/nfs-server/exports. This avoids exposing disks simply by
# booting the image.
rm -f "$SERVICE_ROOT/etc/exports"
ln -s /run/layersentry-nfs/exports "$SERVICE_ROOT/etc/exports"

cat > "$SERVICE_ROOT/usr/local/sbin/layersentry-nfs-server" <<'EOF'
#!/bin/sh
set -eu

mkdir -p /run/layersentry-nfs /var/lib/nfs /var/lib/nfs/rpc_pipefs /proc/fs/nfsd
touch /run/layersentry-nfs/exports

# nfsd is a pseudo filesystem used to control the in-kernel NFS server. The
# extension service is privileged; mount it in this service namespace if Talos
# has not already made it visible.
if ! grep -qs ' /proc/fs/nfsd nfsd ' /proc/mounts; then
  mount -t nfsd nfsd /proc/fs/nfsd
fi

cleanup() {
  exportfs -au >/dev/null 2>&1 || true
  [ -z "${STATD_PID:-}" ] || kill "$STATD_PID" >/dev/null 2>&1 || true
  [ -z "${RPCBIND_PID:-}" ] || kill "$RPCBIND_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Fixed rpcbind/statd/mountd ports keep NFSv3 operation predictable. NFSv4 uses
# TCP/2049 directly. Host ingress filtering is explicitly set to accept in the
# LayerSentry machine configuration; external fabric ACLs remain site policy.
rpcbind -f -w &
RPCBIND_PID=$!
rpc.statd -F -p 662 -o 2020 &
STATD_PID=$!

rpc.nfsd 16 --port 2049
exportfs -ra

# Keep the service supervised by foreground mountd. Re-applying exports is done
# with exportfs -ra by the LayerSentry storage controller after updating the
# controller-owned exports file.
exec rpc.mountd -F -p 20048
EOF
chmod 0755 "$SERVICE_ROOT/usr/local/sbin/layersentry-nfs-server"

cat > "$SERVICE_DEFS/layersentry-nfs-server.yaml" <<'EOF'
name: layersentry-nfs-server
depends:
  - service: cri
  - network:
      - addresses
      - connectivity
      - hostname
      - etcfiles
container:
  entrypoint: /usr/local/sbin/layersentry-nfs-server
  mounts:
    - source: /dev
      destination: /dev
      type: bind
      options:
        - rshared
        - rbind
        - rw
    - source: /var/mnt
      destination: /var/mnt
      type: bind
      options:
        - rshared
        - rbind
        - rw
    - source: /var/lib/layersentry/nfs-server
      destination: /run/layersentry-nfs
      type: bind
      options:
        - rshared
        - rbind
        - rw
  security:
    maskedPaths: []
    readonlyPaths: []
    writeableRootfs: true
    writeableSysfs: true
    rootfsPropagation: shared
restart: always
EOF

cat > "$EXT_ROOT/manifest.yaml" <<EOF
version: v1alpha1
metadata:
  name: layersentry-nfs-server
  version: "${EXTENSION_VERSION}"
  author: LayerSentry
  description: |
    LayerSentry NFS server/export service based on nfs-utils and the Talos nfsd module.
    Supports controller-managed NFS exports without hard-coded default shares.
  compatibility:
    talos:
      version: ">= v1.13.0"
EOF

# Release-blocking assertions for the complete server userspace.
for binary in \
  usr/sbin/exportfs \
  usr/sbin/rpc.nfsd \
  usr/sbin/rpc.mountd \
  sbin/rpc.statd; do
  test -x "$SERVICE_ROOT/$binary"
done

test -x "$SERVICE_ROOT/usr/local/sbin/layersentry-nfs-server"
test -s "$SERVICE_DEFS/layersentry-nfs-server.yaml"
test -s "$EXT_ROOT/manifest.yaml"

OUT="$OUT_DIR/layersentry-nfs-server.tar"
tar \
  --sort=name \
  --mtime='UTC 2026-08-29' \
  --owner=0 --group=0 --numeric-owner \
  -C "$EXT_ROOT" \
  -cf "$OUT" manifest.yaml rootfs

sha256sum "$OUT" > "$OUT.sha256"
echo "built $OUT"
cat "$OUT.sha256"
