#!/usr/bin/env bash
# guest-run-debian-harness.sh — headless pass/fail harness for the Debian ivshmem demo.
#
# Two-stage pipeline:
#   Stage 1: Install prerequisites (debootstrap, qemu-user-static, cross-compilers).
#   Stage 2: Full-stack headless launch — fetch Debian kernel .debs, create qcow2
#            rootfs disks, extract kernels, build FreeRTOS showcase, boot all
#            guests, and verify FreeRTOS receives hello messages from every sender.
#
# Pass condition: FreeRTOS UART contains:
#   "received hello from arm-linux"
#   "received hello from riscv-linux"
#   "received hello from mips-linux"
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   HARNESS_TIMEOUT   seconds to wait for all three pass strings (default 600)
#   HARNESS_LOG_DIR   directory for log files (default /tmp/debian-harness-logs)
#   SKIP_PREREQS      skip apt install if non-empty
#   SKIP_ROOTFS       skip debootstrap rootfs creation if non-empty
#   SKIP_FETCH        skip kernel .deb download if non-empty
#   SKIP_BUILD        skip FreeRTOS showcase build if non-empty
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
REPO="${CHIMERA_ROOT}"

HARNESS_TIMEOUT="${HARNESS_TIMEOUT:-600}"
LOG_DIR="${HARNESS_LOG_DIR:-/tmp/debian-harness-logs}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="debian-harness-${RUN_ID}"
FREERTOS_LOG="${LOG_DIR}/freertos-${RUN_ID}.log"
SETUP_LOG="${LOG_DIR}/setup-${RUN_ID}.log"

# Pass condition: all three senders must be acknowledged.
PASS_STRINGS=(
    "received hello from arm-linux"
    "received hello from riscv-linux"
    "received hello from mips-linux"
)

mkdir -p "${LOG_DIR}"

# ── helpers ─────────────────────────────────────────────────────────────────

_step()  { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }
_ok()    { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_warn()  { printf '\033[0;33m  ⚠ %s\033[0m\n' "$*"; }
_fail()  { printf '\033[0;31m  ✗ %s\033[0m\n' "$*"; }

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
    pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
    pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
    pkill -f "qemu-system-mips.*run-chimera"             2>/dev/null || true
    pkill -f "ivshmem-server"                            2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" \
          "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── Pre-run cleanup ──────────────────────────────────────────────────────────

echo "[debian-harness] Killing orphan processes and removing stale sockets..."
pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
pkill -f "qemu-system-mips.*run-chimera"             2>/dev/null || true
sleep 0.5
rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" \
      "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
      "${IVSHMEM_MIPS_FREERTOS_SOCKET}" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# Stage 1: Install prerequisites
# ═══════════════════════════════════════════════════════════════════════════════

_step "Stage 1: Installing prerequisites"

if [[ -n "${SKIP_PREREQS:-}" ]]; then
    _warn "SKIP_PREREQS set — skipping apt install"
else
    echo "[debian-harness] Checking and installing packages..."
    bash "${SCRIPT_DIR}/guest-install-lima-guest.sh" \
        > "${SETUP_LOG}" 2>&1 \
        || { _fail "Prerequisite installation failed — see ${SETUP_LOG}"; exit 1; }
    _ok "Prerequisites installed"
fi

# Verify critical packages are present.
for cmd in debootstrap qemu-img mkfs.ext4 dpkg-deb; do
    command -v "${cmd}" &>/dev/null || {
        _fail "${cmd} not found — run without SKIP_PREREQS or install it manually"
        exit 1
    }
done
_ok "Critical tools present: debootstrap, qemu-img, mkfs.ext4, dpkg-deb"

# ═══════════════════════════════════════════════════════════════════════════════
# Stage 2: Full-stack headless launch
# ═══════════════════════════════════════════════════════════════════════════════

_step "Stage 2: Full-stack launch"

# ── 2a. Fetch Debian kernel .deb packages ────────────────────────────────────

if [[ -n "${SKIP_FETCH:-}" ]]; then
    _warn "SKIP_FETCH set — skipping kernel .deb download"
else
    echo "[debian-harness] Fetching Debian kernel packages..."
    bash "${SCRIPT_DIR}/guest-fetch-images.sh" \
        || { _fail "Failed to fetch Debian kernel packages"; exit 1; }
    _ok "Kernel .deb packages fetched"
fi

# ── 2b. Create Debian rootfs qcow2 disks ─────────────────────────────────────

if [[ -n "${SKIP_ROOTFS:-}" ]]; then
    _warn "SKIP_ROOTFS set — skipping rootfs disk creation"
else
    for disk in "${ARM_DEBIAN_DISK}" "${RISCV_DEBIAN_DISK}" "${MIPS_DEBIAN_DISK}"; do
        if [[ -f "${disk}" ]]; then
            _ok "Rootfs disk exists: ${disk} ($(du -sh "${disk}" | cut -f1))"
        fi
    done

    if [[ -f "${ARM_DEBIAN_DISK}" ]] && [[ -f "${RISCV_DEBIAN_DISK}" ]] && [[ -f "${MIPS_DEBIAN_DISK}" ]]; then
        _ok "All three rootfs disks present — skipping debootstrap"
    else
        echo "[debian-harness] Creating Debian rootfs qcow2 disks (this may take several minutes)..."
        bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh" \
            2>&1 | tee -a "${SETUP_LOG}" \
            || { _fail "Rootfs creation failed — see ${SETUP_LOG}"; exit 1; }
    fi
fi

# ── 2c. Extract kernels and initrds from .deb packages ───────────────────────

echo "[debian-harness] Extracting kernels..."
bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh" \
    || { _fail "Kernel extraction failed"; exit 1; }
_ok "Kernels and initrds extracted"

# Verify boot assets exist before launching QEMU.
require_file "${ARM_KERNEL_IMAGE}"       "ARM kernel image"
require_file "${ARM_INITRD_IMAGE}"       "ARM initrd image"
require_file "${ARM_DEBIAN_DISK}"        "ARM Debian rootfs disk"
require_file "${RISCV_KERNEL_IMAGE}"     "RISC-V kernel image"
require_file "${RISCV_INITRD_IMAGE}"     "RISC-V initrd image"
require_file "${RISCV_DEBIAN_DISK}"      "RISC-V Debian rootfs disk"
require_file "${MIPS_KERNEL_IMAGE}"      "MIPS kernel image"
require_file "${MIPS_INITRD_IMAGE}"      "MIPS initrd image"
require_file "${MIPS_DEBIAN_DISK}"       "MIPS Debian rootfs disk"

# ── 2d. Build FreeRTOS showcase ──────────────────────────────────────────────

if [[ -z "${SKIP_BUILD:-}" ]]; then
    echo "[debian-harness] Building FreeRTOS showcase..."
    bash "${SCRIPT_DIR}/guest-build-freertos-showcase.sh" \
        > "${LOG_DIR}/build-${RUN_ID}.log" 2>&1 \
        || { _fail "BUILD FAILED — see ${LOG_DIR}/build-${RUN_ID}.log"; exit 1; }
    _ok "Showcase built"
fi
require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

# Check that hello binaries exist (may be absent if cross-compiler is missing).
MISSING_HELLO=0
for bin in "${HELLO_ARM_BINARY}" "${HELLO_RISCV_BINARY}" "${HELLO_MIPS_BINARY}"; do
    if [[ ! -f "${bin}" ]]; then
        _warn "$(basename "${bin}") not found — MIPS guest will not send hello"
        MISSING_HELLO=1
    fi
done

# ── 2e. Launch tmux session ──────────────────────────────────────────────────
# Same 7-pane layout as guest-run-phase5-tmux.sh:
#   pane 0: ARM ivshmem server
#   pane 1: RISCV ivshmem server
#   pane 2: MIPS ivshmem server
#   pane 3: FreeRTOS QEMU   ← monitored for pass string
#   pane 4: ARM Linux QEMU
#   pane 5: RISCV Linux QEMU
#   pane 6: MIPS Linux QEMU

tmux new-session -d -s "${SESSION}" -x 220 -y 55
# Set large history-limit BEFORE any pane produces output so that early
# FreeRTOS "received hello" messages are never evicted from the buffer.
tmux set-option -t "${SESSION}" history-limit 100000
tmux split-window -v -t "${SESSION}:0.0" -l 80%
tmux split-window -v -t "${SESSION}:0.1" -l 45%
tmux split-window -h -t "${SESSION}:0.0"
tmux split-window -h -t "${SESSION}:0.3"
tmux split-window -h -t "${SESSION}:0.1"
tmux split-window -h -t "${SESSION}:0.5"

BUILD_DIR="${BUILD_DIR:-/home/yhsung.guest/chimera-build-linux}"
PANE_ENV="export CHIMERA_ROOT='${CHIMERA_ROOT}'; export BUILD_DIR='${BUILD_DIR}'; export FREERTOS_DEMO_ELF='${FREERTOS_DEMO_ELF}';"

# ── 2f. Start ivshmem servers ────────────────────────────────────────────────

IVSHMEM_BIN="$(find_ivshmem_server)"
echo "[debian-harness] Starting ivshmem servers..."
# Each server MUST have a unique -M name; without it all three would default
# to the POSIX shm object "ivshmem" and share the same 64 MB — causing all
# three FreeRTOS ivshmem-flat channels to alias to identical memory, making
# only the first channel (ARM) ever visible.
tmux send-keys -t "${SESSION}:0.0" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_ARM_FREERTOS_SOCKET}\" -M ivshmem-arm-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter
tmux send-keys -t "${SESSION}:0.1" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_RISCV_FREERTOS_SOCKET}\" -M ivshmem-riscv-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter
tmux send-keys -t "${SESSION}:0.2" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_MIPS_FREERTOS_SOCKET}\" -M ivshmem-mips-ft -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter

# Wait for all three sockets.
for _i in $(seq 1 60); do
    if [[ -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_ARM_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_RISCV_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_MIPS_FREERTOS_SOCKET}"; then
        break
    fi
    sleep 0.5
done
_ok "All three ivshmem servers listening"

# ── 2g. Launch FreeRTOS QEMU ─────────────────────────────────────────────────

echo "[debian-harness] Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.3" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh'" Enter

# Give FreeRTOS a head start — it is the slowest component.
sleep 2

# ── 2h. Launch Linux guests ──────────────────────────────────────────────────

echo "[debian-harness] Starting ARM Linux guest..."
tmux send-keys -t "${SESSION}:0.4" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-arm-phase5.sh'" Enter

echo "[debian-harness] Starting RISC-V Linux guest..."
tmux send-keys -t "${SESSION}:0.5" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-riscv-phase5.sh'" Enter

echo "[debian-harness] Starting MIPS Linux guest..."
tmux send-keys -t "${SESSION}:0.6" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/guest-run-chimera.sh'" Enter

# ── 2i. Auto-login and run hello binaries ────────────────────────────────────

auto_login_and_run() {
    local pane="$1"
    local hello_bin="$2"
    local label="$3"
    local timeout=300
    local elapsed=0

    # Write PCI-enable + hello_bin to a short-named script in the 9p share dir
    # so the guest only needs to receive a ~22-char path.  Long tmux send-keys
    # strings (50+ chars for binary paths, 110+ chars for the PCI one-liner)
    # drop characters on the slow RISCV UART emulation.
    local pane_idx="${pane##*.}"
    {
        printf '#!/bin/sh\n'
        # Enable any un-driven PCI ivshmem devices (needed on some kernels for BAR access)
        printf 'for v in /sys/bus/pci/devices/*/vendor; do\n'
        printf '    [ "$(cat "$v" 2>/dev/null)" = "0x1af4" ] && echo 1 > "$(dirname "$v")/enable" 2>/dev/null || true\n'
        printf 'done\n'
        printf '%s\n' "${hello_bin}"
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
            echo "[debian-harness]   ${label}: logged in (login: prompt) and hello binary fired"
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            tmux send-keys -t "${pane}" "mount /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "${pane}" "sh /mnt/pingpong/r${pane_idx}.sh" Enter
            echo "[debian-harness]   ${label}: auto-login detected, hello binary fired"
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "[debian-harness] WARNING: timed out waiting for shell prompt in ${label} pane" >&2
    return 1
}

auto_login_and_run "${SESSION}:0.4" "/mnt/pingpong/freertos-showcase/hello-arm-linux"   "ARM"   &
PID_ARM=$!
auto_login_and_run "${SESSION}:0.5" "/mnt/pingpong/freertos-showcase/hello-riscv-linux" "RISCV" &
PID_RISCV=$!
# MIPS: copy hello binary to local /tmp to avoid 9p exec issues
auto_login_and_run "${SESSION}:0.6" \
    "cp /mnt/pingpong/freertos-showcase/hello-mips-linux /tmp/ && /tmp/hello-mips-linux" \
    "MIPS" &
PID_MIPS=$!

# ── 2j. Monitor FreeRTOS output ──────────────────────────────────────────────

echo ""
echo "[debian-harness] Monitoring FreeRTOS UART for pass strings (timeout ${HARNESS_TIMEOUT}s)..."
echo "[debian-harness]   ARM:   \"${PASS_STRINGS[0]}\""
echo "[debian-harness]   RISCV: \"${PASS_STRINGS[1]}\""
echo "[debian-harness]   MIPS:  \"${PASS_STRINGS[2]}\""

# Track which pass strings we've seen.
declare -A seen
for s in "${PASS_STRINGS[@]}"; do
    seen["$s"]=0
done

elapsed=0
while (( elapsed < HARNESS_TIMEOUT )); do
    pane_content="$(tmux capture-pane -p -t "${SESSION}:0.3" -S -50000 2>/dev/null)"

    all_seen=1
    for s in "${PASS_STRINGS[@]}"; do
        if [[ "${seen[$s]}" -eq 0 ]]; then
            if echo "${pane_content}" | grep -qF "$s"; then
                seen["$s"]=1
                _ok "Detected: $s"
            else
                all_seen=0
            fi
        fi
    done

    if [[ "$all_seen" -eq 1 ]]; then
        echo ""
        echo "[debian-harness] PASS after ${elapsed}s — all three senders acknowledged"
        echo "=== Matching FreeRTOS output ==="
        echo "${pane_content}" | grep -E "received hello|flag=1|\[diag\]" | tail -20
        echo "${pane_content}" > "${FREERTOS_LOG}"

        # Wait for background auto-login tasks to finish.
        wait ${PID_ARM}  2>/dev/null || true
        wait ${PID_RISCV} 2>/dev/null || true
        wait ${PID_MIPS} 2>/dev/null || true
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[debian-harness] t=%3ds — seen: " "${elapsed}"
        for s in "${PASS_STRINGS[@]}"; do
            if [[ "${seen[$s]}" -eq 1 ]]; then printf "✓ "; else printf "… "; fi
        done
        echo ""
        echo "${pane_content}" | tail -3
    fi

    sleep 2
    (( elapsed += 2 ))
done

# ── Timeout — FAIL ───────────────────────────────────────────────────────────

echo ""
_fail "FAIL: timeout after ${HARNESS_TIMEOUT}s"

MISSING_COUNT=0
for s in "${PASS_STRINGS[@]}"; do
    if [[ "${seen[$s]}" -eq 0 ]]; then
        _fail "  Never saw: $s"
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))
    fi
done

echo ""
echo "[debian-harness] === FreeRTOS pane (last 30 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.3" -S -50000 2>/dev/null | tail -30 || true
echo ""
echo "[debian-harness] === ARM Linux pane (last 20 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.4" 2>/dev/null | tail -20 || true
echo ""
echo "[debian-harness] === RISC-V Linux pane (last 20 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.5" 2>/dev/null | tail -20 || true
echo ""
echo "[debian-harness] === MIPS Linux pane (last 20 lines) ==="
tmux capture-pane -p -t "${SESSION}:0.6" 2>/dev/null | tail -20 || true

# Dump all captured panes to log files for post-mortem.
tmux capture-pane -p -t "${SESSION}:0.3" -S -50000 > "${FREERTOS_LOG}" 2>/dev/null || true
tmux capture-pane -p -t "${SESSION}:0.4"          > "${LOG_DIR}/arm-${RUN_ID}.log"  2>/dev/null || true
tmux capture-pane -p -t "${SESSION}:0.5"          > "${LOG_DIR}/riscv-${RUN_ID}.log" 2>/dev/null || true
tmux capture-pane -p -t "${SESSION}:0.6"          > "${LOG_DIR}/mips-${RUN_ID}.log"  2>/dev/null || true

exit 1
