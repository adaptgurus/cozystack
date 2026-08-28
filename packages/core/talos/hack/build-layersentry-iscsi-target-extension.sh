#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
SCSI_TGT_VERSION=${SCSI_TGT_VERSION:-1.0.96-r0}
EXTENSION_VERSION=${EXTENSION_VERSION:-1.0.96-r0-layersentry.1}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

PKG_ROOT="$TMPDIR/pkg-root"
EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-iscsi-target"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"

mkdir -p "$PKG_ROOT" "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

# Build an isolated userspace rootfs for tgtd. Keeping the Alpine filesystem
# below /usr/local/lib/containers/<service> follows the Talos extension-service
# model and avoids overlaying distribution libraries onto the Talos host rootfs.
docker run --rm \
  -e SCSI_TGT_VERSION="$SCSI_TGT_VERSION" \
  -v "$TMPDIR:/work" \
  "$ALPINE_IMAGE" \
  sh -euc '
    apk add \
      --root /work/pkg-root \
      --initdb \
      --no-cache \
      --no-scripts \
      --repositories-file /etc/apk/repositories \
      "scsi-tgt=${SCSI_TGT_VERSION}"
  '

cp -a "$PKG_ROOT"/. "$SERVICE_ROOT"/

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

# Basic build-time assertions. Talos imager performs its own extension
# validation again when the tarball is merged into the initramfs.
test -x "$SERVICE_ROOT/usr/sbin/tgtd"
test -x "$SERVICE_ROOT/usr/sbin/tgtadm"
test -x "$SERVICE_ROOT/usr/sbin/tgtimg"
test -s "$SERVICE_DEFS/layersentry-iscsi-target.yaml"
test -s "$EXT_ROOT/manifest.yaml"

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
