#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-aarch64)"

require_file "${ARM_UEFI_BIOS}" "ARM UEFI firmware"
require_file "${ARM_KERNEL_IMAGE}" "ARM kernel image (vmlinuz)"
require_file "${ARM_INITRD_IMAGE}" "ARM initrd image"
require_file "${ARM_DEBIAN_DISK}" "ARM Debian rootfs disk"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"

exec "${qemu_bin}" \
    -machine virt,gic-version=3 \
    -cpu cortex-a53 -m 512M -smp 2 \
    -bios "${ARM_UEFI_BIOS}" \
    -kernel "${ARM_KERNEL_IMAGE}" \
    -initrd "${ARM_INITRD_IMAGE}" \
    -append "${ARM_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -chardev socket,id=ivshmem_stats,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_stats,vectors="${IVSHMEM_VECTORS}" \
    -chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
    -drive file="${ARM_DEBIAN_DISK}",format=qcow2,if=virtio \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-arm,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
