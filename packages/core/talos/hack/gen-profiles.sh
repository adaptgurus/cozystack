#!/bin/sh
set -e
set -u

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

PROFILES="initramfs kernel iso installer nocloud metal"
EMBEDDED_CONFIG="layersentry-hci-machine-config.yaml"
LOCAL_ISCSI_TARGET_TARBALL="/extensions/layersentry-iscsi-target.tar"
LOCAL_NFS_SERVER_TARBALL="/extensions/layersentry-nfs-server.tar"

# Firmware already carried by the Cozystack Talos image. Keep this list broad
# enough for the common bare-metal NIC/GPU/storage platforms we support.
FIRMWARES="amd-ucode amdgpu bnx2-bnx2x i915 intel-ice-firmware intel-ucode qlogic-firmware"

# LayerSentry HCI host extensions.
#
# These are deliberately baked into every LayerSentry Talos boot asset so a
# node has the host-side tooling required by storage/network controllers from
# first boot. Hardware-specific kernel capabilities (SR-IOV, VFIO, RDMA/RoCE,
# NVMe/RDMA, NVMe/FC and NVMe/TCP) are provided by the Talos kernel and matching
# device drivers; these extensions add the userspace/service pieces where Talos
# publishes one.
#
# nfsd is the Sidero extension that supplies the Talos-version-matched NFSD
# kernel module. nfs-utils supplies client/NFSv3 helper components. The complete
# server userspace is carried in the LayerSentry nfs-server extension below.
#
# trident-iscsi-tools is intentionally included even when NetApp Trident is not
# installed: Sidero's extension is the supported catalog image that provides
# lsscsi on Talos v1.13.x.
HCI_EXTENSIONS="\
iscsi-tools \
multipath-tools \
nfsd \
nfs-utils \
nfsrahead \
nvme-cli \
lldpd \
trident-iscsi-tools \
util-linux-tools"

# GPU/RDMA-capable nodes use the same ISO. The open NVIDIA production driver
# and CDI/container runtime integration make host GPU workloads possible, while
# a PCIDriverRebindConfig can still bind selected devices to vfio-pci for
# KubeVirt passthrough. nvidia-gdrdrv-device supplies the catalog GPUDirect RDMA
# device support. Actual GPUDirect operation still requires compatible NVIDIA
# GPUs, RDMA NICs, IOMMU/topology and Kubernetes GPU/RDMA operators.
GPU_EXTENSIONS="\
nvidia-open-gpu-kernel-modules-production \
nvidia-container-toolkit-production \
nvidia-gdrdrv-device"

EXTENSIONS="drbd zfs $HCI_EXTENSIONS $GPU_EXTENSIONS"

mkdir -p images/talos/profiles

test -s "$EMBEDDED_CONFIG"
embedded_config_yaml=$(sed 's/^/    /' "$EMBEDDED_CONFIG")

printf "fetching talos version: "
talos_version=${1:-$(skopeo --override-os linux --override-arch amd64 list-tags docker://ghcr.io/siderolabs/imager | jq -r '.Tags[]' | grep '^v[0-9]\+.[0-9]\+.[0-9]\+$' | sort -V | tail -n 1)}
echo "$talos_version"

export TALOS_VERSION="$talos_version"
CATALOG_IMAGE="ghcr.io/siderolabs/extensions:${TALOS_VERSION}"
CATALOG_DIGESTS="$TMPDIR/image-digests"

# crane is convenient for developer workstations, but release builders already
# guarantee Docker. Keep a Docker fallback so normal Cozystack image/release
# builds do not gain a new mandatory host dependency.
if command -v crane >/dev/null 2>&1; then
  crane export "$CATALOG_IMAGE" | tar x -O image-digests > "$CATALOG_DIGESTS"
else
  docker pull "$CATALOG_IMAGE" >/dev/null
  catalog_container=$(docker create "$CATALOG_IMAGE" /bin/true)
  trap 'docker rm -f "$catalog_container" >/dev/null 2>&1 || true; rm -rf "$TMPDIR"' EXIT INT TERM
  docker export "$catalog_container" | tar x -O image-digests > "$CATALOG_DIGESTS"
  docker rm "$catalog_container" >/dev/null
  trap 'rm -rf "$TMPDIR"' EXIT INT TERM
fi

IMAGE_REFS="$TMPDIR/image-refs"
: > "$IMAGE_REFS"

resolve_image() {
  extension_name=$1
  image=$(grep -F "/${extension_name}:" "$CATALOG_DIGESTS" | head -n 1 || true)
  if [ -z "$image" ]; then
    echo "ERROR: Talos ${TALOS_VERSION} extension '${extension_name}' is not present in ${CATALOG_IMAGE}" >&2
    exit 1
  fi
  printf "fetching %s version: %s\n" "$extension_name" "$image" >&2
  printf "%s\n" "$image"
}

for extension in $FIRMWARES $EXTENSIONS; do
  resolve_image "$extension" >> "$IMAGE_REFS"
done

for profile in $PROFILES; do
  echo "writing profile images/talos/profiles/$profile.yaml"
  case "$profile" in
    initramfs|iso)
      image_options="{}"
      out_format="raw"
      platform="metal"
      kind="$profile"
      ;;
    kernel)
      image_options="{}"
      out_format="raw"
      platform="metal"
      kind="$profile"
      ;;
    installer)
      image_options="{}"
      out_format="raw"
      platform="metal"
      kind="installer"
      ;;
    metal)
      image_options="{ diskSize: 1306525696, diskFormat: raw }"
      out_format=".xz"
      platform="metal"
      kind="image"
      ;;
    nocloud)
      image_options="{ diskSize: 1306525696, diskFormat: raw }"
      out_format=".xz"
      platform="nocloud"
      kind="image"
      ;;
    *)
      echo "Unknown profile: $profile" >&2
      exit 1
      ;;
  esac

  extension_yaml=$(sed 's/^/    - imageRef: /' "$IMAGE_REFS")
  # LayerSentry-specific server extensions are built locally as validated Talos
  # extension tarballs and mounted into imager at /extensions.
  extension_yaml="${extension_yaml}
    - tarballPath: ${LOCAL_ISCSI_TARGET_TARBALL}
    - tarballPath: ${LOCAL_NFS_SERVER_TARBALL}"

  # Embedded configuration is a virtual system extension. Include it in every
  # boot/install asset that carries an initramfs so multipath and NFSD kernel
  # modules, multipathd defaults, and LayerSentry's host-ingress accept policy
  # are active from first boot. A kernel-only artifact cannot carry config.
  if [ "$profile" = "kernel" ]; then
    customization_yaml=""
  else
    customization_yaml="customization:
  embeddedMachineConfiguration: |
$embedded_config_yaml"
  fi

  cat > images/talos/profiles/$profile.yaml <<EOT
# this file generated by hack/gen-profiles.sh
# do not edit it
arch: amd64
platform: ${platform}
secureboot: false
version: ${TALOS_VERSION}
${customization_yaml}
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: "ghcr.io/siderolabs/installer:${TALOS_VERSION}"
  systemExtensions:
${extension_yaml}
output:
  kind: ${kind}
  imageOptions: ${image_options}
  outFormat: ${out_format}
EOT
done
