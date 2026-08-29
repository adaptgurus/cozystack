#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22@sha256:55ae5d250caebc548793f321534bc6a8ef1d116f334f18f4ada1b2daad3251b2}
NFS_UTILS_VERSION=${NFS_UTILS_VERSION:-2.6.4-r4}
EXTENSION_VERSION=${EXTENSION_VERSION:-2.6.4-r4-layersentry.3}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-nfs-server"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"
PACKAGE_TAR="$TMPDIR/nfs-server-rootfs.tar"

mkdir -p "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

docker run --rm \
  -e NFS_UTILS_VERSION="$NFS_UTILS_VERSION" \
  -v "$TMPDIR:/work" \
  "$ALPINE_IMAGE" \
  sh -euc '
    mkdir -p /pkg-root/etc/apk/keys
    cp -a /etc/apk/keys/. /pkg-root/etc/apk/keys/
    apk add --root /pkg-root --initdb --no-cache --no-scripts \
      --repositories-file /etc/apk/repositories \
      busybox "nfs-utils=${NFS_UTILS_VERSION}"
    rm -rf /pkg-root/dev /pkg-root/proc /pkg-root/sys /pkg-root/run \
           /pkg-root/tmp /pkg-root/var/tmp /pkg-root/var/cache/apk
    find /pkg-root -xdev \( -type f -o -type d \) -perm -0002 -exec chmod o-w {} +
    tar -C /pkg-root -cf /work/nfs-server-rootfs.tar .
  '

tar -C "$SERVICE_ROOT" -xf "$PACKAGE_TAR"
mkdir -p "$SERVICE_ROOT/usr/local/sbin" "$SERVICE_ROOT/etc"
rm -f "$SERVICE_ROOT/etc/exports"
ln -s /run/layersentry-nfs/exports "$SERVICE_ROOT/etc/exports"

cat > "$SERVICE_ROOT/usr/local/sbin/layersentry-nfs-server" <<'EOF'
#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /run/layersentry-nfs /var/lib/nfs /var/lib/nfs/rpc_pipefs /proc/fs/nfsd
touch /run/layersentry-nfs/exports

# Universal-image safety: do not bind RPC/NFS ports merely because the host has
# NFS capability. LayerSentry must first reconcile export policy and create the
# controller-owned activation marker.
while [ ! -f /run/layersentry-nfs/enabled ]; do
  sleep 2
done

if ! grep -qs ' /proc/fs/nfsd nfsd ' /proc/mounts; then
  mount -t nfsd nfsd /proc/fs/nfsd
fi

cleanup() {
  exportfs -au >/dev/null 2>&1 || true
  [ -z "${STATD_PID:-}" ] || kill "$STATD_PID" >/dev/null 2>&1 || true
  [ -z "${RPCBIND_PID:-}" ] || kill "$RPCBIND_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

rpcbind -f -w &
RPCBIND_PID=$!
rpc.statd -F -p 662 -o 2020 &
STATD_PID=$!
rpc.nfsd 16 --port 2049
exportfs -ra
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
      options: [rshared, rbind, rw]
    - source: /var/mnt
      destination: /var/mnt
      type: bind
      options: [rshared, rbind, rw]
    - source: /var/lib/layersentry/nfs-server
      destination: /run/layersentry-nfs
      type: bind
      options: [rshared, rbind, rw]
  security:
    maskedPaths: []
    readonlyPaths: []
    writeableRootfs: true
    writeableSysfs: false
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
    Controller-activated NFS server/export service based on nfs-utils and the
    custom-kernel nfsd extension. No RPC/NFS listener or export is activated by
    image boot alone.
  compatibility:
    talos:
      version: ">= v1.13.0"
EOF

cat > "$OUT_DIR/layersentry-nfs-server.sbom.spdx.json" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "layersentry-nfs-server-${EXTENSION_VERSION}",
  "documentNamespace": "https://layersentry.invalid/sbom/nfs-server/${EXTENSION_VERSION}",
  "creationInfo": {"created": "2026-08-30T00:00:00Z", "creators": ["Organization: LayerSentry"]},
  "packages": [
    {"name": "nfs-utils", "SPDXID": "SPDXRef-nfs-utils", "versionInfo": "${NFS_UTILS_VERSION}", "downloadLocation": "NOASSERTION", "filesAnalyzed": false},
    {"name": "alpine-base", "SPDXID": "SPDXRef-alpine", "versionInfo": "3.22", "downloadLocation": "NOASSERTION", "filesAnalyzed": false}
  ]
}
EOF

for binary in usr/sbin/exportfs usr/sbin/rpc.nfsd usr/sbin/rpc.mountd sbin/rpc.statd; do
  test -x "$SERVICE_ROOT/$binary"
done
test -x "$SERVICE_ROOT/usr/local/sbin/layersentry-nfs-server"
test -s "$SERVICE_DEFS/layersentry-nfs-server.yaml"
test -s "$EXT_ROOT/manifest.yaml"
test -s "$OUT_DIR/layersentry-nfs-server.sbom.spdx.json"
grep -Fq 'while [ ! -f /run/layersentry-nfs/enabled ]' "$SERVICE_ROOT/usr/local/sbin/layersentry-nfs-server"

if find "$EXT_ROOT/rootfs" \( -type b -o -type c -o -type p -o -type s \) -print | grep -q .; then
  echo "ERROR: special file found in LayerSentry NFS server extension" >&2
  exit 1
fi
if find "$EXT_ROOT/rootfs" \( -type f -o -type d \) -perm -0002 -print | grep -q .; then
  echo "ERROR: world-writable file/directory found in LayerSentry NFS server extension" >&2
  exit 1
fi

OUT="$OUT_DIR/layersentry-nfs-server.tar"
tar --sort=name --mtime='UTC 2026-08-30' --owner=0 --group=0 --numeric-owner \
  -C "$EXT_ROOT" -cf "$OUT" manifest.yaml rootfs
sha256sum "$OUT" > "$OUT.sha256"
echo "built $OUT"
cat "$OUT.sha256"
