#!/usr/bin/env bash
set -euo pipefail

TALOS_VERSION=${TALOS_VERSION:-v1.13.6}
TALOS_COMMIT=${TALOS_COMMIT:-04318854eb64c90e99308b844b45b26b0077489e}
PKGS_COMMIT=${PKGS_COMMIT:-d8c80cc52d6c60a25c7ab2a80fa78814c08a04da}
LOCAL_REGISTRY=${LOCAL_REGISTRY:-127.0.0.1:5005}
BUILD_TAG=${BUILD_TAG:-v1.13.6-layersentry-iser1}
WORK_DIR=${WORK_DIR:-${RUNNER_TEMP:-/tmp}/layersentry-talos-build}

PKGS_DIR="$WORK_DIR/pkgs"
TALOS_DIR="$WORK_DIR/talos"
PKG_KERNEL_IMAGE="${LOCAL_REGISTRY}/layersentry/pkgs/kernel:${BUILD_TAG}"
BASE_INSTALLER_IMAGE="${LOCAL_REGISTRY}/layersentry/talos/installer-base:${BUILD_TAG}"
IMAGER_IMAGE="${LOCAL_REGISTRY}/layersentry/talos/imager:${BUILD_TAG}"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

git clone --filter=blob:none https://github.com/siderolabs/pkgs.git "$PKGS_DIR"
git -C "$PKGS_DIR" checkout --detach "$PKGS_COMMIT"
test "$(git -C "$PKGS_DIR" rev-parse HEAD)" = "$PKGS_COMMIT"

CONFIG="$PKGS_DIR/kernel/build/config-amd64"
grep -Fx '# CONFIG_INFINIBAND_ISER is not set' "$CONFIG"
sed -i 's/^# CONFIG_INFINIBAND_ISER is not set$/CONFIG_INFINIBAND_ISER=m/' "$CONFIG"

# Let Kconfig resolve only the dependency closure for the new option, then gate
# the exact storage/virtualization primitives LayerSentry relies on.
make -C "$PKGS_DIR" kernel-olddefconfig PLATFORM=linux/amd64
grep -Fx 'CONFIG_INFINIBAND_ISER=m' "$CONFIG"
for pattern in \
  '^CONFIG_INFINIBAND=y$' \
  '^CONFIG_INFINIBAND_USER_ACCESS=[ym]$' \
  '^CONFIG_INFINIBAND_ADDR_TRANS=y$' \
  '^CONFIG_SCSI_ISCSI_ATTRS=y$' \
  '^CONFIG_ISCSI_TCP=[ym]$' \
  '^CONFIG_NVME_FABRICS=[ym]$' \
  '^CONFIG_NVME_TCP=[ym]$' \
  '^CONFIG_NVME_RDMA=[ym]$' \
  '^CONFIG_NVME_FC=[ym]$' \
  '^CONFIG_PCI_IOV=y$' \
  '^CONFIG_PCI_P2PDMA=y$' \
  '^CONFIG_VFIO_PCI=[ym]$'; do
  grep -Eq "$pattern" "$CONFIG" || { echo "missing kernel gate: $pattern" >&2; exit 1; }
done

make -C "$PKGS_DIR" kernel \
  REGISTRY="${LOCAL_REGISTRY}/layersentry" \
  USERNAME=pkgs \
  TAG="$BUILD_TAG" \
  PUSH=true \
  PLATFORM=linux/amd64

docker pull "$PKG_KERNEL_IMAGE"

git clone --filter=blob:none --branch "$TALOS_VERSION" --depth=1 https://github.com/siderolabs/talos.git "$TALOS_DIR"
test "$(git -C "$TALOS_DIR" rev-parse HEAD)" = "$TALOS_COMMIT"

MODULE_LIST="$TALOS_DIR/hack/modules-amd64.txt"
ISER_MODULE='kernel/drivers/infiniband/ulp/iser/ib_iser.ko'
grep -Fxq "$ISER_MODULE" "$MODULE_LIST" || printf '%s\n' "$ISER_MODULE" >> "$MODULE_LIST"

make -C "$TALOS_DIR" kernel initramfs installer-base imager \
  REGISTRY="${LOCAL_REGISTRY}/layersentry" \
  USERNAME=talos \
  TAG="$BUILD_TAG" \
  PUSH=true \
  PKG_KERNEL="$PKG_KERNEL_IMAGE" \
  PLATFORM=linux/amd64 \
  INSTALLER_ARCH=amd64

docker pull "$BASE_INSTALLER_IMAGE"
docker pull "$IMAGER_IMAGE"

printf '%s\n' "BASE_INSTALLER_IMAGE=$BASE_INSTALLER_IMAGE"
printf '%s\n' "IMAGER_IMAGE=$IMAGER_IMAGE"
