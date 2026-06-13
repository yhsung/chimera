#!/usr/bin/env bash
# guest-run-riscv-hello-harness.sh — headless pass/fail test for the
# RISCV-Linux <-> FreeRTOS HELLO/ACK handshake over IVSHMEM1.
#
# Launches FreeRTOS (with the 3 mandatory ivshmem channels: ARM/RISCV/MIPS)
# and a RISC-V Linux guest running syslog-riscv-linux with
# SYSLOG_INTERVAL_SEC=1 for fast round trips. Verifies:
#   1. FreeRTOS boots and IVSHMEM1 IRQ wiring is initialised
#      ("[freertos] showcase task started")
#   2. RISCV-Linux completes >=5 HELLO/ACK round trips over IVSHMEM1
#      ("[riscv-linux] ACK   #...")
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   RISCV_HELLO_TIMEOUT  seconds to wait for both pass conditions (default 240)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${RISCV_HELLO_TIMEOUT:-240}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="riscv-hello-${RUN_ID}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

# ---- Prerequisites check ----
MISSING=""
for f in "${FREERTOS_DEMO_ELF}" "${RISCV_KERNEL_IMAGE}" "${RISCV_INITRD_IMAGE}" \
         "${RISCV_DEBIAN_DISK}" "${RISCV_OPENSBI_BIOS}" \
         "${FREERTOS_SHOWCASE_DIR}/syslog-riscv-linux"; do
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
RISCV_QEMU="$(find_qemu_system_binary qemu-system-riscv64)"

# ---- tmux session (2-pane layout) ----
#   pane 0.0: FreeRTOS QEMU
#   pane 0.1: RISC-V Linux QEMU
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on
tmux split-window -v -t "${SESSION}:0.0" -l 50%

# ---- ivshmem servers (background) ----
# FreeRTOS requires the ARM, RISCV, and MIPS ivshmem chardevs to be present
# even though only the RISCV channel is exercised by this harness.
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"  -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" -M ivshmem-riscv-ft -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  -M ivshmem-mips-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 3 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.0) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${FREERTOS_QEMU}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter

# ---- RISC-V Linux QEMU (pane 0.1, no networking required) ----
_info "Starting RISC-V Linux QEMU..."
tmux send-keys -t "${SESSION}:0.1" \
    "exec '${RISCV_QEMU}' \
    -rtc base=localtime \
    -machine virt,aclint=on \
    -cpu rv64,h=true,v=true \
    -m 512M -smp 2 \
    -bios '${RISCV_OPENSBI_BIOS}' \
    -kernel '${RISCV_KERNEL_IMAGE}' \
    -initrd '${RISCV_INITRD_IMAGE}' \
    -append '${RISCV_KERNEL_CMDLINE}' \
    -chardev socket,id=ivshmem,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem,vectors=${IVSHMEM_VECTORS} \
    -drive file='${RISCV_DEBIAN_DISK}',format=qcow2,if=virtio \
    -virtfs local,path='${PINGPONG_DIR}',mount_tag=${PINGPONG_SHARE_TAG},security_model=none,id=${PINGPONG_SHARE_TAG} \
    -nographic" Enter

# ---- Auto-login and launch syslog-riscv-linux ----
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
    "cp /mnt/${PINGPONG_SHARE_TAG}/freertos-showcase/syslog-riscv-linux /tmp/" \
    "SYSLOG_INTERVAL_SEC=1 /tmp/syslog-riscv-linux &" &

# ---- Monitor loop ----
elapsed=0
FREERTOS_SEEN=0
RISCV_ACK_SEEN=0

while (( elapsed < TIMEOUT )); do
    if [[ "${FREERTOS_SEEN}" -eq 0 ]]; then
        ft_content="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"
        if echo "${ft_content}" | grep -q "showcase task started"; then
            FREERTOS_SEEN=1
            _ok "FreeRTOS showcase task started (IVSHMEM1 IRQ wiring initialised)"
        fi
    fi

    if [[ "${RISCV_ACK_SEEN}" -eq 0 ]]; then
        riscv_content="$(tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null)"
        if echo "${riscv_content}" | grep -q '\[riscv-linux\] ACK'; then
            RISCV_ACK_SEEN=1
            _ok "RISCV-Linux completed >=5 HELLO/ACK round trips over IVSHMEM1"
        fi
    fi

    if [[ "${FREERTOS_SEEN}" -eq 1 ]] && [[ "${RISCV_ACK_SEEN}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — both conditions met"
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[harness] t=%3ds  FreeRTOS=%d  RISCV_ACK=%d\n" \
            "${elapsed}" "${FREERTOS_SEEN}" "${RISCV_ACK_SEEN}"
    fi

    sleep 2
    (( ++elapsed ))
done

# FAIL
echo ""
_fail "FAIL: timeout after ${TIMEOUT}s"
if [[ "${FREERTOS_SEEN}" -eq 0 ]]; then
    _fail "  FreeRTOS showcase task started: NOT SEEN"
    echo "  === FreeRTOS pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null | tail -20 || true
fi
if [[ "${RISCV_ACK_SEEN}" -eq 0 ]]; then
    _fail "  [riscv-linux] ACK: NOT SEEN"
    echo "  === RISC-V Linux pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null | tail -20 || true
fi
exit 1
