#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

[[ -n "${ARM_LINUX_IMAGE}" ]] || die "Set ARM_LINUX_IMAGE to the ARM Linux disk image"

ARM_TFA_QEMU_BIOS="${ARM_TFA_QEMU_BIOS:-}"
ARM_TFA_FIP_PFLASH="${ARM_TFA_FIP_PFLASH:-${ARM_TFA_FIP}}"
PHASE2_QEMU_CPU="${PHASE2_QEMU_CPU:-max}"
PHASE2_QEMU_MACHINE="${PHASE2_QEMU_MACHINE:-virt,secure=on,virtualization=on,gic-version=3}"

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
            -nographic
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
        -nographic
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
    -nographic
