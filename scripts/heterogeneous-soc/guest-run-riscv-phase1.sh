#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${RISCV_ISO}" "RISC-V installer ISO"
require_file "${RISCV_UBOOT_ARCHIVE}" "RISC-V U-Boot archive"

bash "${SCRIPT_DIR}/guest-prepare-riscv-uboot.sh"

if [[ ! -f "${RISCV_DISK}" ]]; then
    qemu-img create -f qcow2 "${RISCV_DISK}" 4G
fi

exec qemu-system-riscv64 \
  -machine virt,aclint=on \
  -cpu rv64 -m 512M -smp 2 \
  -kernel "${RISCV_UBOOT_BIN}" \
  -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
  -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
  -drive file="${RISCV_DISK}",if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -drive file="${RISCV_ISO}",media=cdrom,if=none,id=cd0,readonly=on \
  -device virtio-blk-device,drive=cd0 \
  -netdev user,id=net0,hostfwd=tcp::"${RISCV_SSH_PORT}"-:22 \
  -device virtio-net-device,netdev=net0 \
  -nographic
