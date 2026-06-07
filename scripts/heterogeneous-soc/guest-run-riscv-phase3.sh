#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${RISCV_ISO}" "RISC-V installer ISO"
require_file "${RISCV_UBOOT_ARCHIVE}" "RISC-V U-Boot archive"
require_file "${RISCV_OPENSBI_BIOS}" "RISC-V OpenSBI firmware"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

RISCV_BOOT_MODE="${RISCV_BOOT_MODE:-uboot}"
PHASE3_QEMU_MACHINE="${PHASE3_QEMU_MACHINE:-virt,aclint=on,aia=aplic-imsic}"
PHASE3_QEMU_CPU="${PHASE3_QEMU_CPU:-rv64,h=true,v=true}"
PHASE3_SECONDARY_SERIAL_LOG="${PHASE3_SECONDARY_SERIAL_LOG:-}"
PHASE3_QEMU_DEBUG_FLAGS="${PHASE3_QEMU_DEBUG_FLAGS:-}"
PHASE3_QEMU_LOG_FILE="${PHASE3_QEMU_LOG_FILE:-}"

qemu_serial_args=()
if [[ -n "${PHASE3_SECONDARY_SERIAL_LOG}" ]]; then
    qemu_serial_args+=(-serial "file:${PHASE3_SECONDARY_SERIAL_LOG}")
fi

qemu_console_args=(-nographic)
if [[ -n "${PHASE3_SECONDARY_SERIAL_LOG}" ]]; then
    qemu_console_args=(-display none -serial mon:stdio "${qemu_serial_args[@]}")
fi

qemu_debug_args=()
if [[ -n "${PHASE3_QEMU_DEBUG_FLAGS}" ]]; then
    qemu_debug_args+=(-d "${PHASE3_QEMU_DEBUG_FLAGS}")
fi
if [[ -n "${PHASE3_QEMU_LOG_FILE}" ]]; then
    qemu_debug_args+=(-D "${PHASE3_QEMU_LOG_FILE}")
fi

bash "${SCRIPT_DIR}/guest-prepare-riscv-uboot.sh"

if [[ ! -f "${RISCV_DISK}" ]]; then
    qemu-img create -f qcow2 "${RISCV_DISK}" 4G
fi

if [[ "${RISCV_BOOT_MODE}" == "direct" ]]; then
    bash "${SCRIPT_DIR}/guest-prepare-riscv-phase3-boot-assets.sh"
    bash "${SCRIPT_DIR}/guest-prepare-demo-guest-overlays.sh"
    require_file "${RISCV_KERNEL_IMAGE}" "RISC-V decompressed kernel image"
    require_file "${RISCV_INITRAMFS_COMBINED}" "RISC-V combined initramfs image"

    exec qemu-system-riscv64 \
        -machine "${PHASE3_QEMU_MACHINE}" \
        -cpu "${PHASE3_QEMU_CPU}" \
        -m 512M -smp 4 \
        -bios "${RISCV_OPENSBI_BIOS}" \
        -kernel "${RISCV_KERNEL_IMAGE}" \
        -initrd "${RISCV_INITRAMFS_COMBINED}" \
        -append "${RISCV_KERNEL_CMDLINE}" \
        -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
        -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
        -drive file="${RISCV_DISK}",if=none,id=hd0 \
        -device virtio-blk-device,drive=hd0 \
        -drive file="${RISCV_ISO}",media=cdrom,if=none,id=cd0,readonly=on \
        -device virtio-blk-device,drive=cd0 \
        -netdev user,id=net0,hostfwd=tcp::"${RISCV_SSH_PORT}"-:22 \
        -device virtio-net-device,netdev=net0 \
        -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
        "${qemu_debug_args[@]}" \
        "${qemu_console_args[@]}"
fi

exec qemu-system-riscv64 \
    -machine "${PHASE3_QEMU_MACHINE}" \
    -cpu "${PHASE3_QEMU_CPU}" \
    -m 512M -smp 4 \
    -kernel "${RISCV_UBOOT_BIN}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${RISCV_DISK}",if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -drive file="${RISCV_ISO}",media=cdrom,if=none,id=cd0,readonly=on \
    -device virtio-blk-device,drive=cd0 \
    -netdev user,id=net0,hostfwd=tcp::"${RISCV_SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    "${qemu_debug_args[@]}" \
    "${qemu_console_args[@]}"
