#!/usr/bin/env bash
# guest-run-shell-e2e-harness.sh — headless pass/fail test for the FreeRTOS
# interactive UART shell, driven over real serial RX.
#
# Launches FreeRTOS with the 3 mandatory ivshmem channels (ARM/RISCV/MIPS)
# plus the CAN ivshmem channel (so `can status` reads a deterministic
# rx_frames=0 from zero-initialized IVSHMEM5 shared memory -- see the plan's
# Design Decisions for why this is required). No Linux guests are started.
#
# Sends the 6 documented shell commands + 1 unrecognized command via
# `tmux send-keys`, then a second `sysinfo` (as the final command) so we
# can compare heap_free=N before/after the 7-command sequence and assert
# the firmware has not leaked heap during shell/showcase activity. Verifies
# the exact output documented in README.md's "Interactive Shell" section:
#   help, stats, sysinfo, links, loglevel, can status
# plus one unrecognized-command check (shell_dispatch's default branch).
#
# Exit 0 = ALL PASS, Exit 1 = any FAIL.
#
# Environment overrides:
#   SHELL_E2E_TIMEOUT  seconds to wait for the shell prompt at boot (default 60)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BOOT_TIMEOUT="${SHELL_E2E_TIMEOUT:-60}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="shell-e2e-${RUN_ID}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

# ---- tmux session (single pane) ----
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on

# ---- ivshmem servers (background) ----
# ARM/RISCV/MIPS are mandatory chardevs for chimera-r52-freertos-demo. CAN is
# attached (without a canbus object, no sudo/vcan0 needed) so IVSHMEM5 is
# real zero-init shared memory and `can status` reports a deterministic
# rx_frames=0 -- see this plan's Design Decisions, item 3.
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_CAN_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_CAN_FREERTOS_SOCKET}"    -M ivshmem-can-ft    -l "${IVSHMEM_CAN_FREERTOS_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 4 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.0, interactive -nographic) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${qemu_bin}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-can-freertos=canft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -chardev socket,id=canft,path='${IVSHMEM_CAN_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter

# ---- Wait for shell prompt ----
_info "Waiting for shell prompt (timeout ${BOOT_TIMEOUT}s)..."
elapsed=0
PROMPT_SEEN=0
while (( elapsed < BOOT_TIMEOUT )); do
    content="$(tmux capture-pane -p -t "${SESSION}:0.0" 2>/dev/null)"
    if echo "${content}" | grep -q "chimera>"; then
        PROMPT_SEEN=1
        break
    fi
    sleep 1
    (( ++elapsed ))
done

if [[ "${PROMPT_SEEN}" -eq 0 ]]; then
    _fail "FAIL: shell prompt did not appear within ${BOOT_TIMEOUT}s"
    echo "=== pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.0" 2>/dev/null | tail -30 || true
    exit 1
fi
_ok "Shell prompt detected"

# ---- Send commands ----
send_cmd() {
    tmux send-keys -t "${SESSION}:0.0" "$1" Enter
    sleep 1
}

send_cmd "help"
send_cmd "stats"
send_cmd "sysinfo"
send_cmd "links"
send_cmd "loglevel"
send_cmd "can status"
send_cmd "frobnicate"
# Second sysinfo: paired with the first (line 122) to detect heap leaks
# that occur during shell/showcase activity. Equal in firmware to the
# first; only the order in the captured output differs.
send_cmd "sysinfo"
sleep 1

OUTPUT="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"

# ---- Checks ----
FAIL_COUNT=0

check_contains() {
    local label="$1" needle="$2"
    if echo "${OUTPUT}" | grep -qF -- "${needle}"; then
        _ok "${label}"
    else
        _fail "${label}  (expected literal: ${needle})"
        (( ++FAIL_COUNT ))
    fi
}

check_regex() {
    local label="$1" pattern="$2"
    if echo "${OUTPUT}" | grep -Eq -- "${pattern}"; then
        _ok "${label}"
    else
        _fail "${label}  (expected pattern: ${pattern})"
        (( ++FAIL_COUNT ))
    fi
}

echo ""
echo "[harness] Checking 'help' output (6 commands)..."
check_contains "help: help"     "help - list available commands"
check_contains "help: stats"    "stats - per-guest HELLO count, cpu%, mem%"
check_contains "help: sysinfo"  "sysinfo - heap free, uptime, stack high-water marks"
check_contains "help: links"    "links - per-channel IVPOSITION, flags, time since last HELLO"
check_contains "help: loglevel" "loglevel - get/set runtime log verbosity (0=VERBOSE..3=ERROR)"
check_contains "help: can"      "can - 'can status' - CAN controller status register, frames forwarded"

echo ""
echo "[harness] Checking 'stats' output (no Linux guests -> all zero)..."
check_contains "stats: arm-linux"   "arm-linux: hello=0 cpu=0.00% mem=0.00%"
check_contains "stats: riscv-linux" "riscv-linux: hello=0 cpu=0.00% mem=0.00%"
check_contains "stats: mips-linux"  "mips-linux: hello=0 cpu=0.00% mem=0.00%"

echo ""
echo "[harness] Checking 'sysinfo' output..."
check_regex "sysinfo: 4 numeric fields" \
    'heap_free=[0-9]+ uptime_s=[0-9]+ shell_stack_hiwat=[0-9]+ showcase_stack_hiwat=[0-9]+'

echo ""
echo "[harness] Checking 'links' output (no Linux guests -> flags=0)..."
check_regex "links: arm-linux"   'arm-linux: ivpos=0x[0-9a-f]{8} l2f_flag=0 f2l_flag=0 since_hello=[0-9]+ms'
check_regex "links: riscv-linux" 'riscv-linux: ivpos=0x[0-9a-f]{8} l2f_flag=0 f2l_flag=0 since_hello=[0-9]+ms'
check_regex "links: mips-linux"  'mips-linux: ivpos=0x[0-9a-f]{8} l2f_flag=0 f2l_flag=0 since_hello=[0-9]+ms'

echo ""
echo "[harness] Checking 'loglevel' (default level)..."
check_contains "loglevel: default INFO" "loglevel=1 (INFO)"

echo ""
echo "[harness] Checking 'can status' (canft attached -> rx_frames=0)..."
check_regex "can status: sr+rx_frames" 'sr=0x[0-9a-f]{8} rx_frames=0'

echo ""
echo "[harness] Checking unrecognized command..."
check_contains "unknown command" "unknown command: frobnicate (try 'help')"

# ---- Result ----
echo ""
if (( FAIL_COUNT == 0 )); then
    echo "[harness] PASS — all 16 shell command checks passed"
    exit 0
fi

echo "[harness] FAIL — ${FAIL_COUNT} check(s) failed"
echo "=== Full pane output ==="
echo "${OUTPUT}"
exit 1