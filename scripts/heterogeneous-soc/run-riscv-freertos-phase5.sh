#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

exec qemu-system-riscv64 \
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -bios "${FREERTOS_DEMO_ELF}" \
    -nographic
