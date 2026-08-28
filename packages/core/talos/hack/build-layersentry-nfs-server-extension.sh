#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
NFS_UTILS_VERSION=${NFS_UTILS_VERSION:-2.6.4-r4}
EXTENSION_VERSION=${EXTENSION_VERSION:-2.6.4-r4-layersentry.2}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-nfs-server"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"
PACKAGE_TAR="$TMPDIR/nfs-server-rootfs.tar"

mkdir -p "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

# Build the complete NFS userspace *inside* the signed Alpine container. Seed
# the alternate root with Alpine's trusted keys before package resolution, then
# export a normal tar so the runner never receives root-owned working files.
docker run --rm \
  -e NFS_UTILS_VERSION="$NFS_UTILS_VERSION" \
  -v "$TMPDIR:/work" \
  "$ALPINE_IMAGE" \
  sh -euc '
    mkdir -p /pkg-root/etc/apk/keys
    cp -a /etc/apk/keys/. /pkg-root/etc/apk/keys/

    apk add \
      --root /pkg-root \
      --initdb \
      --no-cache \
      --no-scripts \
      --repositories-file /etc/apk/repositories \
      busybox \
      "nfs-utils=${NFS_UTILS_VERSION}"

    # Alternate-root initialization can create device nodes/cache that Talos
    # extensions neither need nor permit. Strip them and remove world-write bits
    # from regular files/directories; symlink mode bits are not permissions.
    rm -rf /pkg-root/dev /pkg-root/proc /pkg-root/sys /pkg-root/run \
           /pkg-root/tmp /pkg-root/var/tmp /pkg-root/var/cache/apk
    find /pkg-root -xdev \( -type f -o -type d \) -perm -0002 -exec chmod o-w {} +

    tar -C /pkg-root -cf /work/nfs-server-rootfs.tar .
  '

tar -C "$SERVICE_ROOT" -xf "$PACKAGE_TAR"
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
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

# Fixed statd/mountd ports keep NFSv3 operation predictable. NFSv4 uses
# TCP/2049 directly. Host ingress filtering is explicitly accept in the
# LayerSentry machine config; external fabric ACLs remain site policy.
rpcbind -f -w &
RPCBIND_PID=$!
rpc.statd -F -p 662 -o 2020 &
STATD_PID=$!

rpc.nfsd 16 --port 2049
exportfs -ra

# Foreground mountd is the supervised process. After the LayerSentry controller
# updates the controller-owned exports file, it can apply policy with exportfs
# -ra inside ext-layersentry-nfs-server.
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

# Release-blocking assertions for complete NFS server userspace.
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

# Validate Talos' basic extension rootfs restrictions. Symlinks commonly have
# 0777 mode by definition; only regular files/directories are checked for a
# world-write bit.
if find "$EXT_ROOT/rootfs" \( -type b -o -type c -o -type p -o -type s \) -print | grep -q .; then
  echo "ERROR: special file found in LayerSentry NFS server extension" >&2
  exit 1
fi
if find "$EXT_ROOT/rootfs" \( -type f -o -type d \) -perm -0002 -print | grep -q .; then
  echo "ERROR: world-writable file/directory found in LayerSentry NFS server extension" >&2
  exit 1
fi

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
