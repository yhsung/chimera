#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-aarch64)"

require_file "${ARM_ISO}" "ARM installer ISO"
require_file "${ARM_UEFI_BIOS}" "ARM UEFI firmware"
require_file "${ARM_KERNEL_IMAGE}" "ARM kernel image"
require_file "${ARM_INITRAMFS_COMBINED}" "ARM combined initramfs image"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/prepare-arm-phase2-boot-assets.sh"
bash "${SCRIPT_DIR}/prepare-demo-guest-overlays.sh"

exec "${qemu_bin}" \
    -machine virt,gic-version=3 \
    -cpu cortex-a57 -m 512M -smp 2 \
    -bios "${ARM_UEFI_BIOS}" \
    -kernel "${ARM_KERNEL_IMAGE}" \
    -initrd "${ARM_INITRAMFS_COMBINED}" \
    -append "${ARM_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${ARM_ISO}",media=cdrom \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
