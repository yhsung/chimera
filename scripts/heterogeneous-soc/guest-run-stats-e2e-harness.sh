#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-run-stats-e2e-harness.sh — headless pass/fail test for ARM-Linux-side
# consumption of the FreeRTOS stats snapshot channel (IVSHMEM3).
#
# Launches FreeRTOS (with the 3 mandatory ivshmem channels: ARM/RISCV/MIPS,
# plus the stats channel) and an ARM Linux guest running linux-arm-stats.
# Verifies:
#   1. FreeRTOS boots and publishes the stats snapshot magic
#      ("[freertos] showcase task started")
#   2. linux-arm-stats finds the stats BAR2 via sysfs PCI scan
#      ("[stats] logging to ...")
#   3. linux-arm-stats observes a generation change and logs it
#      ("[stats] gen=<N> logged", N>=1)
#   4. chimera-cross-domain.log contains a correctly-formatted snapshot line
#      ("gen=<N> arm=...")
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   STATS_E2E_TIMEOUT  seconds to wait for all pass conditions (default 240)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${STATS_E2E_TIMEOUT:-240}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="stats-e2e-${RUN_ID}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

# ---- Prerequisites check ----
MISSING=""
for f in "${FREERTOS_DEMO_ELF}" "${ARM_KERNEL_IMAGE}" "${ARM_INITRD_IMAGE}" \
         "${ARM_DEBIAN_DISK}" "${ARM_UEFI_BIOS}" \
         "${FREERTOS_SHOWCASE_DIR}/linux-arm-stats"; do
    if [[ ! -f "$f" ]]; then
        MISSING+="  MISSING: ${f}\n"
    fi
done
if [[ -n "${MISSING}" ]]; then
    _fail "Missing required artifacts:"
    printf "%b" "${MISSING}"
    _fail "Build the showcase first via guest-build-freertos-showcase.sh"
    exit 1
fi

FREERTOS_QEMU="$(find_qemu_system_binary qemu-system-arm)"
ARM_QEMU="$(find_qemu_system_binary qemu-system-aarch64)"

# ---- tmux session (2-pane layout) ----
#   pane 0.0: FreeRTOS QEMU
#   pane 0.1: ARM Linux QEMU
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on
tmux split-window -v -t "${SESSION}:0.0" -l 50%

# ---- ivshmem servers (background) ----
# FreeRTOS requires the ARM, RISCV, and MIPS ivshmem chardevs to be present;
# the stats channel is the one this harness actually exercises.
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}"  -M ivshmem-stats-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 4 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.0) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${FREERTOS_QEMU}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -chardev socket,id=statsft,path='${IVSHMEM_STATS_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter

# ---- ARM Linux QEMU (pane 0.1, stats ivshmem-doorbell only) ----
_info "Starting ARM Linux QEMU..."
tmux send-keys -t "${SESSION}:0.1" \
    "exec '${ARM_QEMU}' \
    -machine virt,gic-version=3 \
    -cpu cortex-a53 -m 512M -smp 2 \
    -bios '${ARM_UEFI_BIOS}' \
    -kernel '${ARM_KERNEL_IMAGE}' \
    -initrd '${ARM_INITRD_IMAGE}' \
    -append 'console=ttyAMA0 root=/dev/vda rw' \
    -chardev socket,id=ivshmem_stats,path='${IVSHMEM_STATS_FREERTOS_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem_stats,vectors=${IVSHMEM_VECTORS} \
    -drive file='${ARM_DEBIAN_DISK}',format=qcow2,if=virtio \
    -virtfs local,path='${PINGPONG_DIR}',mount_tag=${PINGPONG_SHARE_TAG},security_model=none,id=${PINGPONG_SHARE_TAG} \
    -nographic" Enter

# ---- Auto-login and launch linux-arm-stats ----
auto_login_and_run() {
    local pane="$1"
    shift
    local cmds=("$@")
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"
        if echo "${content}" | grep -q "login:"; then
            tmux send-keys -t "${pane}" "root" Enter
            sleep 3
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        fi
        sleep 3
        (( ++elapsed ))
    done
    echo "[harness] WARNING: timed out waiting for shell prompt in pane ${pane}" >&2
    return 1
}

auto_login_and_run "${SESSION}:0.1" \
    "mount /mnt/${PINGPONG_SHARE_TAG}" \
    "cp /mnt/${PINGPONG_SHARE_TAG}/freertos-showcase/linux-arm-stats /tmp/" \
    "/tmp/linux-arm-stats &" \
    "sleep 1 && tail -F /var/log/chimera-log/chimera-cross-domain.log &" &

# ---- Monitor loop ----
elapsed=0
FREERTOS_SEEN=0
STATS_STARTED=0
STATS_GEN_LOGGED=0
STATS_FILE_LINE=0

while (( elapsed < TIMEOUT )); do
    if [[ "${FREERTOS_SEEN}" -eq 0 ]]; then
        ft_content="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"
        if echo "${ft_content}" | grep -q "showcase task started"; then
            FREERTOS_SEEN=1
            _ok "FreeRTOS showcase task started (stats magic published)"
        fi
    fi

    arm_content="$(tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null)"

    if [[ "${STATS_STARTED}" -eq 0 ]] && echo "${arm_content}" | grep -q '\[stats\] logging to'; then
        STATS_STARTED=1
        _ok "linux-arm-stats found the stats BAR2 and opened the log file"
    fi

    if [[ "${STATS_GEN_LOGGED}" -eq 0 ]] && echo "${arm_content}" | grep -Eq '\[stats\] gen=[1-9][0-9]* logged'; then
        STATS_GEN_LOGGED=1
        _ok "linux-arm-stats observed a generation change and logged it"
    fi

    if [[ "${STATS_FILE_LINE}" -eq 0 ]] && echo "${arm_content}" | grep -Eq 'gen=[1-9][0-9]* arm='; then
        STATS_FILE_LINE=1
        _ok "chimera-cross-domain.log contains a correctly-formatted snapshot line"
    fi

    if [[ "${FREERTOS_SEEN}" -eq 1 ]] && [[ "${STATS_STARTED}" -eq 1 ]] && \
       [[ "${STATS_GEN_LOGGED}" -eq 1 ]] && [[ "${STATS_FILE_LINE}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — all four conditions met"
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[harness] t=%3ds  FreeRTOS=%d  StatsStarted=%d  GenLogged=%d  FileLine=%d\n" \
            "${elapsed}" "${FREERTOS_SEEN}" "${STATS_STARTED}" "${STATS_GEN_LOGGED}" "${STATS_FILE_LINE}"
    fi

    sleep 2
    (( ++elapsed ))
done

# FAIL
echo ""
_fail "FAIL: timeout after ${TIMEOUT}s"
[[ "${FREERTOS_SEEN}"    -eq 0 ]] && _fail "  FreeRTOS showcase task started: NOT SEEN"
[[ "${STATS_STARTED}"    -eq 0 ]] && _fail "  [stats] logging to ...: NOT SEEN"
[[ "${STATS_GEN_LOGGED}" -eq 0 ]] && _fail "  [stats] gen=<N> logged (N>=1): NOT SEEN"
[[ "${STATS_FILE_LINE}"  -eq 0 ]] && _fail "  chimera-cross-domain.log snapshot line: NOT SEEN"
echo "=== FreeRTOS pane tail ==="
tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null | tail -20 || true
echo "=== ARM Linux pane tail ==="
tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null | tail -20 || true
exit 1
