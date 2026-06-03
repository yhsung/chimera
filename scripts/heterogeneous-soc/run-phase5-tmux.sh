#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
SESSION="freertos-showcase"
ELF="$REPO/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf"

cd "$REPO"

# One-time setup: Lima guest, disk images, and ivshmem server binary.
# Gated on ELF absence as a proxy; none of these need to re-run on every launch.
if [[ ! -f "$ELF" ]]; then
    echo "=== One-time setup ==="
    scripts/heterogeneous-soc/install-lima-guest.sh
    scripts/heterogeneous-soc/fetch-images.sh
    BUILD_DIR="$HOME/chimera-build-linux" VM_SOURCE_DIR="$HOME/chimera-src" \
        scripts/heterogeneous-soc/build-ivshmem-tools.sh
    echo "=== One-time setup complete ==="
fi

# Always rebuild the FreeRTOS ELF and Linux hello binaries so source changes
# are picked up without manual intervention.
echo "=== Building FreeRTOS showcase ==="
scripts/heterogeneous-soc/build-freertos-showcase.sh
echo "=== Build complete ==="

# Kill any existing session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Build a single-window layout:
#
# After each split-window -h, tmux renumbers panes by visual position
# (left-to-right, top-to-bottom), so the indices after all four splits are:
#
#  ┌──────────────────────────┬──────────────────────────┐
#  │ shmem server ARM-FreeRTOS│ shmem server RISCV-FreeRT│  (panes 0, 1)
#  ├──────────────────────────┴──────────────────────────┤
#  │                    FreeRTOS                         │  (pane 2)
#  ├──────────────────────────┬──────────────────────────┤
#  │   hello from ARM-Linux   │  hello from RISCV-Linux  │  (panes 3, 4)
#  └──────────────────────────┴──────────────────────────┘

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

# Split into three horizontal bands: servers (top), freertos (middle), guests (bottom)
# tmux 3.4+ requires -l N% instead of the removed -p N flag
tmux split-window -v -t "$SESSION:0.0" -l 80%  # pane 0=top(20%), pane 1=rest(80%)
tmux split-window -v -t "$SESSION:0.1" -l 45%  # pane 1=middle(44%), pane 2=bottom(36%)

# Split the server band and the guest band each into two side-by-side panes.
# After the first h-split, tmux renumbers by visual position: the new top-right
# pane becomes 1, pushing old pane 1→2 (middle) and old pane 2→3 (bottom).
# The second h-split must therefore target pane 3 (the bottom band).
tmux split-window -h -t "$SESSION:0.0"          # pane 0=top-left, pane 1=top-right
tmux split-window -h -t "$SESSION:0.3"          # pane 3=bottom-left, pane 4=bottom-right

# Start ivshmem servers first, then wait for sockets before launching guests
tmux send-keys -t "$SESSION:0.0" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh"   Enter
tmux send-keys -t "$SESSION:0.1" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh" Enter

sleep 1

tmux send-keys -t "$SESSION:0.2" "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.3" "cd '$REPO' && scripts/heterogeneous-soc/run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-phase5.sh"          Enter

# Wait for a login prompt in a pane, then send commands automatically.
# Runs in the background so attach-session below can proceed.
auto_login_and_run() {
    local pane="$1"
    local hello_bin="$2"
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        if tmux capture-pane -p -t "$pane" 2>/dev/null | grep -q "login:"; then
            tmux send-keys -t "$pane" "root" Enter
            sleep 3
            tmux send-keys -t "$pane" "busybox mkdir -p /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "$pane" "busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for login prompt in pane $pane" >&2
}

auto_login_and_run "$SESSION:0.3" "/mnt/pingpong/freertos-showcase/hello-arm-linux"   &
auto_login_and_run "$SESSION:0.4" "/mnt/pingpong/freertos-showcase/hello-riscv-linux" &

# Focus freertos pane so FreeRTOS output is front-and-center on attach
tmux select-pane -t "$SESSION:0.2"

echo ""
echo "=== Phase 5 showcase starting (session: $SESSION) ==="
echo "    Guests will auto-login and run hello senders once booted."
echo "    Navigate panes: Ctrl-b arrow keys"
echo "    Attaching..."
echo ""

tmux attach-session -t "$SESSION"
