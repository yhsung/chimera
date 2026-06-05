#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
SESSION="freertos-showcase"
ELF="$REPO/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf"

cd "$REPO"

if [[ -z "${SKIP_BUILD:-}" ]]; then
    # One-time setup: Lima guest, disk images, and ivshmem server binary.
    # Gated on ELF absence as a proxy; none of these need to re-run on every launch.
    if [[ ! -f "$ELF" ]]; then
        echo "=== One-time setup ==="
        scripts/heterogeneous-soc/guest-install-lima-guest.sh
        scripts/heterogeneous-soc/guest-fetch-images.sh
        BUILD_DIR="$HOME/chimera-build-linux" VM_SOURCE_DIR="$HOME/chimera-src" \
            scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh
        echo "=== One-time setup complete ==="
    fi

    # Always rebuild the FreeRTOS ELF and Linux hello binaries so source changes
    # are picked up without manual intervention.
    echo "=== Building FreeRTOS showcase ==="
    scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
    echo "=== Build complete ==="
fi

# Build a single-window layout:
#
#  ┌──────────────┬──────────────┬──────────────┐
#  │  srv ARM-FT  │  srv RISCV-FT│  srv MIPS-FT │  panes 0, 1, 2  (equal thirds)
#  ├──────────────┴──────────────┴──────────────┤
#  │                  FreeRTOS                   │  pane 3
#  ├──────────────┬──────────────┬──────────────┤
#  │  ARM-Linux   │  RISCV-Linux │  MIPS-Linux  │  panes 4, 5, 6  (equal thirds)
#  └──────────────┴──────────────┴──────────────┘
#
# Split sequence (-l N% gives the new pane N% of the pane being split):
#   split-v 80% on 0.0  → 0=top(20%),  1=rest(80%)
#   split-v 45% on 0.1  → 0=top(20%),  1=mid(44%),   2=bot(36%)
#   split-h 67% on 0.0  → 0=tl(33%),   1=tr(67%),    2=mid, 3=bot
#   split-h 50% on 0.1  → 0=tl(33%),   1=tm(33%),    2=tr(33%), 3=mid, 4=bot
#   split-h 67% on 0.4  → ...,          4=bl(33%),    5=br(67%)
#   split-h 50% on 0.5  → ...,          4=bl(33%),    5=bm(33%), 6=br(33%)

# Kill any existing session
tmux kill-session -t "$SESSION" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

tmux split-window -v -t "$SESSION:0.0" -l 80%
tmux split-window -v -t "$SESSION:0.1" -l 45%
tmux split-window -h -t "$SESSION:0.0" -l 67%
tmux split-window -h -t "$SESSION:0.1" -l 50%
tmux split-window -h -t "$SESSION:0.4" -l 67%
tmux split-window -h -t "$SESSION:0.5" -l 50%

# Kill any stale QEMU processes that outlived a previous session.
pkill -f "qemu-system-riscv64.*freertos-riscv-demo" 2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"        2>/dev/null || true
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-mips.*run-chimera"             2>/dev/null || true
sleep 0.5   # let the processes exit and release disk locks before QEMU restarts

# Start ivshmem servers first; wait for all three sockets before launching guests.
tmux send-keys -t "$SESSION:0.0" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-arm-freertos.sh"   Enter
tmux send-keys -t "$SESSION:0.1" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-riscv-freertos.sh" Enter
tmux send-keys -t "$SESSION:0.2" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-mips-freertos.sh"  Enter

ARM_SOCK="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}/sock"
RISCV_SOCK="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}/sock"
MIPS_SOCK="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}/sock"
for _i in $(seq 1 60); do
    if [[ -S "$ARM_SOCK"  ]] && ss -xl | grep -Fq "$ARM_SOCK"  && \
       [[ -S "$RISCV_SOCK" ]] && ss -xl | grep -Fq "$RISCV_SOCK" && \
       [[ -S "$MIPS_SOCK"  ]] && ss -xl | grep -Fq "$MIPS_SOCK"; then
        break
    fi
    sleep 0.5
done

tmux send-keys -t "$SESSION:0.3" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-phase5.sh"          Enter
tmux send-keys -t "$SESSION:0.6" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-chimera.sh"               Enter

# Wait for the guest shell to be ready, then run the hello binary.
auto_login_and_run() {
    local pane="$1"
    local hello_bin="$2"
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)"
        if echo "$content" | grep -q "login:"; then
            tmux send-keys -t "$pane" "root" Enter
            sleep 3
            tmux send-keys -t "$pane" "mount /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        elif echo "$content" | grep -qE "root@[^:]*:~?#"; then
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for shell prompt in pane $pane" >&2
}

auto_login_and_run "$SESSION:0.4" "/mnt/pingpong/freertos-showcase/hello-arm-linux"   &
auto_login_and_run "$SESSION:0.5" "/mnt/pingpong/freertos-showcase/hello-riscv-linux" &
auto_login_and_run "$SESSION:0.6" "/mnt/pingpong/freertos-showcase/hello-mips-linux"  &

# Focus FreeRTOS pane so FreeRTOS output is front-and-center on attach
tmux select-pane -t "$SESSION:0.3"

echo ""
echo "=== Phase 5 showcase starting (session: $SESSION) ==="
echo "    Guests will auto-login and run hello senders once booted."
echo "    Navigate panes: Ctrl-b arrow keys"
echo "    Attaching..."
echo ""

tmux attach-session -t "$SESSION"
