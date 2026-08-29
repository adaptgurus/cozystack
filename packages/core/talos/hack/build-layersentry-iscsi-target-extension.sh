#!/bin/sh
set -eu

OUT_DIR=${1:-../../../_out/extensions}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22@sha256:55ae5d250caebc548793f321534bc6a8ef1d116f334f18f4ada1b2daad3251b2}
SCSI_TGT_VERSION=${SCSI_TGT_VERSION:-1.0.96-r0}
EXTENSION_VERSION=${EXTENSION_VERSION:-1.0.96-r0-layersentry.3}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

EXT_ROOT="$TMPDIR/extension"
SERVICE_ROOT="$EXT_ROOT/rootfs/usr/local/lib/containers/layersentry-iscsi-target"
SERVICE_DEFS="$EXT_ROOT/rootfs/usr/local/etc/containers"
PACKAGE_TAR="$TMPDIR/scsi-tgt-rootfs.tar"

mkdir -p "$SERVICE_ROOT" "$SERVICE_DEFS" "$OUT_DIR"

docker run --rm \
  -e SCSI_TGT_VERSION="$SCSI_TGT_VERSION" \
  -v "$TMPDIR:/work" \
  "$ALPINE_IMAGE" \
  sh -euc '
    mkdir -p /pkg-root/etc/apk/keys
    cp -a /etc/apk/keys/. /pkg-root/etc/apk/keys/
    apk add --root /pkg-root --initdb --no-cache --no-scripts \
      --repositories-file /etc/apk/repositories \
      busybox "scsi-tgt=${SCSI_TGT_VERSION}"
    rm -rf /pkg-root/dev /pkg-root/proc /pkg-root/sys /pkg-root/run \
           /pkg-root/tmp /pkg-root/var/tmp /pkg-root/var/cache/apk
    find /pkg-root -xdev \( -type f -o -type d \) -perm -0002 -exec chmod o-w {} +
    tar -C /pkg-root -cf /work/scsi-tgt-rootfs.tar .
  '

tar -C "$SERVICE_ROOT" -xf "$PACKAGE_TAR"
mkdir -p "$SERVICE_ROOT/usr/local/sbin"

# Universal-image safety: capability is installed, but the target daemon does
# not start listening until the LayerSentry storage controller creates the
# controller-owned enable marker. No LUN, ACL or backing device is auto-created.
cat > "$SERVICE_ROOT/usr/local/sbin/layersentry-iscsi-target" <<'EOF'
#!/bin/sh
set -eu
STATE=/var/lib/layersentry/iscsi-target
mkdir -p "$STATE"
while [ ! -f "$STATE/enabled" ]; do
  sleep 2
done
exec /usr/sbin/tgtd -f
EOF
chmod 0755 "$SERVICE_ROOT/usr/local/sbin/layersentry-iscsi-target"

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
  entrypoint: /usr/local/sbin/layersentry-iscsi-target
  mounts:
    - source: /dev
      destination: /dev
      type: bind
      options: [rshared, rbind, rw]
    - source: /var/lib/layersentry/iscsi-target
      destination: /var/lib/layersentry/iscsi-target
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
  name: layersentry-iscsi-target
  version: "${EXTENSION_VERSION}"
  author: LayerSentry
  description: |
    Controller-activated userspace iSCSI target based on scsi-tgt/tgtd.
    The daemon remains dormant until LayerSentry explicitly enables it; no
    target, LUN, ACL or backing device is implicitly created by image boot.
  compatibility:
    talos:
      version: ">= v1.13.0"
EOF

cat > "$OUT_DIR/layersentry-iscsi-target.sbom.spdx.json" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "layersentry-iscsi-target-${EXTENSION_VERSION}",
  "documentNamespace": "https://layersentry.invalid/sbom/iscsi-target/${EXTENSION_VERSION}",
  "creationInfo": {"created": "2026-08-30T00:00:00Z", "creators": ["Organization: LayerSentry"]},
  "packages": [
    {"name": "scsi-tgt", "SPDXID": "SPDXRef-scsi-tgt", "versionInfo": "${SCSI_TGT_VERSION}", "downloadLocation": "NOASSERTION", "filesAnalyzed": false},
    {"name": "alpine-base", "SPDXID": "SPDXRef-alpine", "versionInfo": "3.22", "downloadLocation": "NOASSERTION", "filesAnalyzed": false}
  ]
}
EOF

test -x "$SERVICE_ROOT/usr/sbin/tgtd"
test -x "$SERVICE_ROOT/usr/sbin/tgtadm"
test -x "$SERVICE_ROOT/usr/sbin/tgtimg"
test -x "$SERVICE_ROOT/usr/local/sbin/layersentry-iscsi-target"
test -s "$SERVICE_DEFS/layersentry-iscsi-target.yaml"
test -s "$EXT_ROOT/manifest.yaml"
test -s "$OUT_DIR/layersentry-iscsi-target.sbom.spdx.json"
grep -Fq 'while [ ! -f "$STATE/enabled" ]' "$SERVICE_ROOT/usr/local/sbin/layersentry-iscsi-target"

if find "$EXT_ROOT/rootfs" \( -type b -o -type c -o -type p -o -type s \) -print | grep -q .; then
  echo "ERROR: special file found in LayerSentry iSCSI target extension" >&2
  exit 1
fi
if find "$EXT_ROOT/rootfs" \( -type f -o -type d \) -perm -0002 -print | grep -q .; then
  echo "ERROR: world-writable file/directory found in LayerSentry iSCSI target extension" >&2
  exit 1
fi

OUT="$OUT_DIR/layersentry-iscsi-target.tar"
tar --sort=name --mtime='UTC 2026-08-30' --owner=0 --group=0 --numeric-owner \
  -C "$EXT_ROOT" -cf "$OUT" manifest.yaml rootfs
sha256sum "$OUT" > "$OUT.sha256"
echo "built $OUT"
cat "$OUT.sha256"
