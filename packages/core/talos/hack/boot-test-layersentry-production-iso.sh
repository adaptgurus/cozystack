#!/usr/bin/env bash
set -euo pipefail

ISO=${1:?usage: $0 <iso> <installer-tar>}
INSTALLER_TAR=${2:?usage: $0 <iso> <installer-tar>}
TALOSCTL=${TALOSCTL:-/tmp/talosctl}
BUILD_TAG=${BUILD_TAG:-v1.13.6-layersentry-prod1}
LOCAL_REGISTRY=${LOCAL_REGISTRY:-127.0.0.1:5005}
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
EVIDENCE="$ROOT/_out/evidence"
mkdir -p "$EVIDENCE"

test -s "$ISO"
test -s "$INSTALLER_TAR"
command -v qemu-system-x86_64 >/dev/null
command -v qemu-img >/dev/null
test -x "$TALOSCTL"

wait_insecure() {
  out=$1
  for _ in $(seq 1 180); do
    if "$TALOSCTL" --nodes 127.0.0.1 --endpoints 127.0.0.1 --insecure version >"$out" 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_secure() {
  config=$1
  out=$2
  for _ in $(seq 1 240); do
    if "$TALOSCTL" --talosconfig "$config" --nodes 127.0.0.1 --endpoints 127.0.0.1 version >"$out" 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

kill_vm() {
  pid=${1:-}
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

BIOS_SERIAL="$EVIDENCE/bios-serial.log"
qemu-system-x86_64 \
  -machine q35,accel=tcg -cpu max -m 3072 -smp 2 \
  -boot d -cdrom "$ISO" -display none -serial "file:${BIOS_SERIAL}" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:50000-:50000 \
  -device virtio-net-pci,netdev=net0 \
  >"$EVIDENCE/bios-qemu.out" 2>"$EVIDENCE/bios-qemu.err" &
BIOS_PID=$!
trap 'kill_vm "${BIOS_PID:-}"; kill_vm "${UEFI_PID:-}"' EXIT
if ! wait_insecure "$EVIDENCE/bios-talos-version.txt"; then
  tail -200 "$BIOS_SERIAL" || true
  exit 1
fi
kill_vm "$BIOS_PID"
BIOS_PID=

LOAD_OUT="$EVIDENCE/docker-load-installer.txt"
docker load -i "$INSTALLER_TAR" | tee "$LOAD_OUT"
LOADED=$(sed -n 's/^Loaded image: //p' "$LOAD_OUT" | tail -1)
if [ -z "$LOADED" ]; then
  LOADED=$(sed -n 's/^Loaded image ID: //p' "$LOAD_OUT" | tail -1)
fi
test -n "$LOADED"
LOCAL_INSTALLER="${LOCAL_REGISTRY}/layersentry/installer:${BUILD_TAG}"
docker tag "$LOADED" "$LOCAL_INSTALLER"
docker push "$LOCAL_INSTALLER"

OVMF_CODE=$(find /usr/share/OVMF -maxdepth 1 -type f \( -name 'OVMF_CODE.fd' -o -name 'OVMF_CODE_4M.fd' \) | sort | head -1)
test -n "$OVMF_CODE"
case "$OVMF_CODE" in
  *_4M.fd) OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd ;;
  *) OVMF_VARS=/usr/share/OVMF/OVMF_VARS.fd ;;
esac
test -s "$OVMF_VARS"
VARS="$EVIDENCE/OVMF_VARS.fd"
cp "$OVMF_VARS" "$VARS"
DISK="$EVIDENCE/layersentry-installed.qcow2"
qemu-img create -f qcow2 "$DISK" 12G

start_uefi() {
  with_iso=$1
  serial=$2
  args=(
    -machine q35,accel=tcg -cpu max -m 4096 -smp 2
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,unit=1,file=${VARS}"
    -drive "file=${DISK},if=virtio,format=qcow2"
    -display none -serial "file:${serial}"
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:50000-:50000
    -device virtio-net-pci,netdev=net0
  )
  if [ "$with_iso" = yes ]; then
    args+=( -boot order=cd,once=d -cdrom "$ISO" )
  else
    args+=( -boot c )
  fi
  qemu-system-x86_64 "${args[@]}" >"${serial}.out" 2>"${serial}.err" &
  UEFI_PID=$!
}

UEFI_SERIAL="$EVIDENCE/uefi-install-serial.log"
start_uefi yes "$UEFI_SERIAL"
if ! wait_insecure "$EVIDENCE/uefi-maintenance-version.txt"; then
  tail -200 "$UEFI_SERIAL" || true
  exit 1
fi

CFG="$EVIDENCE/talos-config"
mkdir -p "$CFG"
"$TALOSCTL" gen config layersentry-ci https://10.0.2.15:6443 \
  --output-dir "$CFG" --install-disk /dev/vda \
  --install-image "registry.layersentry.invalid/layersentry/installer:${BUILD_TAG}"

python3 - "$CFG/controlplane.yaml" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
needle='machine:\n'
insert='machine:\n  kernel:\n    modules:\n      - name: dm_multipath\n      - name: dm-round-robin\n      - name: drbd\n      - name: zfs\n      - name: nfsd\n      - name: ib_iser\n'
if needle not in s:
    raise SystemExit('machine root not found in generated config')
s=s.replace(needle, insert, 1)
open(p,'w').write(s)
PY

awk 'f{print} /^---$/{f=1; print}' "$ROOT/packages/core/talos/layersentry-hci-machine-config.yaml" >> "$CFG/controlplane.yaml"
cat >> "$CFG/controlplane.yaml" <<'EOF'
---
apiVersion: v1alpha1
kind: RegistryMirrorConfig
name: registry.layersentry.invalid
endpoints:
  - url: http://10.0.2.2:5005
EOF

"$TALOSCTL" --nodes 127.0.0.1 --endpoints 127.0.0.1 --insecure \
  apply-config --file "$CFG/controlplane.yaml"

if ! wait_secure "$CFG/talosconfig" "$EVIDENCE/post-install-version.txt"; then
  tail -250 "$UEFI_SERIAL" || true
  exit 1
fi
kill_vm "$UEFI_PID"
UEFI_PID=
sleep 2

DISK_SERIAL="$EVIDENCE/uefi-disk-only-serial.log"
start_uefi no "$DISK_SERIAL"
if ! wait_secure "$CFG/talosconfig" "$EVIDENCE/disk-only-version.txt"; then
  tail -250 "$DISK_SERIAL" || true
  exit 1
fi
TC=("$TALOSCTL" --talosconfig "$CFG/talosconfig" --nodes 127.0.0.1 --endpoints 127.0.0.1)
"${TC[@]}" ls /sys/firmware/efi > "$EVIDENCE/efi.txt"
"${TC[@]}" read /proc/config.gz > "$EVIDENCE/config.gz"
"${TC[@]}" read /proc/modules > "$EVIDENCE/modules.txt"
"${TC[@]}" get extensions -o yaml > "$EVIDENCE/extensions.yaml"
"${TC[@]}" services > "$EVIDENCE/services.txt"
"${TC[@]}" read /proc/net/tcp > "$EVIDENCE/tcp.txt"
"${TC[@]}" read /proc/net/tcp6 > "$EVIDENCE/tcp6.txt"

for gate in \
  'CONFIG_INFINIBAND_ISER=m' 'CONFIG_NFS_V3=y' 'CONFIG_NFS_V4=y' \
  'CONFIG_NFS_V4_1=y' 'CONFIG_NFS_V4_2=y' 'CONFIG_NVME_TCP=y' \
  'CONFIG_NVME_RDMA=m' 'CONFIG_NVME_FC=y' 'CONFIG_SCSI_QLA_FC=m' \
  'CONFIG_SCSI_LPFC=m' 'CONFIG_PCI_IOV=y' 'CONFIG_INTEL_IOMMU=y' \
  'CONFIG_AMD_IOMMU=y'; do
  zgrep -Fx "$gate" "$EVIDENCE/config.gz"
done
zgrep -Eq '^CONFIG_VFIO_PCI=[ym]$' "$EVIDENCE/config.gz"

for module in dm_multipath drbd zfs nfsd ib_iser; do
  grep -Eq "^${module} " "$EVIDENCE/modules.txt" || {
    echo "required installed-node module is not loaded: ${module}" >&2
    cat "$EVIDENCE/modules.txt" >&2
    exit 1
  }
done

EXPECTED_EXTENSIONS="amd-ucode intel-ice-firmware intel-ucode qlogic-firmware iscsi-tools multipath-tools nfs-utils nfsrahead nvme-cli lldpd trident-iscsi-tools util-linux-tools nvidia-container-toolkit-production amdgpu bnx2-bnx2x i915 drbd zfs nfsd nvidia-open-gpu-kernel-modules-production nvidia-gdrdrv-device layersentry-iscsi-target layersentry-nfs-server layersentry-hci-tools"
for extension in $EXPECTED_EXTENSIONS; do
  grep -Fq "$extension" "$EVIDENCE/extensions.yaml" || {
    echo "installed node is missing extension: $extension" >&2
    exit 1
  }
done

! grep -Fq 'ext-zfs-service' "$EVIDENCE/services.txt"
cat "$EVIDENCE/tcp.txt" "$EVIDENCE/tcp6.txt" | awk '
  $4=="0A" && $2 ~ /:(006F|0801|0CBC|4E50)$/ {print; bad=1}
  END {exit bad}
' || {
  echo 'generic installed node unexpectedly exposes NFS/RPC/iSCSI target listener' >&2
  exit 1
}

printf '%s\n' 'LayerSentry BIOS boot + UEFI install + disk-only reboot validation: PASS'
