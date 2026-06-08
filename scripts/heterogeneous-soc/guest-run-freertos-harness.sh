#!/usr/bin/env bash
# guest-run-freertos-harness.sh — headless pass/fail harness for the FreeRTOS ivshmem demo.
#
# Runs everything in a detached tmux session (same layout as guest-run-phase5-tmux.sh).
# FreeRTOS UART is captured to a log file via tmux pipe-pane.
# auto_login_and_run() drives the Linux guests when the shell is ready.
# Pass condition: FreeRTOS log contains "received hello from arm-linux".
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   HARNESS_TIMEOUT   seconds to wait for pass string (default 300)
#   HARNESS_LOG_DIR   directory for log files (default /tmp/harness-logs)
#   SKIP_BUILD        skip make step if non-empty
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
REPO="${CHIMERA_ROOT}"

HARNESS_TIMEOUT="${HARNESS_TIMEOUT:-300}"
LOG_DIR="${HARNESS_LOG_DIR:-/tmp/harness-logs}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="freertos-harness-${RUN_ID}"
FREERTOS_LOG="${LOG_DIR}/freertos-${RUN_ID}.log"
PASS_STRING="received hello from arm-linux"

mkdir -p "${LOG_DIR}"

# ── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
    pkill -f "qemu-system-aarch64.*run-arm-phase5"       2>/dev/null || true
    pkill -f "qemu-system-riscv64.*run-riscv-phase5"     2>/dev/null || true
    pkill -f "ivshmem-server.*arm-freertos\|ivshmem-server.*riscv-freertos\|ivshmem-server.*mips-freertos\|ivshmem-server.*stats" 2>/dev/null || true
    pkill -f "qemu-system-mips.*run-chimera" 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Pre-run cleanup ──────────────────────────────────────────────────────────
echo "[harness] Killing orphan processes and removing stale sockets..."
pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
pkill -f "qemu-system-aarch64.*run-arm-phase5"       2>/dev/null || true
pkill -f "qemu-system-mips.*run-chimera"             2>/dev/null || true
sleep 0.5
rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" 2>/dev/null || true

# ── Build ────────────────────────────────────────────────────────────────────
if [[ -z "${SKIP_BUILD:-}" ]]; then
    echo "[harness] Building showcase..."
    bash "${SCRIPT_DIR}/guest-build-freertos-showcase.sh" \
        > "${LOG_DIR}/build-${RUN_ID}.log" 2>&1 \
        || { echo "[harness] BUILD FAILED — see ${LOG_DIR}/build-${RUN_ID}.log"; exit 1; }
fi
require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

# ── tmux session ─────────────────────────────────────────────────────────────
# Same pane layout as guest-run-phase5-tmux.sh:
#  pane 0: ARM ivshmem server
#  pane 1: RISCV ivshmem server
#  pane 2: MIPS ivshmem server
#  pane 3: STATS ivshmem server
#  pane 4: FreeRTOS QEMU   ← monitored for pass string
#  pane 5: ARM Linux QEMU
#  pane 6: RISCV Linux QEMU
#  pane 7: MIPS Linux QEMU
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux split-window -v -t "${SESSION}:0.0" -l 80%
tmux split-window -v -t "${SESSION}:0.1" -l 45%
tmux split-window -h -t "${SESSION}:0.0" -l 75%
tmux split-window -h -t "${SESSION}:0.1" -l 67%
tmux split-window -h -t "${SESSION}:0.2" -l 50%
tmux split-window -h -t "${SESSION}:0.5" -l 67%
tmux split-window -h -t "${SESSION}:0.6" -l 50%

# ── ivshmem servers ──────────────────────────────────────────────────────────
# Prepend env setup to every pane command so scripts inherit the correct paths
# even though tmux panes open a fresh login shell that may have a different
# CHIMERA_ROOT from the Lima VM's own ~/.bashrc.
BUILD_DIR="${BUILD_DIR:-/home/yhsung.guest/chimera-build-linux}"
# Explicitly set FREERTOS_DEMO_ELF so the pane command can't be overridden by the
# Lima VM's ~/.bashrc which may have an old path from a previous build in ~/chimera-src.
PANE_ENV="export CHIMERA_ROOT='${CHIMERA_ROOT}'; export BUILD_DIR='${BUILD_DIR}'; export FREERTOS_DEMO_ELF='${FREERTOS_DEMO_ELF}';"

IVSHMEM_BIN="$(find_ivshmem_server)"
tmux send-keys -t "${SESSION}:0.0" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_ARM_FREERTOS_SOCKET}\" -M ivshmem-arm-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter
tmux send-keys -t "${SESSION}:0.1" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_RISCV_FREERTOS_SOCKET}\" -M ivshmem-riscv-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter
tmux send-keys -t "${SESSION}:0.2" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_MIPS_FREERTOS_SOCKET}\" -M ivshmem-mips-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter
tmux send-keys -t "${SESSION}:0.3" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_STATS_FREERTOS_SOCKET}\" -M ivshmem-stats-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter

# Wait for sockets to exist and be listening.
for _i in $(seq 1 60); do
    if [[ -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_ARM_FREERTOS_SOCKET}"   && \
       [[ -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_RISCV_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  && \
       [[ -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_STATS_FREERTOS_SOCKET}"; then
        break
    fi
    sleep 0.5
done

# ── FreeRTOS QEMU ────────────────────────────────────────────────────────────
echo "[harness] Starting FreeRTOS QEMU; UART → ${FREERTOS_LOG}"
tmux send-keys -t "${SESSION}:0.4" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh'" Enter

# Give FreeRTOS QEMU time to start and print its first line before anything else.
sleep 2

# ── Linux guests ─────────────────────────────────────────────────────────────
tmux send-keys -t "${SESSION}:0.5" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-arm-phase5.sh'"    Enter
tmux send-keys -t "${SESSION}:0.6" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-riscv-phase5.sh'"  Enter
tmux send-keys -t "${SESSION}:0.7" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-chimera.sh'"        Enter

# ── auto_login_and_run ───────────────────────────────────────────────────────
# Detect the guest shell and fire the hello binary.  Same logic as
# handles both interactive login: and autologin ~#.
auto_login_and_run() {
    local pane="$1"
    shift
    local cmds=("$@")
    local timeout=180
    local elapsed=0

    # Write commands to a short-named bootstrap script in the 9p share dir so
    # the guest receives a ~22-char path instead of a 50+ char binary path.
    # Long tmux send-keys strings drop characters on the slow RISCV UART
    # emulation; the short "sh /mnt/pingpong/rN.sh" path is immune.
    local pane_idx="${pane##*.}"
    {
        printf '#!/bin/sh\n'
        for cmd in "${cmds[@]}"; do
            printf '%s\n' "$cmd"
        done
    } > "${PINGPONG_DIR}/r${pane_idx}.sh"

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"
        if echo "${content}" | grep -q "login:"; then
            tmux send-keys -t "${pane}" "root" Enter
            sleep 3
            tmux send-keys -t "${pane}" "mount /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "${pane}" "sh /mnt/pingpong/r${pane_idx}.sh" Enter
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            tmux send-keys -t "${pane}" "mount /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "${pane}" "sh /mnt/pingpong/r${pane_idx}.sh" Enter
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "[harness] WARNING: timed out waiting for shell prompt in pane ${pane}" >&2
}

auto_login_and_run "${SESSION}:0.5" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "/mnt/pingpong/freertos-showcase/hello-arm-linux" &
auto_login_and_run "${SESSION}:0.6" \
    "/mnt/pingpong/freertos-showcase/hello-riscv-linux" &
auto_login_and_run "${SESSION}:0.7" \
    "cp /mnt/pingpong/freertos-showcase/hello-mips-linux /tmp/hello-mips-linux && /tmp/hello-mips-linux" &

# ── Monitor ──────────────────────────────────────────────────────────────────
# Poll the FreeRTOS pane (0.4) directly via tmux capture-pane (avoids all
# pipe-pane buffering issues).  Set a large scroll buffer so we see history.
tmux set-option -t "${SESSION}" history-limit 50000

echo "[harness] Monitoring for \"${PASS_STRING}\" (timeout ${HARNESS_TIMEOUT}s)..."
elapsed=0
while (( elapsed < HARNESS_TIMEOUT )); do
    pane_content="$(tmux capture-pane -p -t "${SESSION}:0.4" -S -50000 2>/dev/null)"

    if echo "${pane_content}" | grep -q "${PASS_STRING}"; then
        echo "[harness] PASS after ${elapsed}s"
        echo "=== Matching FreeRTOS pane output ==="
        echo "${pane_content}" | grep -E "received hello|flag=1|\[diag\]" | tail -20
        # Dump full FreeRTOS pane to log for record
        echo "${pane_content}" > "${FREERTOS_LOG}"
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        echo "[harness] t=${elapsed}s — FreeRTOS pane tail:"
        echo "${pane_content}" | tail -3
    fi

    sleep 2
    (( elapsed += 2 ))
done

echo "[harness] FAIL: timeout after ${HARNESS_TIMEOUT}s"
echo "=== FreeRTOS pane (last 30 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.4" -S -50000 2>/dev/null | tail -30 || true
echo ""
echo "=== ARM Linux pane (last 20 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.5" 2>/dev/null | tail -20 || true
exit 1
