#!/usr/bin/env bash
set -euo pipefail

TALOS_VERSION=${TALOS_VERSION:-v1.13.6}
TALOS_COMMIT=${TALOS_COMMIT:-04318854eb64c90e99308b844b45b26b0077489e}
PKGS_COMMIT=${PKGS_COMMIT:-d8c80cc52d6c60a25c7ab2a80fa78814c08a04da}
LOCAL_REGISTRY=${LOCAL_REGISTRY:-127.0.0.1:5005}
BUILD_TAG=${BUILD_TAG:-v1.13.6-layersentry-prod1}
WORK_DIR=${WORK_DIR:-${RUNNER_TEMP:-/tmp}/layersentry-talos-build}

PKGS_DIR="$WORK_DIR/pkgs"
TALOS_DIR="$WORK_DIR/talos"
PKGS_PREFIX="${LOCAL_REGISTRY}/layersentry/pkgs"
PKG_KERNEL_IMAGE="${PKGS_PREFIX}/kernel:${BUILD_TAG}"
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

# Resolve only the dependency closure for iSER and then fail the build if any
# universal HCI/dHCI/SAN primitive disappears from the exact Talos kernel.
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
  '^CONFIG_NFS_FS=y$' \
  '^CONFIG_NFS_V3=y$' \
  '^CONFIG_NFS_V4=y$' \
  '^CONFIG_NFS_V4_1=y$' \
  '^CONFIG_NFS_V4_2=y$' \
  '^CONFIG_NFSD=[ym]$' \
  '^CONFIG_SCSI_QLA_FC=[ym]$' \
  '^CONFIG_SCSI_LPFC=[ym]$' \
  '^CONFIG_DM_MULTIPATH=[ym]$' \
  '^CONFIG_BRIDGE=y$' \
  '^CONFIG_BRIDGE_VLAN_FILTERING=y$' \
  '^CONFIG_BONDING=y$' \
  '^CONFIG_VLAN_8021Q=y$' \
  '^CONFIG_NF_CONNTRACK=y$' \
  '^CONFIG_PCI_IOV=y$' \
  '^CONFIG_PCI_P2PDMA=y$' \
  '^CONFIG_VFIO_PCI=[ym]$' \
  '^CONFIG_INTEL_IOMMU=y$' \
  '^CONFIG_AMD_IOMMU=y$'; do
  grep -Eq "$pattern" "$CONFIG" || { echo "missing kernel gate: $pattern" >&2; exit 1; }
done

# Talos signs loadable modules with the kernel build key. Build every external
# module package that LayerSentry extensions consume from this same custom pkgs
# tree so DRBD/ZFS/NVIDIA cannot silently carry stock-kernel signatures/CRCs.
make -C "$PKGS_DIR" \
  kernel drbd-pkg zfs-pkg nvidia-open-gpu-kernel-modules-production-pkg \
  REGISTRY="$LOCAL_REGISTRY" \
  USERNAME=layersentry/pkgs \
  TAG="$BUILD_TAG" \
  PUSH=true \
  PLATFORM=linux/amd64

docker pull "$PKG_KERNEL_IMAGE"

git clone --filter=blob:none --branch "$TALOS_VERSION" --depth=1 https://github.com/siderolabs/talos.git "$TALOS_DIR"
test "$(git -C "$TALOS_DIR" rev-parse HEAD)" = "$TALOS_COMMIT"

MODULE_LIST="$TALOS_DIR/hack/modules-amd64.txt"
ISER_MODULE='kernel/drivers/infiniband/ulp/iser/ib_iser.ko'
grep -Fxq "$ISER_MODULE" "$MODULE_LIST" || printf '%s\n' "$ISER_MODULE" >> "$MODULE_LIST"

# FC, RDMA, NVMe-oF and VFIO modules are expected to remain in the Talos
# initramfs allow-list. Treat their disappearance as a release-breaking change.
for module in \
  kernel/drivers/infiniband/core/ib_uverbs.ko \
  kernel/drivers/infiniband/core/rdma_ucm.ko \
  kernel/drivers/infiniband/hw/bnxt_re/bnxt_re.ko \
  kernel/drivers/infiniband/hw/irdma/irdma.ko \
  kernel/drivers/infiniband/hw/mlx4/mlx4_ib.ko \
  kernel/drivers/infiniband/hw/mlx5/mlx5_ib.ko \
  kernel/drivers/nvme/host/nvme-rdma.ko \
  kernel/drivers/scsi/lpfc/lpfc.ko \
  kernel/drivers/scsi/qla2xxx/qla2xxx.ko \
  kernel/drivers/vfio/pci/vfio-pci.ko; do
  grep -Fxq "$module" "$MODULE_LIST" || {
    echo "required Talos module allow-list entry missing: $module" >&2
    exit 1
  }
done

make -C "$TALOS_DIR" kernel initramfs installer-base imager \
  REGISTRY="$LOCAL_REGISTRY" \
  USERNAME=layersentry/talos \
  TAG="$BUILD_TAG" \
  PUSH=true \
  PKG_KERNEL="$PKG_KERNEL_IMAGE" \
  PLATFORM=linux/amd64 \
  INSTALLER_ARCH=amd64

docker pull "$BASE_INSTALLER_IMAGE"
docker pull "$IMAGER_IMAGE"

printf '%s\n' "PKGS_PREFIX=$PKGS_PREFIX"
printf '%s\n' "BASE_INSTALLER_IMAGE=$BASE_INSTALLER_IMAGE"
printf '%s\n' "IMAGER_IMAGE=$IMAGER_IMAGE"
