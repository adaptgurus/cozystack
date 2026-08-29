#!/usr/bin/env bash
set -euo pipefail

TALOS_VERSION=${TALOS_VERSION:-v1.13.6}
LOCAL_REGISTRY=${LOCAL_REGISTRY:-127.0.0.1:5005}
BUILD_TAG=${BUILD_TAG:-v1.13.6-layersentry-prod1}
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
TALOS_DIR="$ROOT/packages/core/talos"
EXT_DIR="$ROOT/_out/extensions"
PROFILE="$TALOS_DIR/images/talos/profiles/iso.yaml"
INSTALLER_PROFILE="$TALOS_DIR/images/talos/profiles/installer.yaml"
MACHINE="$TALOS_DIR/layersentry-hci-machine-config.yaml"
CILIUM="$ROOT/packages/system/cilium/values.yaml"

for f in "$PROFILE" "$INSTALLER_PROFILE" "$MACHINE" "$CILIUM"; do test -s "$f"; done
for p in "$PROFILE" "$INSTALLER_PROFILE"; do
  grep -Fq "version: ${TALOS_VERSION}" "$p"
  grep -Fq "imageRef: ${LOCAL_REGISTRY}/layersentry/talos/installer-base:${BUILD_TAG}" "$p"
  awk '/systemExtensions:/{on=1;next} on && /imageRef:/{print $3} on && /^customization:/{exit}' "$p" | while read -r ref; do
    printf '%s\n' "$ref" | grep -Fq '@sha256:' || {
      echo "official extension is not digest pinned: $ref" >&2
      exit 1
    }
  done

done

OFFICIAL="amd-ucode intel-ice-firmware intel-ucode qlogic-firmware iscsi-tools multipath-tools nfs-utils nfsrahead nvme-cli lldpd trident-iscsi-tools util-linux-tools nvidia-container-toolkit-production"
for e in $OFFICIAL; do grep -Fq "/${e}:" "$PROFILE"; done

KERNEL="amdgpu bnx2-bnx2x i915 drbd zfs nfsd nvidia-open-gpu-kernel-modules-production nvidia-gdrdrv-device"
for e in $KERNEL; do
  tarball="$EXT_DIR/layersentry-${e}.tar"
  test -s "$tarball"
  grep -Fq "tarballPath: /extensions/layersentry-${e}.tar" "$PROFILE"
done

for e in layersentry-iscsi-target layersentry-nfs-server layersentry-hci-tools; do
  test -s "$EXT_DIR/${e}.tar"
  test -s "$EXT_DIR/${e}.sbom.spdx.json"
  grep -Fq "tarballPath: /extensions/${e}.tar" "$PROFILE"
done

test -s "$EXT_DIR/layersentry-kernel-extensions.sha256"
(cd "$EXT_DIR" && sha256sum -c layersentry-kernel-extensions.sha256)

# Universal storage image safety: the ZFS capability may exist, but its upstream
# force-import service must never exist in the final extension.
if tar -tf "$EXT_DIR/layersentry-zfs.tar" | grep -Fq 'rootfs/usr/local/etc/containers/zfs-service.yaml'; then
  echo 'unsafe ZFS automatic import service present' >&2
  exit 1
fi
tar -tf "$EXT_DIR/layersentry-zfs.tar" | grep -Fq 'rootfs/usr/local/share/layersentry/storage-ownership-policy.txt'

# Required userspace is present in the selected extensions.
tar -tf "$EXT_DIR/layersentry-iscsi-target.tar" | grep -E '/tgtd$' >/dev/null
tar -tf "$EXT_DIR/layersentry-iscsi-target.tar" | grep -E '/tgtadm$' >/dev/null
tar -tf "$EXT_DIR/layersentry-nfs-server.tar" | grep -E '/rpc\.nfsd$' >/dev/null
tar -tf "$EXT_DIR/layersentry-nfs-server.tar" | grep -E '/rpc\.mountd$' >/dev/null
tar -tf "$EXT_DIR/layersentry-nfs-server.tar" | grep -E '/exportfs$' >/dev/null
for b in ethtool rdma ibv_devices ibv_devinfo; do tar -tf "$EXT_DIR/layersentry-hci-tools.tar" | grep -E "/${b}$" >/dev/null; done

# The generic ISO must not hard-code an open host firewall or a universal SAN
# path selector. Stable WWID/WWN/NQN identity remains explicit policy.
! grep -Fq 'kind: NetworkDefaultActionConfig' "$MACHINE"
! grep -Fq 'path_selector "round-robin 0"' "$MACHINE"
grep -Fq 'find_multipaths yes' "$MACHINE"
grep -Fq 'user_friendly_names no' "$MACHINE"
for m in dm_multipath drbd zfs nfsd ib_iser; do grep -Fq "name: ${m}" "$MACHINE"; done

# Cilium is the normal Kubernetes datapath; netfilter/conntrack can remain only
# as kernel compatibility substrate.
grep -Fq 'kubeProxyReplacement: true' "$CILIUM"
grep -Fq 'masquerade: true' "$CILIUM"
grep -Fq 'hostLegacyRouting: false' "$CILIUM"
grep -Fq 'hostFirewall:' "$CILIUM"
grep -Fq 'enabled: true' "$CILIUM"

# Detect accidental duplicate non-directory paths across all LayerSentry-local
# tarballs. The Talos imager performs the authoritative full extension merge
# validation, including official digest-pinned extensions.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for t in "$EXT_DIR"/layersentry-*.tar; do
  tar -tf "$t" | sed 's#^\./##' | grep -v '/$' | grep -v '^manifest.yaml$' >> "$tmp"
done
if sort "$tmp" | uniq -d | grep -q .; then
  echo 'duplicate file paths across LayerSentry-local extensions:' >&2
  sort "$tmp" | uniq -d >&2
  exit 1
fi

printf '%s\n' 'LayerSentry production profile validation: PASS'
