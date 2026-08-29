#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
ETHTOOL_VERSION=${ETHTOOL_VERSION:-6.14.1-r0}
RDMA_CORE_VERSION=${RDMA_CORE_VERSION:-57.0-r0}
IPROUTE2_RDMA_VERSION=${IPROUTE2_RDMA_VERSION:-6.15.0-r0}
EXTENSION_VERSION=${EXTENSION_VERSION:-1.0.0-layersentry.1}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-hci-tools"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"
PACKAGE_TAR="$TMPDIR/hci-tools-rootfs.tar"
mkdir -p "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

docker run --rm \
  -e ETHTOOL_VERSION="$ETHTOOL_VERSION" \
  -e RDMA_CORE_VERSION="$RDMA_CORE_VERSION" \
  -e IPROUTE2_RDMA_VERSION="$IPROUTE2_RDMA_VERSION" \
  -v "$TMPDIR:/work" \
  "$ALPINE_IMAGE" \
  sh -euc '
    mkdir -p /pkg-root/etc/apk/keys
    cp -a /etc/apk/keys/. /pkg-root/etc/apk/keys/
    apk add --root /pkg-root --initdb --no-cache --no-scripts \
      --repositories-file /etc/apk/repositories \
      "ethtool=${ETHTOOL_VERSION}" \
      "rdma-core=${RDMA_CORE_VERSION}" \
      "iproute2-rdma=${IPROUTE2_RDMA_VERSION}"
    rm -rf /pkg-root/dev /pkg-root/proc /pkg-root/sys /pkg-root/run \
           /pkg-root/tmp /pkg-root/var/tmp /pkg-root/var/cache/apk
    find /pkg-root -xdev \( -type f -o -type d \) -perm -0002 -exec chmod o-w {} +
    tar -C /pkg-root -cf /work/hci-tools-rootfs.tar .
  '

tar -C "$SERVICE_ROOT" -xf "$PACKAGE_TAR"

cat > "$SERVICE_DEFS/layersentry-hci-tools.yaml" <<'EOF'
name: layersentry-hci-tools
depends:
  - service: cri
  - network:
      - addresses
      - connectivity
      - hostname
      - etcfiles
container:
  entrypoint: /bin/sleep
  args:
    - infinity
  mounts:
    - source: /dev
      destination: /dev
      type: bind
      options: [rshared, rbind, rw]
    - source: /sys
      destination: /sys
      type: bind
      options: [rbind, rw]
  security:
    maskedPaths: []
    readonlyPaths: []
    writeableRootfs: false
    writeableSysfs: true
restart: always
EOF

cat > "$EXT_ROOT/manifest.yaml" <<EOF
version: v1alpha1
metadata:
  name: layersentry-hci-tools
  version: "${EXTENSION_VERSION}"
  author: LayerSentry
  description: LayerSentry HCI diagnostics toolbox with ethtool and RDMA userspace tools.
  compatibility:
    talos:
      version: ">= v1.13.0"
EOF

ETHTOOL_BIN=$(find "$SERVICE_ROOT" -type f -name ethtool -perm -0100 | head -1)
RDMA_BIN=$(find "$SERVICE_ROOT" -type f -name rdma -perm -0100 | head -1)
IBV_DEVICES_BIN=$(find "$SERVICE_ROOT" -type f -name ibv_devices -perm -0100 | head -1)
IBV_DEVINFO_BIN=$(find "$SERVICE_ROOT" -type f -name ibv_devinfo -perm -0100 | head -1)
test -n "$ETHTOOL_BIN"
test -n "$RDMA_BIN"
test -n "$IBV_DEVICES_BIN"
test -n "$IBV_DEVINFO_BIN"

if find "$EXT_ROOT/rootfs" \( -type b -o -type c -o -type p -o -type s \) -print | grep -q .; then
  echo "ERROR: special file found in LayerSentry HCI tools extension" >&2
  exit 1
fi
if find "$EXT_ROOT/rootfs" \( -type f -o -type d \) -perm -0002 -print | grep -q .; then
  echo "ERROR: world-writable file/directory found in LayerSentry HCI tools extension" >&2
  exit 1
fi

OUT="$OUT_DIR/layersentry-hci-tools.tar"
tar --sort=name --mtime='UTC 2026-08-29' --owner=0 --group=0 --numeric-owner \
  -C "$EXT_ROOT" -cf "$OUT" manifest.yaml rootfs
sha256sum "$OUT" > "$OUT.sha256"
echo "built $OUT"
cat "$OUT.sha256"
