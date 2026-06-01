#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${ARM_ISO}" "ARM installer image"
require_file "${ARM_UEFI_BIOS}" "ARM UEFI firmware"

exec qemu-system-aarch64 \
    -machine virt,gic-version=3 \
    -cpu cortex-a57 -m 512M -smp 2 \
    -bios "${ARM_UEFI_BIOS}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${ARM_ISO}",media=cdrom -boot d \
    -netdev user,id=net0,hostfwd=tcp::"${ARM_SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -nographic
