#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${ARM_ISO}" "ARM installer image"

mkdir -p "${ARM_BOOT_ASSET_DIR}"

bsdtar -xOf "${ARM_ISO}" boot/vmlinuz-virt > "${ARM_KERNEL_IMAGE}"
bsdtar -xOf "${ARM_ISO}" boot/initramfs-virt > "${ARM_INITRAMFS_IMAGE}"
bsdtar -xOf "${ARM_ISO}" boot/modloop-virt > "${ARM_MODLOOP_IMAGE}"
bsdtar -xOf "${ARM_ISO}" boot/grub/grub.cfg > "${ARM_BOOT_ASSET_DIR}/grub.cfg"

echo "ARM_KERNEL_IMAGE=${ARM_KERNEL_IMAGE}"
echo "ARM_INITRAMFS_IMAGE=${ARM_INITRAMFS_IMAGE}"
echo "ARM_MODLOOP_IMAGE=${ARM_MODLOOP_IMAGE}"
