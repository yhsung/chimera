#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-riscv64)"

require_file "${RISCV_OPENSBI_BIOS}" "RISC-V OpenSBI firmware"
require_file "${RISCV_KERNEL_IMAGE}" "RISC-V kernel image (vmlinuz)"
require_file "${RISCV_INITRD_IMAGE}" "RISC-V initrd image"
require_file "${RISCV_DEBIAN_DISK}" "RISC-V Debian rootfs disk"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"

exec "${qemu_bin}" \
    -machine virt,aclint=on \
    -cpu rv64,h=true,v=true \
    -m 2G -smp 4 \
    -bios "${RISCV_OPENSBI_BIOS}" \
    -kernel "${RISCV_KERNEL_IMAGE}" \
    -initrd "${RISCV_INITRD_IMAGE}" \
    -append "${RISCV_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
    -drive file="${RISCV_DEBIAN_DISK}",format=qcow2,if=virtio \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-riscv,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
