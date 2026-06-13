# CAN End-to-End Forwarding Harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing `guest-run-can-harness.sh` to also verify the ARM-side `can-log-arm-linux` daemon receives CAN frames forwarded through IVSHMEM5 from FreeRTOS.

**Architecture:** The current CAN harness only tests FreeRTOS CAN RX (matching `CAN RX:` in FreeRTOS UART). Add an ARM-Linux guest launch alongside FreeRTOS, start the `can-log-arm-linux` daemon inside it, send a CAN frame from Lima `vcan0`, and verify the ARM-side log file `/var/log/chimera-log/can-bus.log` contains a `CAN/freertos` line (proving the frame arrived via IVSHMEM5) and optionally a `CAN/socketcan` line (proving the frame arrived via the `kvaser_pci` → `can0` path).

**Tech Stack:** Bash (harness extension), QEMU (FreeRTOS + ARM Linux guests), ARM-Linux cross-compiled daemon

---

## Design Decisions

1. **Keep the existing CAN harness intact.** Create a new `guest-run-can-e2e-harness.sh` rather than modifying the existing one, so the simpler FreeRTOS-only CAN test stays available for CI gate and fast iteration.

2. **ARM Linux boots from Debian rootfs qcow2.** This requires the Debian rootfs artifacts (kernel, initrd, qcow2 disk) to already exist. The harness checks for them first and skips with a clear message if they're absent.

3. **ARM guest gets minimal CAN setup:** `kvaser_pci` + `can-bus` backend (same as the showcase) + `can-log-arm-linux` daemon launched via `auto_login_and_run`.

4. **Log verification via SSH.** After the CAN frame is sent and enough time passes, SSH into the ARM guest (port 2222) and check `/var/log/chimera-log/can-bus.log` for both source tags.

---

## File Structure

### New Files
| File | Purpose |
|---|---|
| `scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh` | End-to-end CAN harness: FreeRTOS + ARM Linux + can-log daemon |

### Modified Files
| File | Change |
|---|---|
| `CLAUDE.md` | Document the new harness |

---

### Task 1: Create the CAN end-to-end harness

**Files:**
- Create: `scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh`

- [ ] **Step 1: Write the harness preamble and prerequisites check**

```bash
#!/usr/bin/env bash
# guest-run-can-e2e-harness.sh — headless end-to-end CAN test.
#
# Launches FreeRTOS + ARM Linux with CAN passthrough, sends a CAN frame
# from Lima's vcan0, and verifies:
#   1. FreeRTOS prints "CAN RX:" (CAN controller decode)
#   2. ARM Linux can-log-arm-linux daemon logs a "CAN/freertos" line
#      (proving IVSHMEM5 forwarding works)
#   3. ARM Linux daemon logs a "CAN/socketcan" line
#      (proving kvaser_pci → can0 path works)
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

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  ✗ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
```

- [ ] **Step 2: Add cleanup and pre-run checks**

```bash
cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
    pkill -f "qemu-system-aarch64.*can-e2e-arm" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-arm-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-riscv-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-mips-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-stats-ft" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-bootlog" 2>/dev/null || true
    pkill -f "ivshmem-server.*ivshmem-can-ft" 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" \
          "${IVSHMEM_BOOTLOG_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

# ── Prerequisites check ────────────────────────────────────────────────────
# Check required ARM boot assets exist.
MISSING=""
require_file_present() {
    local f="$1" label="$2"
    if [[ ! -f "$f" ]]; then
        MISSING+="  ${label}: ${f}\n"
    fi
}
require_file_present "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
require_file_present "${ARM_KERNEL_IMAGE}" "ARM kernel image"
require_file_present "${ARM_INITRD_IMAGE}" "ARM initrd image"
require_file_present "${ARM_DEBIAN_DISK}" "ARM Debian rootfs"
require_file_present "${CAN_LOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/can-log-arm-linux}" "can-log-arm-linux binary"
require_file_present "${HELLO_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-arm-linux}" "hello-arm-linux binary"

if [[ -n "${MISSING}" ]]; then
    _fail "Missing required artifacts:"
    printf "%b" "${MISSING}"
    _fail "Build the showcase first via guest-build-freertos-showcase.sh"
    exit 1
fi

# Find QEMU binaries.
ARM_QEMU="$(find_qemu_system_binary qemu-system-aarch64)"
FREERTOS_QEMU="$(find_qemu_system_binary qemu-system-arm)"

# ── vcan0 + CAP_NET_RAW ──────────────────────────────────────────────────
sudo modprobe vcan 2>/dev/null || true
ip link show "${CAN_VCAN_IF}" >/dev/null 2>&1 || sudo ip link add dev "${CAN_VCAN_IF}" type vcan
sudo ip link set "${CAN_VCAN_IF}" up
sudo setcap cap_net_raw+eip "${ARM_QEMU}" 2>/dev/null || true
sudo setcap cap_net_raw+eip "${FREERTOS_QEMU}" 2>/dev/null || true
```

- [ ] **Step 3: Add tmux session setup with ivshmem servers**

```bash
# ── tmux session layout ───────────────────────────────────────────────────
#  pane 0: ARM ivshmem server
#  pane 1: RISCV ivshmem server (mandatory for FreeRTOS boot)
#  pane 2: MIPS ivshmem server
#  pane 3: STATS ivshmem server
#  pane 4: BOOTLOG ivshmem server (mandatory for FreeRTOS boot)
#  pane 5: FreeRTOS QEMU
#  pane 6: ARM Linux QEMU (with CAN)
tmux new-session -d -s "${SESSION}" -x 220 -y 55
# Set large history before any output.
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on

# ivshmem servers (direct launch, no separate panes needed — use background)
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}" \
         "${IVSHMEM_BOOTLOG_DIR}" "${IVSHMEM_CAN_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}"  -M ivshmem-stats-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_BOOTLOG_SOCKET}"        -M ivshmem-bootlog   -l "${IVSHMEM_BOOTLOG_SIZE}" -n "${IVSHMEM_BOOTLOG_VECTORS}" &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_CAN_FREERTOS_SOCKET}"   -M ivshmem-can-ft    -l "${IVSHMEM_CAN_FREERTOS_SIZE}" -n "${IVSHMEM_VECTORS}" &

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
```

- [ ] **Step 4: Launch FreeRTOS in tmux pane 5**

```bash
# ── FreeRTOS QEMU (pane 5) ────────────────────────────────────────────────
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.5" \
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
    -serial file:'${FREERTOS_LOG}' -nographic" Enter

sleep 3  # Give FreeRTOS time to initialize
```

- [ ] **Step 5: Launch ARM Linux in tmux pane 6 and auto-login**

```bash
# ── ARM Linux QEMU (pane 6) ────────────────────────────────────────────────
_info "Starting ARM Linux QEMU with CAN..."
tmux send-keys -t "${SESSION}:0.6" \
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
    -netdev user,id=eth0,hostfwd=tcp::${ARM_SSH_PORT}-:22 \
    -device virtio-net-pci,netdev=eth0 \
    -nographic" Enter

# ── Auto-login and launch CAN daemon ──────────────────────────────────────
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
        (( elapsed += 3 ))
    done
    echo "[harness] WARNING: timed out waiting for shell prompt in pane ${pane}" >&2
    return 1
}

# On ARM: bring up can0, start the CAN log daemon, and send a HELLO
# (so FreeRTOS ivshmem channel is exercised too).
auto_login_and_run "${SESSION}:0.6" \
    "mount /mnt/pingpong" \
    "ip link set can0 type can bitrate 500000 2>/dev/null; ip link set can0 up 2>/dev/null" \
    "cp /mnt/pingpong/freertos-showcase/can-log-arm-linux /tmp/ && /tmp/can-log-arm-linux &" \
    "/mnt/pingpong/freertos-showcase/hello-arm-linux" &
```

- [ ] **Step 6: Main monitor loop — send CAN frame and check all pass conditions**

```bash
# ── Monitor loop ──────────────────────────────────────────────────────────
# Pass conditions:
#   1. FreeRTOS UART shows "CAN RX:" (FreeRTOS decoded the frame)
#   2. ARM log shows "CAN/freertos" (frame arrived via IVSHMEM5)
#   3. ARM log shows "CAN/socketcan" (frame arrived via can0/kvaser_pci)
_info "Sending CAN frame: ${CAN_VCAN_IF} ${CAN_TEST_ID}#${CAN_TEST_DATA}"
cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}"

elapsed=0
FREERTOS_CAN_SEEN=0
CAN_LOG_SEEN_FREERTOS=0
CAN_LOG_SEEN_SOCKETCAN=0

while (( elapsed < TIMEOUT )); do
    # Re-send the CAN frame periodically in case it was missed.
    if (( elapsed > 0 && elapsed % 10 == 0 )); then
        cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}" 2>/dev/null || true
    fi

    # Check FreeRTOS serial log.
    if [[ "${FREERTOS_CAN_SEEN}" -eq 0 ]] && \
       grep -qi "CAN RX:" "${FREERTOS_LOG}" 2>/dev/null; then
        FREERTOS_CAN_SEEN=1
        _ok "FreeRTOS received and decoded CAN frame"
    fi

    # Check ARM daemon log via SSH (non-blocking, best-effort).
    if [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 0 ]] || [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 0 ]]; then
        local arm_log
        arm_log="$(timeout 5 ssh -p "${ARM_SSH_PORT}" \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 \
            root@localhost 'cat /var/log/chimera-log/can-bus.log 2>/dev/null || echo "LOG_NOT_FOUND"' 2>/dev/null || true)"

        if [[ -n "${arm_log}" ]]; then
            if [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 0 ]] && \
               echo "${arm_log}" | grep -q "CAN/freertos"; then
                CAN_LOG_SEEN_FREERTOS=1
                _ok "ARM daemon logged CAN/freertos frame (IVSHMEM5 path works)"
            fi
            if [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 0 ]] && \
               echo "${arm_log}" | grep -q "CAN/socketcan"; then
                CAN_LOG_SEEN_SOCKETCAN=1
                _ok "ARM daemon logged CAN/socketcan frame (kvaser_pci path works)"
            fi
        fi
    fi

    # All pass conditions met?
    if [[ "${FREERTOS_CAN_SEEN}" -eq 1 ]] && \
       [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 1 ]] && \
       [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — all three conditions met:"
        echo "  ✓ FreeRTOS CAN RX decode"
        echo "  ✓ CAN/freertos (IVSHMEM5 forwarding)"
        echo "  ✓ CAN/socketcan (kvaser_pci path)"
        echo ""
        echo "=== FreeRTOS CAN output ==="
        grep -i "CAN" "${FREERTOS_LOG}" 2>/dev/null | tail -5
        echo ""
        echo "=== ARM daemon log ==="
        echo "${arm_log}" | tail -5
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[harness] t=%3ds  FreeRTOS_CAN=%d  CAN/freertos=%d  CAN/socketcan=%d\n" \
            "${elapsed}" "${FREERTOS_CAN_SEEN}" "${CAN_LOG_SEEN_FREERTOS}" "${CAN_LOG_SEEN_SOCKETCAN}"
    fi

    sleep 2
    (( elapsed += 2 ))
done
```

- [ ] **Step 7: Timeout failure reporting**

```bash
# ── FAIL ──────────────────────────────────────────────────────────────────
echo ""
_fail "FAIL: timeout after ${TIMEOUT}s"

if [[ "${FREERTOS_CAN_SEEN}" -eq 0 ]]; then
    _fail "  FreeRTOS CAN RX:   NOT SEEN"
    echo "  === FreeRTOS serial tail ==="
    tail -20 "${FREERTOS_LOG}" 2>/dev/null || true
fi
if [[ "${CAN_LOG_SEEN_FREERTOS}" -eq 0 ]]; then
    _fail "  CAN/freertos:      NOT SEEN (IVSHMEM5 may be down)"
fi
if [[ "${CAN_LOG_SEEN_SOCKETCAN}" -eq 0 ]]; then
    _fail "  CAN/socketcan:     NOT SEEN (kvaser_pci or can0 may be down)"
fi

# Dump ARM pane for diagnostics.
echo ""
echo "=== ARM Linux pane (last 20 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.6" 2>/dev/null | tail -20 || true

echo ""
echo "=== FreeRTOS pane (last 20 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.5" -S -50000 2>/dev/null | tail -20 || true

exit 1
```

- [ ] **Step 8: Commit**

```bash
chmod +x scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh
git add scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh
git commit -m "test(can): add end-to-end CAN forwarding harness
Verifies FreeRTOS CAN RX decode, CAN/freertos IVSHMEM5 forwarding
path, and CAN/socketcan kvaser_pci path by sending a frame from
Lima vcan0 and checking both FreeRTOS UART and ARM daemon log.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Run the harness on Lima and verify

- [ ] **Step 1: Run the harness**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh
```

Expected output: All three pass conditions met within 180s timeout.

- [ ] **Step 2: Debug failures if any**

Common failure modes:
- **Missing boot assets:** Run `guest-build-freertos-showcase.sh` first.
- **ARM Linux fails to boot:** Check `ARM_UEFI_BIOS` path and kernel/initrd exist.
- **SSH connection refused:** ARM guest may still be booting. Increase timeout.
- **can0 not up in ARM:** The `ip link set can0 up` may fail if `kvaser_pci` didn't probe. Check ARM pane for kernel messages.
- **IVSHMEM5 not forwarding:** Verify `can-log-arm-linux` was cross-compiled and injected. Check ARM pane for `[can]` stderr output.

- [ ] **Step 3: Update CLAUDE.md**

After the existing CAN harness doc in CLAUDE.md, add:

```
### `guest-run-can-e2e-harness.sh` (full-stack, ~3 min)

End-to-end CAN verification: launches FreeRTOS + ARM Linux with CAN
passthrough, sends a CAN frame from Lima's `vcan0`, and verifies:
1. FreeRTOS decodes the frame (`CAN RX:` in UART)
2. ARM `can-log-arm-linux` daemon logs `CAN/freertos` (IVSHMEM5 path)
3. ARM daemon logs `CAN/socketcan` (kvaser_pci → can0 path)

Requires all showcase build artifacts. Exit 0 only when all three
conditions are met.

**Environment overrides:** `CAN_E2E_TIMEOUT` (default 180).

**Run:**
```bash
limactl shell qemu-dev -- \
    bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh
```
```

- [ ] **Step 4: Commit docs**

```bash
git add CLAUDE.md
git commit -m "docs: document CAN end-to-end harness in CLAUDE.md
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:** All three CAN pass conditions are tested: FreeRTOS decode (UART), IVSHMEM5 forwarding (CAN/freertos in ARM log), and kvaser_pci path (CAN/socketcan in ARM log). The existing simple CAN harness is preserved unchanged.

**2. Placeholder scan:** No "TBD", "TODO", or vague steps. All bash code is complete and follows existing patterns from `guest-run-freertos-harness.sh` and `guest-run-can-harness.sh`.

**3. Type consistency:** Uses `ARM_QEMU`, `FREERTOS_QEMU`, `ARM_SSH_PORT`, `ARM_UEFI_BIOS`, `CAN_LOG_ARM_BINARY` — all defined in `common.sh`. `CAN_E2E_TIMEOUT` follows the existing `CAN_HARNESS_TIMEOUT` naming convention. `auto_login_and_run` matches the same pattern in `guest-run-debian-harness.sh`.
