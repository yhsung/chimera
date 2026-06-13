#!/usr/bin/env bash
# guest-run-can-e2e-harness.sh — headless end-to-end CAN test.
#
# Launches FreeRTOS + ARM Linux with CAN passthrough, sends a CAN frame
# from Lima's vcan0, and verifies:
#   1. FreeRTOS prints "CAN RX:" (CAN controller decode)
#   2. ARM Linux can-log-arm-linux daemon logs a "CAN/freertos" line
#      (proving IVSHMEM5 forwarding works)
#   3. ARM Linux daemon logs a "CAN/socketcan" line
#      (proving kvaser_pci -> can0 path works)
#
# Requires: Debian boot assets (kernel, initrd, qcow2) and the ARM-Linux
# cross-compiled daemon to be built already.
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   CAN_E2E_TIMEOUT    seconds to wait for all pass conditions (default 180)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${CAN_E2E_TIMEOUT:-180}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_DIR="${HARNESS_LOG_DIR:-/tmp/harness-logs}"
SESSION="can-e2e-${RUN_ID}"
FREERTOS_LOG="${LOG_DIR}/can-e2e-freertos-${RUN_ID}.log"
mkdir -p "${LOG_DIR}"

CAN_TEST_ID="${CAN_TEST_ID:-123}"
CAN_TEST_DATA="${CAN_TEST_DATA:-DEADBEEF}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

QEMU_PIDS=""
cleanup() {
    if [[ -n "${QEMU_PIDS}" ]]; then
        for pid in ${QEMU_PIDS}; do
            kill "${pid}" 2>/dev/null || true
        done
    fi
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" \
          "${IVSHMEM_BOOTLOG_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

# ---- Prerequisites check ----
MISSING=""
for f in "${FREERTOS_DEMO_ELF}" "${ARM_KERNEL_IMAGE}" "${ARM_INITRD_IMAGE}" \
         "${ARM_DEBIAN_DISK}" "${FREERTOS_SHOWCASE_DIR}/can-log-arm-linux"; do
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

ARM_QEMU="$(find_qemu_system_binary qemu-system-aarch64)"
FREERTOS_QEMU="$(find_qemu_system_binary qemu-system-arm)"

# ---- vcan0 + CAP_NET_RAW ----
sudo modprobe vcan 2>/dev/null || true
ip link show "${CAN_VCAN_IF}" >/dev/null 2>&1 || sudo ip link add dev "${CAN_VCAN_IF}" type vcan
sudo ip link set "${CAN_VCAN_IF}" up
sudo setcap cap_net_raw+eip "${ARM_QEMU}" 2>/dev/null || true
sudo setcap cap_net_raw+eip "${FREERTOS_QEMU}" 2>/dev/null || true

# ---- tmux session (simple 2-pane layout) ----
#   pane 0.0: FreeRTOS QEMU
#   pane 0.1: ARM Linux QEMU
# ivshmem servers run in background (not in tmux panes)
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on
tmux split-window -v -t "${SESSION}:0.0" -l 50%

# ivshmem servers (background)
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}" \
         "${IVSHMEM_BOOTLOG_DIR}" "${IVSHMEM_CAN_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}"  -M ivshmem-stats-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_BOOTLOG_SOCKET}"        -M ivshmem-bootlog   -l "${IVSHMEM_BOOTLOG_SIZE}" -n "${IVSHMEM_BOOTLOG_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_CAN_FREERTOS_SOCKET}"   -M ivshmem-can-ft    -l "${IVSHMEM_CAN_FREERTOS_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

# Wait for all six sockets.
for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" \
                 "${IVSHMEM_BOOTLOG_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 6 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.5) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${FREERTOS_QEMU}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft,canbus=canbus0,ivshmem-can-freertos=canft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -chardev socket,id=statsft,path='${IVSHMEM_STATS_FREERTOS_SOCKET}' \
    -chardev socket,id=bootft,path='${IVSHMEM_BOOTLOG_SOCKET}' \
    -object can-bus,id=canbus0 \
    -object 'can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0' \
    -chardev socket,id=canft,path='${IVSHMEM_CAN_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter
sleep 3

# ---- ARM Linux QEMU (pane 0.1, user-mode net) ----
# Note: Use direct QEMU invocation instead of guest-run-arm-phase5.sh
# because that script requires TAP networking (tap-arm) which needs root.
_info "Starting ARM Linux QEMU with CAN..."
tmux send-keys -t "${SESSION}:0.1" \
    "exec '${ARM_QEMU}' \
    -machine virt,gic-version=3 \
    -cpu cortex-a53 -m 512M -smp 2 \
    -bios '${ARM_UEFI_BIOS}' \
    -kernel '${ARM_KERNEL_IMAGE}' \
    -initrd '${ARM_INITRD_IMAGE}' \
    -append 'console=ttyAMA0 root=/dev/vda rw' \
    -chardev socket,id=ivshmem,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem,vectors=${IVSHMEM_VECTORS} \
    -chardev socket,id=ivshmem_boot,path='${IVSHMEM_BOOTLOG_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
    -chardev socket,id=ivshmem_can,path='${IVSHMEM_CAN_FREERTOS_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem_can,vectors=${IVSHMEM_VECTORS} \
    -object can-bus,id=canbus0 \
    -object 'can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0' \
    -device kvaser_pci,canbus=canbus0 \
    -drive file='${ARM_DEBIAN_DISK}',format=qcow2,if=virtio \
    -virtfs local,path='${PINGPONG_DIR}',mount_tag=pingpong,security_model=none,id=pingpong \
    -nographic" Enter

# ---- Auto-login and launch CAN daemon ----
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
            tmux send-keys -t "${pane}" "mount /mnt/pingpong" Enter
            sleep 1
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            tmux send-keys -t "${pane}" "mount /mnt/pingpong" Enter
            sleep 1
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
    "mount /mnt/pingpong" \
    "ip link set can0 type can bitrate 500000 2>/dev/null; ip link set can0 up 2>/dev/null" \
    "cp /mnt/pingpong/freertos-showcase/can-log-arm-linux /tmp/ && /tmp/can-log-arm-linux &" &

# Note: syslog-arm-linux is intentionally not launched here — the CAN E2E
# harness focuses on CAN forwarding. The ivshmem HELLO/ACK channel is
# tested by the freertos-harness and debian-harness.

# ---- Monitor loop ----
_info "Sending CAN frame: ${CAN_VCAN_IF} ${CAN_TEST_ID}#${CAN_TEST_DATA}"
cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}"

elapsed=0
FREERTOS_CAN_SEEN=0
CAN_LOG_SEEN_FREERTOS=0
CAN_LOG_SEEN_SOCKETCAN=0

while (( elapsed < TIMEOUT )); do
    if (( elapsed > 0 && elapsed % 10 == 0 )); then
        cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}" 2>/dev/null || true
    fi

    # Check FreeRTOS pane for CAN RX.
    if [[ "${FREERTOS_CAN_SEEN}" -eq 0 ]]; then
        ft_content="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"
        if echo "${ft_content}" | grep -qi "CAN RX:"; then
            FREERTOS_CAN_SEEN=1
            _ok "FreeRTOS received and decoded CAN frame"
        fi
    fi

    # Check ARM daemon output via tmux pane (daemon prints [can] stderr).
    if [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 0 ]] || [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 0 ]]; then
        arm_content="$(tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null)"
        if [[ -n "${arm_content}" ]]; then
            if [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 0 ]] && \
               echo "${arm_content}" | grep -qi "CAN/socketcan"; then
                CAN_LOG_SEEN_SOCKETCAN=1
                _ok "ARM daemon logged CAN/socketcan frame (kvaser_pci path works)"
            fi
            if [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 0 ]] && \
               echo "${arm_content}" | grep -qi "CAN/freertos"; then
                CAN_LOG_SEEN_FREERTOS=1
                _ok "ARM daemon logged CAN/freertos frame (IVSHMEM5 path works)"
            fi
        fi
    fi

    if [[ "${FREERTOS_CAN_SEEN}" -eq 1 ]] && \
       [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 1 ]] && \
       [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — all three CAN path conditions met"
        echo "  \342\234\223 FreeRTOS CAN RX decode"
        echo "  \342\234\223 CAN/freertos (IVSHMEM5 forwarding)"
        echo "  \342\234\223 CAN/socketcan (kvaser_pci path)"
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[harness] t=%3ds  FreeRTOS_CAN=%d  CAN/freertos=%d  CAN/socketcan=%d\n" \
            "${elapsed}" "${FREERTOS_CAN_SEEN}" "${CAN_LOG_SEEN_FREERTOS}" "${CAN_LOG_SEEN_SOCKETCAN}"
    fi

    sleep 2
    (( ++elapsed ))
done

# FAIL
echo ""
_fail "FAIL: timeout after ${TIMEOUT}s"
if [[ "${FREERTOS_CAN_SEEN}" -eq 0 ]]; then
    _fail "  FreeRTOS CAN RX:   NOT SEEN"
    echo "  === FreeRTOS pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null | tail -20 || true
fi
if [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 0 ]]; then
    _fail "  CAN/freertos:      NOT SEEN (IVSHMEM5 may be down)"
fi
if [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 0 ]]; then
    _fail "  CAN/socketcan:     NOT SEEN (kvaser_pci or can0 may be down)"
fi
echo "=== ARM Linux pane (last 20) ==="
tmux capture-pane -p -t "${SESSION}:0.1" 2>/dev/null | tail -20 || true
exit 1
