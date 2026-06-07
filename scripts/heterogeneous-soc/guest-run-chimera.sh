#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-mipsel)"

require_file "${MIPS_KERNEL_IMAGE}" "MIPS kernel image (vmlinuz)"
require_file "${MIPS_INITRD_IMAGE}" "MIPS initrd image"
require_file "${MIPS_DEBIAN_DISK}" "MIPS Debian rootfs disk"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"

exec "${qemu_bin}" \
    -machine malta \
    -cpu 24Kf \
    -m 512M \
    -kernel "${MIPS_KERNEL_IMAGE}" \
    -initrd "${MIPS_INITRD_IMAGE}" \
    -append "${MIPS_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
    -drive file="${MIPS_DEBIAN_DISK}",format=qcow2,if=ide \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-mips,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0 \
    -nographic
