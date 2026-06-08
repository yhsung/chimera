#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

exec "${qemu_bin}" \
    -machine chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -monitor unix:/tmp/freertos-monitor.sock,server,nowait \
    -nographic
