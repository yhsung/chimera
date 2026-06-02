#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${RISCV_ISO}" "RISC-V installer ISO"

mkdir -p "${RISCV_BOOT_ASSET_DIR}"

bsdtar -xOf "${RISCV_ISO}" boot/vmlinuz-lts > "${RISCV_KERNEL_IMAGE_COMPRESSED}"
gzip -dc "${RISCV_KERNEL_IMAGE_COMPRESSED}" > "${RISCV_KERNEL_IMAGE}"
bsdtar -xOf "${RISCV_ISO}" boot/initramfs-lts > "${RISCV_INITRAMFS_IMAGE}"
bsdtar -xOf "${RISCV_ISO}" boot/grub/grub.cfg > "${RISCV_BOOT_ASSET_DIR}/grub.cfg"

echo "RISCV_KERNEL_IMAGE=${RISCV_KERNEL_IMAGE}"
echo "RISCV_INITRAMFS_IMAGE=${RISCV_INITRAMFS_IMAGE}"
