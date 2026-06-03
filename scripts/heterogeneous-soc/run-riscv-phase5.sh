#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${RISCV_ISO}" "RISC-V installer ISO"
require_file "${RISCV_OPENSBI_BIOS}" "RISC-V OpenSBI firmware"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

RISCV_BOOT_MODE="${RISCV_BOOT_MODE:-direct}"

bash "${SCRIPT_DIR}/prepare-riscv-uboot.sh"
bash "${SCRIPT_DIR}/prepare-riscv-phase3-boot-assets.sh"
bash "${SCRIPT_DIR}/prepare-demo-guest-overlays.sh"

if [[ ! -f "${RISCV_DISK}" ]]; then
    qemu-img create -f qcow2 "${RISCV_DISK}" 4G
fi

require_file "${RISCV_KERNEL_IMAGE}" "RISC-V decompressed kernel image"
require_file "${RISCV_INITRAMFS_COMBINED}" "RISC-V combined initramfs image"

exec qemu-system-riscv64 \
    -machine virt,aclint=on \
    -cpu rv64,h=true,v=true \
    -m 2G -smp 4 \
    -bios "${RISCV_OPENSBI_BIOS}" \
    -kernel "${RISCV_KERNEL_IMAGE}" \
    -initrd "${RISCV_INITRAMFS_COMBINED}" \
    -append "${RISCV_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${RISCV_DISK}",if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -drive file="${RISCV_ISO}",media=cdrom,if=none,id=cd0,readonly=on \
    -device virtio-blk-device,drive=cd0 \
    -netdev user,id=net0,hostfwd=tcp::"${RISCV_SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
