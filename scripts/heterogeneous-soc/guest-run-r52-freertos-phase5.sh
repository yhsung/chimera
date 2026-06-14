#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

# ── vcan0 setup (gracefully degrade if unavailable) ───────────────────────────
if ! ip link show "${CAN_VCAN_IF}" >/dev/null 2>&1; then
    sudo modprobe vcan 2>/dev/null || true
    sudo ip link add dev "${CAN_VCAN_IF}" type vcan 2>/dev/null || true
fi
sudo ip link set "${CAN_VCAN_IF}" up 2>/dev/null || true

can_backend=()
if [[ -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" ]] && ip link show "${CAN_VCAN_IF}" 2>/dev/null | grep -q "UP"; then
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
    -rtc base=localtime \
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
