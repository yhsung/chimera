#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-run-can-harness.sh — headless pass/fail test for CAN RX on FreeRTOS.
#
# Brings up vcan0, starts ivshmem-server instances for all six FreeRTOS
# channels (ARM/RISCV/MIPS/stats/bootlog/CAN), launches the FreeRTOS guest
# with its UART captured to a file, sends a CAN frame from Lima's vcan0, and
# asserts the decoded "CAN RX:" line appears.
#
# All six channels are required even though this harness only exercises CAN:
#  - ARM/RISCV/MIPS chardevs are mandatory (chimera_r52_require_chardev()
#    exits QEMU if any of them is missing).
#  - main() calls bootlog_init() — which writes the bootlog header magic into
#    the IVSHMEM4 shared-memory region — before the very first UART message,
#    so without the bootlog chardev the firmware takes a data abort and
#    prints nothing at all.
#  - The stats channel is connected for parity with the normal launch.
#
# PASS when FreeRTOS prints the decoded frame from a Lima `cansend`.
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   CAN_TEST_ID         CAN frame ID to send (default 123, hex without 0x)
#   CAN_TEST_DATA       CAN frame payload (default DEADBEEF)
#   SERIAL_LOG          FreeRTOS UART capture file (default /tmp/can-harness-freertos.log)
#   CAN_HARNESS_TIMEOUT seconds to wait for the "CAN RX:" line (default 60)
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

CAN_TEST_ID="${CAN_TEST_ID:-123}"
CAN_TEST_DATA="${CAN_TEST_DATA:-DEADBEEF}"
SERIAL_LOG="${SERIAL_LOG:-/tmp/can-harness-freertos.log}"
TIMEOUT="${CAN_HARNESS_TIMEOUT:-60}"

ALL_SOCKETS=(
    "${IVSHMEM_ARM_FREERTOS_SOCKET}"
    "${IVSHMEM_RISCV_FREERTOS_SOCKET}"
    "${IVSHMEM_MIPS_FREERTOS_SOCKET}"
    "${IVSHMEM_STATS_FREERTOS_SOCKET}"
    "${IVSHMEM_BOOTLOG_SOCKET}"
    "${IVSHMEM_CAN_FREERTOS_SOCKET}"
)

cleanup() {
    pkill -f "qemu-system-arm.*chimera-r52-freertos-demo" 2>/dev/null || true
    pkill -f "ivshmem-server.*-M ivshmem-(arm|riscv|mips|stats|can)-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*-M ivshmem-bootlog" 2>/dev/null || true
    rm -f "${ALL_SOCKETS[@]}"
}
trap cleanup EXIT
cleanup
rm -f "${SERIAL_LOG}"

# ── vcan0 + CAP_NET_RAW ──────────────────────────────────────────────────────
sudo modprobe vcan 2>/dev/null || true
ip link show "${CAN_VCAN_IF}" >/dev/null 2>&1 || \
    sudo ip link add dev "${CAN_VCAN_IF}" type vcan
sudo ip link set "${CAN_VCAN_IF}" up
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"
sudo setcap cap_net_raw+eip "${qemu_bin}" 2>/dev/null || true

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

# ── ivshmem-server instances (ARM/RISCV/MIPS/stats/bootlog/CAN) ─────────────
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
    "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}" \
    "${IVSHMEM_BOOTLOG_DIR}" "${IVSHMEM_CAN_FREERTOS_DIR}"

IVSHMEM_BIN="$(find_ivshmem_server)"
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}" -M ivshmem-arm-ft -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" -M ivshmem-riscv-ft -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}" -M ivshmem-mips-ft -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" -M ivshmem-stats-ft -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_BOOTLOG_SOCKET}" -M ivshmem-bootlog -l "${IVSHMEM_BOOTLOG_SIZE}" -n "${IVSHMEM_BOOTLOG_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" -M ivshmem-can-ft -l "${IVSHMEM_CAN_FREERTOS_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

# Wait for all six sockets to exist and be listening.
for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${ALL_SOCKETS[@]}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done

# ── Launch FreeRTOS, serial -> file ─────────────────────────────────────────
"${qemu_bin}" \
    -machine "chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft,canbus=canbus0,ivshmem-can-freertos=canft" \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -object can-bus,id=canbus0 \
    -object "can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0" \
    -chardev socket,id=canft,path="${IVSHMEM_CAN_FREERTOS_SOCKET}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -serial file:"${SERIAL_LOG}" -nographic &
sleep 5

# ── Send the frame and wait for the decoded line ────────────────────────────
cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}"

want="CAN RX: id=0x${CAN_TEST_ID}"
elapsed=0
while (( elapsed < TIMEOUT )); do
    if grep -qi "${want}" "${SERIAL_LOG}" 2>/dev/null; then
        echo "PASS: FreeRTOS received CAN frame:"
        grep -i "CAN RX:" "${SERIAL_LOG}" | tail -1
        exit 0
    fi
    cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}" 2>/dev/null || true
    sleep 2; (( elapsed += 2 ))
done

echo "FAIL: no 'CAN RX:' line within ${TIMEOUT}s. Serial tail:"
tail -20 "${SERIAL_LOG}" 2>/dev/null || true
exit 1
