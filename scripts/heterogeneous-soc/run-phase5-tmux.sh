#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
SESSION="freertos-showcase"
ELF="$REPO/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf"

cd "$REPO"

# One-time setup: runs inline (blocking) if payloads are missing
if [[ ! -f "$ELF" ]]; then
    echo "=== One-time setup ==="
    scripts/heterogeneous-soc/install-lima-guest.sh
    scripts/heterogeneous-soc/fetch-images.sh
    BUILD_DIR="$HOME/chimera-build-linux" VM_SOURCE_DIR="$HOME/chimera-src" \
        scripts/heterogeneous-soc/build-ivshmem-tools.sh
    scripts/heterogeneous-soc/build-freertos-showcase.sh
    echo "=== Setup complete ==="
fi

# Kill any existing session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Build a single-window layout:
#
#  ┌─────────────────┬─────────────────┐
#  │  arm-ft-server  │ riscv-ft-server │  (panes 0, 3)
#  ├─────────────────┴─────────────────┤
#  │            freertos               │  (pane 1)
#  ├─────────────────┬─────────────────┤
#  │   arm-guest     │   riscv-guest   │  (panes 2, 4)
#  └─────────────────┴─────────────────┘

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

# Split into three horizontal bands: servers (top), freertos (middle), guests (bottom)
# tmux 3.4+ requires -l N% instead of the removed -p N flag
tmux split-window -v -t "$SESSION:0.0" -l 80%  # pane 0=top(20%), pane 1=rest(80%)
tmux split-window -v -t "$SESSION:0.1" -l 45%  # pane 1=middle(44%), pane 2=bottom(36%)

# Split the server band and the guest band each into two side-by-side panes
tmux split-window -h -t "$SESSION:0.0"          # pane 0=top-left, pane 3=top-right
tmux split-window -h -t "$SESSION:0.2"          # pane 2=bottom-left, pane 4=bottom-right

# Start ivshmem servers first, then wait for sockets before launching guests
tmux send-keys -t "$SESSION:0.0" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh"   Enter
tmux send-keys -t "$SESSION:0.3" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh" Enter

sleep 1

tmux send-keys -t "$SESSION:0.1" "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.2" "cd '$REPO' && scripts/heterogeneous-soc/run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-phase5.sh"          Enter

# Focus freertos pane
tmux select-pane -t "$SESSION:0.1"

cat <<'EOF'

=== Phase 5 showcase starting (tmux session: freertos-showcase) ===

Layout (single window, 5 panes):
  top-left:     arm-ft-server
  top-right:    riscv-ft-server
  middle:       freertos guest
  bottom-left:  arm-guest
  bottom-right: riscv-guest

Navigate panes: Ctrl-b arrow keys

Once the Linux guests finish booting, run inside each QEMU console:

  ARM guest (bottom-left):
    busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong
    /mnt/pingpong/freertos-showcase/hello-arm-linux

  RISC-V guest (bottom-right):
    busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong
    /mnt/pingpong/freertos-showcase/hello-riscv-linux

Attaching...
EOF

tmux attach-session -t "$SESSION"
