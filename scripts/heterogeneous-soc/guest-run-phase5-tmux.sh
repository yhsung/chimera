#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"
REPO="${CHIMERA_ROOT}"
SESSION="freertos-showcase"
ELF="$REPO/contrib/heterogeneous-soc/freertos-showcase/freertos-r52-demo.elf"

cd "$REPO"

if [[ -z "${SKIP_BUILD:-}" ]]; then
    # One-time setup: Lima guest and disk images.
    # Re-triggered only when the ELF is absent (first run or after a clean).
    if [[ ! -f "$ELF" ]]; then
        echo "=== One-time setup ==="
        scripts/heterogeneous-soc/guest-install-lima-guest.sh
        scripts/heterogeneous-soc/guest-fetch-images.sh
        echo "=== One-time setup complete ==="
    fi

    # Always rebuild QEMU and ivshmem-server via ninja (incremental; no-op when
    # nothing changed, fast partial rebuild when only .c files changed).
    # BUILD_DIR/VM_SOURCE_DIR are left to common.sh's own detection, which
    # resolves them relative to this script's location (REPO).
    scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh

    # Always rebuild the FreeRTOS ELF and Linux syslog binaries so source changes
    # are picked up without manual intervention.
    echo "=== Building FreeRTOS showcase ==="
    scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
    echo "=== Build complete ==="
fi

# Build a single-window layout:
#
#  ┌────────┬────────┬────────┬────────┬────────┐
#  │srv     │srv     │srv     │srv     │srv     │  panes 0-4  (equal fifths)
#  │ARM-FT  │RSCV-FT │MIPS-FT │STATS   │BOOT-LOG│
#  ├────────┴────────┴────────┴────────┴────────┤
#  │                  FreeRTOS                  │  pane 5
#  ├─────────────┬──────────────┬───────────────┤
#  │  ARM-Linux  │  RISCV-Linux │  MIPS-Linux   │  panes 6,7,8  (equal thirds)
#  └─────────────┴──────────────┴───────────────┘
#
# Split sequence (-l N% gives the new pane N% of the pane being split):
#   split-v 80% on 0.0  → 0=top(20%),    1=rest(80%)
#   split-v 45% on 0.1  → 0=top(20%),    1=mid(44%),    2=bot(36%)
#   split-h 80% on 0.0  → 0=srv1(20%),   1=srv_rest(80%), 2=mid, 3=bot
#   split-h 75% on 0.1  → 0=srv1(20%),   1=srv2(20%),   2=srv_rest(60%), 3=mid, 4=bot
#   split-h 67% on 0.2  → 0=srv1(20%),   1=srv2(20%),   2=srv3(20%),   3=srv_rest(40%), 4=mid, 5=bot
#   split-h 50% on 0.3  → 0=srv1(20%),   1=srv2(20%),   2=srv3(20%),   3=srv4(20%),   4=srv5(20%), 5=mid, 6=bot
#   split-h 67% on 0.6  → ...,            6=bl(33%),     7=br(67%)
#   split-h 50% on 0.7  → ...,            6=bl(33%),     7=bm(33%), 8=br(33%)

# Kill any existing session
tmux kill-session -t "$SESSION" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

tmux split-window -v -t "$SESSION:0.0" -l 80%
tmux split-window -v -t "$SESSION:0.1" -l 45%
tmux split-window -h -t "$SESSION:0.0" -l 80%
tmux split-window -h -t "$SESSION:0.1" -l 75%
tmux split-window -h -t "$SESSION:0.2" -l 67%
tmux split-window -h -t "$SESSION:0.3" -l 50%
tmux split-window -h -t "$SESSION:0.6" -l 67%
tmux split-window -h -t "$SESSION:0.7" -l 50%

# Name each pane for command-line addressing (see guest-tmux-pane.sh).
tmux select-pane -t "$SESSION:0.0" -T "ivshmem-arm"
tmux select-pane -t "$SESSION:0.1" -T "ivshmem-riscv"
tmux select-pane -t "$SESSION:0.2" -T "ivshmem-mips"
tmux select-pane -t "$SESSION:0.3" -T "ivshmem-stats"
tmux select-pane -t "$SESSION:0.4" -T "ivshmem-bootlog"
tmux select-pane -t "$SESSION:0.5" -T "freertos"
tmux select-pane -t "$SESSION:0.6" -T "arm-linux"
tmux select-pane -t "$SESSION:0.7" -T "riscv-linux"
tmux select-pane -t "$SESSION:0.8" -T "mips-linux"
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format "#{pane_index}:#{pane_title}"

# Kill any stale QEMU processes that outlived a previous session.
pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
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
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh"       Enter
( cd "$REPO" && scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh >/dev/null 2>&1 & )

ARM_SOCK="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}/sock"
RISCV_SOCK="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}/sock"
MIPS_SOCK="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}/sock"
STATS_SOCK="${IVSHMEM_STATS_FREERTOS_DIR:-/tmp/ivshmem-stats-freertos}/sock"
BOOT_SOCK="${IVSHMEM_BOOTLOG_DIR:-/tmp/ivshmem-bootlog}/sock"
CAN_SOCK="${IVSHMEM_CAN_FREERTOS_DIR:-/tmp/ivshmem-can-freertos}/sock"
for _i in $(seq 1 60); do
    if [[ -S "$ARM_SOCK"   ]] && ss -xl | grep -Fq "$ARM_SOCK"   && \
       [[ -S "$RISCV_SOCK" ]] && ss -xl | grep -Fq "$RISCV_SOCK" && \
       [[ -S "$MIPS_SOCK"  ]] && ss -xl | grep -Fq "$MIPS_SOCK"  && \
       [[ -S "$STATS_SOCK" ]] && ss -xl | grep -Fq "$STATS_SOCK" && \
       [[ -S "$BOOT_SOCK"  ]] && ss -xl | grep -Fq "$BOOT_SOCK"  && \
       [[ -S "$CAN_SOCK"   ]] && ss -xl | grep -Fq "$CAN_SOCK"; then
        break
    fi
    sleep 0.5
done

tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.6" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.7" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-phase5.sh"          Enter
tmux send-keys -t "$SESSION:0.8" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-chimera.sh"               Enter

# Send a string one character at a time with a per-char delay.
# Slow UART emulation (notably RISC-V) drops characters when tmux send-keys
# fires the whole string at once; this workaround prevents that.
_send_keys_slow() {
    local pane="$1" text="$2" delay="${3:-0.04}"
    local i ch
    for (( i=0; i<${#text}; i++ )); do
        ch="${text:$i:1}"
        tmux send-keys -t "$pane" "$ch"
        sleep "${delay}"
    done
}

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
        # Match a shell prompt that may have systemd boot messages interleaved on
        # the same terminal line (e.g. "root@host:~# [ OK ] Started foo.service").
        # Anchoring to ^ avoids false positives; dropping the $ avoids missing the
        # prompt when a concurrent kernel/systemd message lands after the '#'.
        tmux capture-pane -p -t "$pane" 2>/dev/null | grep -qE "^root@[^:]+:[^#]*#"
    }

    _wait_prompt() {
        local max=$1 t=0
        while (( t < max )); do
            _has_prompt && return 0
            sleep 2; (( t += 2 ))
        done
        return 1
    }

    _send_slow_and_verify() {
        local cmd="$1" max_retries=3 retries=0
        while (( retries < max_retries )); do
            _send_keys_slow "$pane" "$cmd"
            tmux send-keys -t "$pane" Enter
            sleep 2
            # Check that the command was received correctly (no dropped chars)
            local pane_content
            pane_content="$(tmux capture-pane -p -t "$pane" 2>/dev/null || true)"
            if echo "$pane_content" | grep -qE "(command not found|No such file)"; then
                (( retries++ ))
                sleep 1
                # Clear the line with Ctrl+C before retrying
                tmux send-keys -t "$pane" C-c
                sleep 0.5
            else
                return 0
            fi
        done
        return 1
    }

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "$pane" 2>/dev/null || true)"

        # Match only a bare login: prompt — not the autologin echo line
        # "login: root (automatic login)" which also contains "login:".
        if echo "$content" | grep -qE 'login:[[:space:]]*$'; then
            _send_keys_slow "$pane" "root"
            tmux send-keys -t "$pane" Enter
            _wait_prompt 60 || true
        fi

        if _has_prompt; then
            _send_slow_and_verify "mount /mnt/pingpong"
            # Even if verify gave up, try the script — it might have mounted OK.
            sleep 1
            _send_keys_slow "$pane" "sh /mnt/pingpong/r${pane_idx}.sh"
            tmux send-keys -t "$pane" Enter
            return 0
        fi

        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for shell prompt in pane $pane" >&2
}

auto_login_and_run "$SESSION:0.6" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "syslog-arm-linux &" \
    "bootlog-arm-linux &" \
    "ip link set can0 type can bitrate 500000 2>/dev/null; ip link set can0 up 2>/dev/null" \
    "can-log-arm-linux &" \
    "boot-collector" &
auto_login_and_run "$SESSION:0.7" \
    "syslog-riscv-linux &" \
    "bootlog-riscv-linux" &
auto_login_and_run "$SESSION:0.8" \
    "syslog-mips-linux &" \
    "bootlog-mips-linux" &

# Focus FreeRTOS pane so FreeRTOS output is front-and-center on attach
tmux select-pane -t "$SESSION:0.5"

echo ""
echo "=== Phase 5 showcase starting (session: $SESSION) ==="
echo "    Guests will auto-login and run syslog daemons once booted."
echo "    Navigate panes: Ctrl-b arrow keys"
echo "    Attaching..."
echo ""

tmux attach-session -t "$SESSION"
