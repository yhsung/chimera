#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

can_backend=()
if [[ -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" ]]; then
    can_backend=(
        -object can-bus,id=canbus0
        -object "can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0"
        -chardev "socket,id=canft,path=${IVSHMEM_CAN_FREERTOS_SOCKET}"
    )
fi

machine_opts="chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft"
if [[ ${#can_backend[@]} -gt 0 ]]; then
    machine_opts+=",canbus=canbus0,ivshmem-can-freertos=canft"
fi

exec "${qemu_bin}" \
    -machine "${machine_opts}" \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    "${can_backend[@]}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -monitor unix:/tmp/freertos-monitor.sock,server,nowait \
    -nographic
