#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
REPO="${CHIMERA_ROOT}"
SESSION="freertos-showcase"
ELF="$REPO/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf"

cd "$REPO"

if [[ -z "${SKIP_BUILD:-}" ]]; then
    # Check whether the existing QEMU binary supports the expected machine
    # properties — a stale binary will fail at runtime with "Property not found".
    _qemu_build_valid() {
        local qemu_riscv="${BUILD_DIR}/qemu-system-riscv64"
        [[ -x "${qemu_riscv}" ]] || return 1
        "${qemu_riscv}" -M chimera-riscv-freertos-demo,help 2>&1 | \
            grep -q "ivshmem-stats-freertos" || return 1
    }

    # One-time setup: Lima guest, disk images, and ivshmem server binary.
    # Re-triggered when the ELF is absent or the QEMU binary is stale.
    if [[ ! -f "$ELF" ]] || ! _qemu_build_valid; then
        echo "=== One-time setup ==="
        scripts/heterogeneous-soc/guest-install-lima-guest.sh
        scripts/heterogeneous-soc/guest-fetch-images.sh
        BUILD_DIR="$HOME/chimera-build-linux" VM_SOURCE_DIR="$HOME/chimera-src" \
            scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh
        echo "=== One-time setup complete ==="
    fi

    # Always rebuild the FreeRTOS ELF and Linux syslog binaries so source changes
    # are picked up without manual intervention.
    echo "=== Building FreeRTOS showcase ==="
    scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
    echo "=== Build complete ==="
fi

# Build a single-window layout:
#
#  ┌──────────┬──────────┬──────────┬──────────┐
#  │srv ARM-FT│srv RSCV-F│srv MIPS-F│srv STATS │  panes 0,1,2,3  (equal quarters)
#  ├──────────┴──────────┴──────────┴──────────┤
#  │                  FreeRTOS                  │  pane 4
#  ├──────────────┬──────────────┬─────────────┤
#  │  ARM-Linux   │  RISCV-Linux │  MIPS-Linux │  panes 5,6,7  (equal thirds)
#  └──────────────┴──────────────┴─────────────┘
#
# Split sequence (-l N% gives the new pane N% of the pane being split):
#   split-v 80% on 0.0  → 0=top(20%),    1=rest(80%)
#   split-v 45% on 0.1  → 0=top(20%),    1=mid(44%),    2=bot(36%)
#   split-h 75% on 0.0  → 0=tl(25%),     1=tr(75%),     2=mid, 3=bot
#   split-h 67% on 0.1  → 0=tl(25%),     1=tm1(25%),    2=tm2+tr(50%), 3=mid, 4=bot
#   split-h 50% on 0.2  → 0=tl(25%),     1=tm1(25%),    2=tm2(25%), 3=tr(25%), 4=mid, 5=bot
#   split-h 67% on 0.5  → ...,            5=bl(33%),     6=br(67%)
#   split-h 50% on 0.6  → ...,            5=bl(33%),     6=bm(33%), 7=br(33%)

# Kill any existing session
tmux kill-session -t "$SESSION" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

tmux split-window -v -t "$SESSION:0.0" -l 80%
tmux split-window -v -t "$SESSION:0.1" -l 45%
tmux split-window -h -t "$SESSION:0.0" -l 75%
tmux split-window -h -t "$SESSION:0.1" -l 67%
tmux split-window -h -t "$SESSION:0.2" -l 50%
tmux split-window -h -t "$SESSION:0.5" -l 67%
tmux split-window -h -t "$SESSION:0.6" -l 50%

# Kill any stale QEMU processes that outlived a previous session.
pkill -f "qemu-system-riscv64.*freertos-riscv-demo" 2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"        2>/dev/null || true
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-mips.*run-chimera"             2>/dev/null || true
sleep 0.5   # let the processes exit and release disk locks before QEMU restarts

# Set up network bridge and TAP devices for Avahi L2 networking.
bash "${SCRIPT_DIR}/guest-setup-network-bridge.sh"

# Start ivshmem servers; wait for all four sockets before launching guests.
tmux send-keys -t "$SESSION:0.0" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-arm-freertos.sh"   Enter
tmux send-keys -t "$SESSION:0.1" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-riscv-freertos.sh" Enter
tmux send-keys -t "$SESSION:0.2" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-mips-freertos.sh"  Enter
tmux send-keys -t "$SESSION:0.3" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh"          Enter

ARM_SOCK="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}/sock"
RISCV_SOCK="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}/sock"
MIPS_SOCK="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}/sock"
STATS_SOCK="${IVSHMEM_STATS_FREERTOS_DIR:-/tmp/ivshmem-stats-freertos}/sock"
for _i in $(seq 1 60); do
    if [[ -S "$ARM_SOCK"   ]] && ss -xl | grep -Fq "$ARM_SOCK"   && \
       [[ -S "$RISCV_SOCK" ]] && ss -xl | grep -Fq "$RISCV_SOCK" && \
       [[ -S "$MIPS_SOCK"  ]] && ss -xl | grep -Fq "$MIPS_SOCK"  && \
       [[ -S "$STATS_SOCK" ]] && ss -xl | grep -Fq "$STATS_SOCK"; then
        break
    fi
    sleep 0.5
done

tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.6" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-phase5.sh"          Enter
tmux send-keys -t "$SESSION:0.7" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-chimera.sh"               Enter

# Wait for the guest shell to be ready, then run the syslog daemon.
auto_login_and_run() {
    local pane="$1"
    shift
    local cmds=("$@")
    local timeout=300
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
    } > "$PINGPONG_DIR/r${pane_idx}.sh"

    _has_prompt() {
        tmux capture-pane -p -t "$pane" 2>/dev/null | grep -qE "root@[^:]+:[^#]*#[[:space:]]*$"
    }

    _wait_prompt() {
        local max=$1 t=0
        while (( t < max )); do
            _has_prompt && return 0
            sleep 2; (( t += 2 ))
        done
        return 1
    }

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "$pane" 2>/dev/null || true)"

        # Match only a bare login: prompt — not the autologin echo line
        # "login: root (automatic login)" which also contains "login:".
        if echo "$content" | grep -qE 'login:[[:space:]]*$'; then
            tmux send-keys -t "$pane" "root" Enter
            _wait_prompt 60 || true
        fi

        if _has_prompt; then
            tmux send-keys -t "$pane" "mount /mnt/pingpong" Enter
            _wait_prompt 30 || true
            sleep 1
            tmux send-keys -t "$pane" "sh /mnt/pingpong/r${pane_idx}.sh" Enter
            return 0
        fi

        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for shell prompt in pane $pane" >&2
}

auto_login_and_run "$SESSION:0.5" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "syslog-arm-linux" &
auto_login_and_run "$SESSION:0.6" \
    "syslog-riscv-linux" &
auto_login_and_run "$SESSION:0.7" \
    "syslog-mips-linux" &

# Focus FreeRTOS pane so FreeRTOS output is front-and-center on attach
tmux select-pane -t "$SESSION:0.4"

echo ""
echo "=== Phase 5 showcase starting (session: $SESSION) ==="
echo "    Guests will auto-login and run syslog daemons once booted."
echo "    Navigate panes: Ctrl-b arrow keys"
echo "    Attaching..."
echo ""

tmux attach-session -t "$SESSION"
