#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[[ -n "${ARM_LINUX_IMAGE}" ]] || die "Set ARM_LINUX_IMAGE to the ARM Linux disk image"

ARM_TFA_QEMU_BIOS="${ARM_TFA_QEMU_BIOS:-}"
ARM_TFA_FIP_PFLASH="${ARM_TFA_FIP_PFLASH:-${ARM_TFA_FIP}}"
PHASE2_QEMU_CPU="${PHASE2_QEMU_CPU:-max,sme=off,sve=off}"
PHASE2_QEMU_MACHINE="${PHASE2_QEMU_MACHINE:-virt,secure=on,virtualization=on,gic-version=3}"
PHASE2_SECONDARY_SERIAL_LOG="${PHASE2_SECONDARY_SERIAL_LOG:-}"
PHASE2_QEMU_DEBUG_FLAGS="${PHASE2_QEMU_DEBUG_FLAGS:-}"
PHASE2_QEMU_LOG_FILE="${PHASE2_QEMU_LOG_FILE:-}"

qemu_serial_args=()
if [[ -n "${PHASE2_SECONDARY_SERIAL_LOG}" ]]; then
    qemu_serial_args+=(-serial "file:${PHASE2_SECONDARY_SERIAL_LOG}")
fi

qemu_console_args=(-nographic)
if [[ -n "${PHASE2_SECONDARY_SERIAL_LOG}" ]]; then
    qemu_console_args=(-display none -serial mon:stdio "${qemu_serial_args[@]}")
fi

qemu_debug_args=()
if [[ -n "${PHASE2_QEMU_DEBUG_FLAGS}" ]]; then
    qemu_debug_args+=(-d "${PHASE2_QEMU_DEBUG_FLAGS}")
fi
if [[ -n "${PHASE2_QEMU_LOG_FILE}" ]]; then
    qemu_debug_args+=(-D "${PHASE2_QEMU_LOG_FILE}")
fi

require_file "${ARM_LINUX_IMAGE}" "ARM Linux image"

if [[ -n "${ARM_TFA_QEMU_BIOS}" ]]; then
    require_file "${ARM_TFA_QEMU_BIOS}" "TF-A QEMU BIOS image"
    phase2_workdir="$(cd "$(dirname "${ARM_TFA_QEMU_BIOS}")" && pwd)"

    if [[ -f "${ARM_KERNEL_IMAGE}" && -f "${ARM_INITRAMFS_IMAGE}" ]]; then
        cd "${phase2_workdir}"
        exec qemu-system-aarch64 \
            -machine "${PHASE2_QEMU_MACHINE}" \
            -cpu "${PHASE2_QEMU_CPU}" -m 2G -smp 4 \
            -bios "${ARM_TFA_QEMU_BIOS}" \
            -kernel "${ARM_KERNEL_IMAGE}" \
            -initrd "${ARM_INITRAMFS_IMAGE}" \
            -append "${ARM_KERNEL_CMDLINE}" \
            -semihosting-config enable=on,target=native \
            -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
            -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
            -drive file="${ARM_LINUX_IMAGE}",media=cdrom \
            -netdev user,id=net0,hostfwd=tcp::"${ARM_SSH_PORT}"-:22 \
            -device virtio-net-device,netdev=net0 \
            "${qemu_debug_args[@]}" \
            "${qemu_console_args[@]}"
    fi

    cd "${phase2_workdir}"
    exec qemu-system-aarch64 \
        -machine "${PHASE2_QEMU_MACHINE}" \
        -cpu "${PHASE2_QEMU_CPU}" -m 2G -smp 4 \
        -bios "${ARM_TFA_QEMU_BIOS}" \
        -drive file="${ARM_LINUX_IMAGE}",format=raw \
        -semihosting-config enable=on,target=native \
        -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
        -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
        "${qemu_debug_args[@]}" \
        "${qemu_console_args[@]}"
fi

[[ -n "${ARM_TFA_BL1}" ]] || die "Set ARM_TFA_BL1 to TF-A bl1.bin, or ARM_TFA_QEMU_BIOS to qemu_fw.bios"
[[ -n "${ARM_TFA_FIP}" ]] || die "Set ARM_TFA_FIP to the TF-A FIP image, or ARM_TFA_QEMU_BIOS to qemu_fw.bios"

require_file "${ARM_TFA_BL1}" "TF-A BL1"
require_file "${ARM_TFA_FIP}" "TF-A FIP"
require_file "${ARM_TFA_FIP_PFLASH}" "TF-A pflash FIP image"

exec qemu-system-aarch64 \
    -machine "${PHASE2_QEMU_MACHINE}" \
    -cpu "${PHASE2_QEMU_CPU}" -m 2G -smp 4 \
    -bios "${ARM_TFA_BL1}" \
    -drive if=pflash,file="${ARM_TFA_FIP_PFLASH}",format=raw \
    -drive file="${ARM_LINUX_IMAGE}",format=raw \
    -semihosting-config enable=on,target=native \
    -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    "${qemu_debug_args[@]}" \
    "${qemu_console_args[@]}"
