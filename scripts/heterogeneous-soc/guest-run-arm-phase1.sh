#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${ARM_ISO}" "ARM installer image"
require_file "${ARM_UEFI_BIOS}" "ARM UEFI firmware"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-arm-phase2-boot-assets.sh"
bash "${SCRIPT_DIR}/guest-prepare-demo-guest-overlays.sh"
require_file "${ARM_KERNEL_IMAGE}" "ARM kernel image"
require_file "${ARM_INITRAMFS_COMBINED}" "ARM combined initramfs"

exec qemu-system-aarch64 \
    -machine virt,gic-version=3 \
    -cpu cortex-a57 -m 512M -smp 2 \
    -bios "${ARM_UEFI_BIOS}" \
    -kernel "${ARM_KERNEL_IMAGE}" \
    -initrd "${ARM_INITRAMFS_COMBINED}" \
    -append "${ARM_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${ARM_ISO}",media=cdrom \
    -netdev user,id=net0,hostfwd=tcp::"${ARM_SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
