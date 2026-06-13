#!/usr/bin/env bash
# guest-run-freertos-shell-harness.sh — headless pass/fail test for all
# six FreeRTOS UART shell commands.
#
# Starts FreeRTOS QEMU with all mandatory ivshmem channels but NO Linux
# guests. Sends each shell command over the UART and verifies the response.
#
# Exit 0 = ALL PASS, Exit 1 = any FAIL.
#
# Environment overrides:
#   SHELL_HARNESS_TIMEOUT  seconds per command (default 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

PER_CMD_TIMEOUT="${SHELL_HARNESS_TIMEOUT:-30}"
TOTAL_TIMEOUT=180
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_DIR="${HARNESS_LOG_DIR:-/tmp/harness-logs}"
SERIAL_DIR="/tmp/freertos-shell-${RUN_ID}"
SERIAL_IN="${SERIAL_DIR}.in"
SERIAL_OUT="${SERIAL_DIR}.out"
FREERTOS_LOG="${LOG_DIR}/freertos-shell-${RUN_ID}.log"
PASS_COUNT=0
FAIL_COUNT=0

mkdir -p "${LOG_DIR}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    pkill -f "qemu-system-arm.*freertos-r52-demo.*serial pipe" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-arm-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-riscv-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-mips-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-stats-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-bootlog" 2>/dev/null || true
    rm -f "${SERIAL_IN}" "${SERIAL_OUT}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Clean up before starting.
cleanup
rm -f "${FREERTOS_LOG}"

# ── Helper: wait for a string in the serial output ────────────────────────
# Reads SERIAL_OUT in a loop until the needle appears or timeout expires.
# Returns 0 (match) or 1 (timeout).  Accumulates output into the passed variable.
wait_for_serial() {
    local needle="$1"
    local varname="$2"   # name of variable to append output to
    local timeout="${3:-${PER_CMD_TIMEOUT}}"
    local elapsed=0
    local buf=""

    while (( elapsed < timeout )); do
        if [[ -r "${SERIAL_OUT}" ]]; then
            local chunk
            chunk="$(cat "${SERIAL_OUT}" 2>/dev/null || true)"
            if [[ -n "${chunk}" ]]; then
                buf+="${chunk}"
                > "${SERIAL_OUT}"  # clear after reading
            fi
        fi
        if echo "${buf}" | grep -q "${needle}"; then
            eval "${varname}=\"\${buf}\""
            return 0
        fi
        sleep 0.2
        (( elapsed++ ))  # 0.2 s per iteration ≈ 5 ticks/sec; elapsed counts seconds
    done
    eval "${varname}=\"\${buf}\""
    return 1
}

# ── Helper: send a string to the UART ─────────────────────────────────────
send_serial() {
    printf '%s\n' "$1" >> "${SERIAL_IN}"
}

# ── Helper: run a command, check for expected output, report ──────────────
test_command() {
    local cmd="$1"
    local expected="$2"
    local label="$3"
    local output=""

    _info "  Sending: ${cmd}"
    send_serial "${cmd}"
    if wait_for_serial "${expected}" output "${PER_CMD_TIMEOUT}"; then
        _ok "${label}: matched '${expected}'"
        PASS_COUNT=$(( PASS_COUNT + 1 ))
        return 0
    else
        _fail "${label}: expected '${expected}' not found within ${PER_CMD_TIMEOUT}s"
        _fail "  Last output: $(echo "${output}" | tail -5 | tr '\n' ' ')"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        return 1
    fi
}

# ── ivshmem servers ────────────────────────────────────────────────────────
_info "Starting ivshmem servers..."

IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}" \
         "${IVSHMEM_BOOTLOG_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}"  -M ivshmem-stats-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_BOOTLOG_SOCKET}"        -M ivshmem-bootlog   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &

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

# ── FreeRTOS QEMU with serial pipe ─────────────────────────────────────────
require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

_info "Starting FreeRTOS QEMU with serial pipe: ${SERIAL_DIR}"
"${qemu_bin}" \
    -machine "chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft" \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -serial pipe:"${SERIAL_DIR}" \
    -nographic &
QEMU_PID=$!

# ── Wait for shell prompt ─────────────────────────────────────────────────
_info "Waiting for shell prompt..."
if ! wait_for_serial "chimera>" _ 20; then
    _fail "Shell prompt not detected within 20s"
    _info "=== Serial output ==="
    cat "${SERIAL_OUT}" 2>/dev/null | tail -20 || true
    exit 1
fi
_ok "Shell prompt detected"

# ── Test: help ────────────────────────────────────────────────────────────
test_command "help" \
    "Chimera shell commands:" \
    "help shows command list"

# ── Test: stats ────────────────────────────────────────────────────────────
test_command "stats" \
    "hello=" \
    "stats shows per-guest hello counts"

# ── Test: sysinfo ─────────────────────────────────────────────────────────
test_command "sysinfo" \
    "heap_free=" \
    "sysinfo shows heap free"
test_command "sysinfo" \
    "uptime_s=" \
    "sysinfo shows uptime"
test_command "sysinfo" \
    "shell_stack_hiwat=" \
    "sysinfo shows shell stack high-water mark"
test_command "sysinfo" \
    "showcase_stack_hiwat=" \
    "sysinfo shows showcase stack high-water mark"

# ── Test: links ───────────────────────────────────────────────────────────
test_command "links" \
    "ivpos=" \
    "links shows ivshmem IVPOSITION"
test_command "links" \
    "since_hello=" \
    "links shows time since last hello"

# ── Test: loglevel (read) ─────────────────────────────────────────────────
test_command "loglevel" \
    "loglevel=" \
    "loglevel shows current log level"

# ── Test: loglevel (set to VERBOSE and re-read) ───────────────────────────
test_command "loglevel 0" \
    "loglevel=0" \
    "loglevel 0 sets verbose mode (may not echo on all builds)"
# Reset to default INFO.
send_serial "loglevel 1"
sleep 1

# ── Test: can status ──────────────────────────────────────────────────────
test_command "can status" \
    "sr=0x" \
    "can status shows status register"
test_command "can status" \
    "rx_frames=" \
    "can status shows frame count"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Shell test results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "=========================================="

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
    _ok "All shell command tests PASSED"
    exit 0
else
    _fail "Some shell command tests FAILED"
    # Dump serial output for debugging
    echo "=== Captured serial output ==="
    cat "${SERIAL_OUT}" 2>/dev/null | tail -50 || true
    exit 1
fi
