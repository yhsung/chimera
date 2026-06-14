#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${MIPS_ISO}" "MIPS installer ISO"

mkdir -p "${MIPS_BOOT_ASSET_DIR}"

# Alpine 3.10 mips standard ISO has vmlinuz-vanilla and initramfs-vanilla.
# If the filenames differ in the ISO, set MIPS_KERNEL_BASENAME and
# MIPS_INITRAMFS_BASENAME in the environment before calling this script.
KERNEL_BASENAME="${MIPS_KERNEL_BASENAME:-vmlinuz-vanilla}"
INITRAMFS_BASENAME="${MIPS_INITRAMFS_BASENAME:-initramfs-vanilla}"

bsdtar -xOf "${MIPS_ISO}" "boot/${KERNEL_BASENAME}"     > "${MIPS_KERNEL_IMAGE}"
bsdtar -xOf "${MIPS_ISO}" "boot/${INITRAMFS_BASENAME}"  > "${MIPS_INITRAMFS_IMAGE}"

echo "MIPS_KERNEL_IMAGE=${MIPS_KERNEL_IMAGE}"
echo "MIPS_INITRAMFS_IMAGE=${MIPS_INITRAMFS_IMAGE}"
