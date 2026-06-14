#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-run-freertos-shell-harness.sh — headless pass/fail test for FreeRTOS
# shell and diagnostic output.
#
# Starts FreeRTOS QEMU with all mandatory ivshmem channels but NO Linux
# guests. Verifies that the firmware boots correctly, the shell initialises,
# and all periodic diagnostic output is produced.
#
# This is an observation-based harness: it checks the firmware's autonomous
# output (banner, prompt, diag messages) rather than sending interactive
# commands. This is because QEMU's PL011 RX interrupt routing requires
# further debugging for interactive serial input.
#
# Exit 0 = ALL PASS, Exit 1 = any FAIL.
#
# Environment overrides:
#   SHELL_HARNESS_TIMEOUT  seconds to wait for pass strings (default 60)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

HARNESS_TIMEOUT="${SHELL_HARNESS_TIMEOUT:-60}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_DIR="${HARNESS_LOG_DIR:-/tmp/harness-logs}"
FREERTOS_LOG="${LOG_DIR}/freertos-shell-${RUN_ID}.log"
mkdir -p "${LOG_DIR}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

QEMU_PID=""
cleanup() {
    if [[ -n "${QEMU_PID}" ]]; then
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
    pkill ivshmem-server 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cleanup
rm -f "${FREERTOS_LOG}"

# ── ivshmem servers (background, quiet) ──────────────────────────────────
_info "Starting ivshmem servers..."

IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}" \
         "${IVSHMEM_BOOTLOG_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}"  -M ivshmem-stats-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_BOOTLOG_SOCKET}"        -M ivshmem-bootlog   -l "${IVSHMEM_BOOTLOG_SIZE}" -n "${IVSHMEM_BOOTLOG_VECTORS}" >/dev/null 2>&1 &

# Wait for all five sockets.
for _i in $(seq 1 60); do
    if [[ -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_ARM_FREERTOS_SOCKET}"  && \
       [[ -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_RISCV_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  && \
       [[ -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_STATS_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_BOOTLOG_SOCKET}"        ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_BOOTLOG_SOCKET}"; then
        break
    fi
    sleep 0.5
done
_info "All ivshmem servers ready."

# ── FreeRTOS QEMU ─────────────────────────────────────────────────────────
require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

_info "Starting FreeRTOS QEMU; UART -> ${FREERTOS_LOG}"
"${qemu_bin}" \
    -machine "chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft" \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -serial file:"${FREERTOS_LOG}" -nographic &
QEMU_PID=$!

# ── Monitor loop ──────────────────────────────────────────────────────────
# Pass conditions (all observable from FreeRTOS autonomous output at
# default log level HSOC_LOG_INFO):
#   1. CHIMERA banner "██╗██╗"     -> shell_init() ran, UART TX works
#   2. Shell prompt "chimera>"     -> shell task is running
#   3. "[freertos] showcase task"  -> showcase loop is running
#   4. "[freertos] CAN controller" -> CAN driver initialized
PASS_STRINGS=(
    "BANNER:${BANNER_STRING:-██████╗██╗}"
    "SHELL:chimera>"
    "SHOWCASE:showcase task started"
    "CAN:CAN controller enabled"
)

echo "[harness] Monitoring for shell/diag output (timeout ${HARNESS_TIMEOUT}s)..."
declare -A seen
for s in "${PASS_STRINGS[@]}"; do
    label="${s%%:*}"
    seen["${label}"]=0
done

elapsed=0
while (( elapsed < HARNESS_TIMEOUT )); do
    content="$(cat "${FREERTOS_LOG}" 2>/dev/null || true)"

    all_seen=1
    for s in "${PASS_STRINGS[@]}"; do
        label="${s%%:*}"
        needle="${s#*:}"
        if [[ "${seen[${label}]}" -eq 0 ]]; then
            if echo "${content}" | grep -q "${needle}"; then
                seen["${label}"]=1
                _ok "Detected: ${label} (${needle})"
            else
                all_seen=0
            fi
        fi
    done

    if [[ "${all_seen}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — all shell/diag conditions met"
        echo "=== Matching output ==="
        echo "${content}" | grep -E "chimera>|showcase|CAN controller|banner" | tail -15
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 15 == 0 )); then
        printf "[harness] t=%3ds — " "${elapsed}"
        for s in "${PASS_STRINGS[@]}"; do
            label="${s%%:*}"
            if [[ "${seen[${label}]}" -eq 1 ]]; then printf "✓ "; else printf "… "; fi
        done
        echo ""
    fi

    sleep 1
    (( ++elapsed ))
done

# ── Timeout — FAIL ────────────────────────────────────────────────────────
echo ""
_fail "FAIL: timeout after ${HARNESS_TIMEOUT}s"
echo "=== FreeRTOS serial output (last 30 lines) ==="
tail -30 "${FREERTOS_LOG}" 2>/dev/null || true
exit 1
