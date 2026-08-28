#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
SCSI_TGT_VERSION=${SCSI_TGT_VERSION:-1.0.96-r0}
EXTENSION_VERSION=${EXTENSION_VERSION:-1.0.96-r0-layersentry.2}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-iscsi-target"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"
PACKAGE_TAR="$TMPDIR/scsi-tgt-rootfs.tar"

mkdir -p "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

# Build the isolated rootfs *inside* the signed Alpine container. apk --root
# does not automatically inherit the parent image keyring, so seed the target
# root with Alpine's trusted signing keys before resolving v3.22/community.
# Exporting a tar back to the runner also avoids root-owned files in TMPDIR.
docker run --rm \
  -e SCSI_TGT_VERSION="$SCSI_TGT_VERSION" \
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
      "scsi-tgt=${SCSI_TGT_VERSION}"

    # Talos system extensions reject special files and world-writable regular
    # files/directories. apk may create a minimal /dev and cache while
    # initializing an alternate root; neither is needed by this service rootfs.
    rm -rf /pkg-root/dev /pkg-root/proc /pkg-root/sys /pkg-root/run \
           /pkg-root/tmp /pkg-root/var/tmp /pkg-root/var/cache/apk
    find /pkg-root -xdev \( -type f -o -type d \) -perm -0002 -exec chmod o-w {} +

    tar -C /pkg-root -cf /work/scsi-tgt-rootfs.tar .
  '

# Extract as the CI user so the temporary working tree remains removable.
tar -C "$SERVICE_ROOT" -xf "$PACKAGE_TAR"

# The service runs in the host network namespace and receives the host device
# tree so LayerSentry can present file-backed or block-backed LUNs. No target is
# created automatically; target/LUN/ACL lifecycle is owned by the LayerSentry
# storage controller, which prevents an ISO from exposing arbitrary disks.
cat > "$SERVICE_DEFS/layersentry-iscsi-target.yaml" <<'EOF'
name: layersentry-iscsi-target
depends:
  - service: cri
  - network:
      - addresses
      - connectivity
      - hostname
      - etcfiles
container:
  entrypoint: /usr/sbin/tgtd
  args:
    - -f
  mounts:
    - source: /dev
      destination: /dev
      type: bind
      options:
        - rshared
        - rbind
        - rw
    - source: /var/lib/layersentry/iscsi-target
      destination: /var/lib/layersentry/iscsi-target
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
  name: layersentry-iscsi-target
  version: "${EXTENSION_VERSION}"
  author: LayerSentry
  description: |
    LayerSentry userspace iSCSI target service based on scsi-tgt/tgtd.
    Provides tgtd/tgtadm/tgtimg without requiring the Linux LIO target kernel.
  compatibility:
    talos:
      version: ">= v1.13.0"
EOF

# Basic build-time assertions. Talos Imager performs extension validation again
# when the tarball is merged into the initramfs.
test -x "$SERVICE_ROOT/usr/sbin/tgtd"
test -x "$SERVICE_ROOT/usr/sbin/tgtadm"
test -x "$SERVICE_ROOT/usr/sbin/tgtimg"
test -s "$SERVICE_DEFS/layersentry-iscsi-target.yaml"
test -s "$EXT_ROOT/manifest.yaml"

# Fail locally if any prohibited special file or world-writable regular
# file/directory survived cleanup. Symlink mode bits are intentionally ignored.
if find "$EXT_ROOT/rootfs" \( -type b -o -type c -o -type p -o -type s \) -print | grep -q .; then
  echo "ERROR: special file found in LayerSentry iSCSI target extension" >&2
  exit 1
fi
if find "$EXT_ROOT/rootfs" \( -type f -o -type d \) -perm -0002 -print | grep -q .; then
  echo "ERROR: world-writable file/directory found in LayerSentry iSCSI target extension" >&2
  exit 1
fi

OUT="$OUT_DIR/layersentry-iscsi-target.tar"
tar \
  --sort=name \
  --mtime='UTC 2026-08-29' \
  --owner=0 --group=0 --numeric-owner \
  -C "$EXT_ROOT" \
  -cf "$OUT" manifest.yaml rootfs

sha256sum "$OUT" > "$OUT.sha256"
echo "built $OUT"
cat "$OUT.sha256"
