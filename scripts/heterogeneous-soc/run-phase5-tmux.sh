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

# Replace any existing session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Window 0: ARM ivshmem server
tmux new-session -d -s "$SESSION" -n "arm-ft-server" -x 220 -y 50
tmux send-keys -t "$SESSION:arm-ft-server" \
    "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh" Enter

# Window 1: RISC-V ivshmem server
tmux new-window -t "$SESSION" -n "riscv-ft-server"
tmux send-keys -t "$SESSION:riscv-ft-server" \
    "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh" Enter

# Give servers a moment to bind their sockets
sleep 1

# Window 2: FreeRTOS guest
tmux new-window -t "$SESSION" -n "freertos"
tmux send-keys -t "$SESSION:freertos" \
    "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh" Enter

# Window 3: ARM/Linux guest
tmux new-window -t "$SESSION" -n "arm-guest"
tmux send-keys -t "$SESSION:arm-guest" \
    "cd '$REPO' && scripts/heterogeneous-soc/run-arm-phase5.sh" Enter

# Window 4: RISC-V/Linux guest
tmux new-window -t "$SESSION" -n "riscv-guest"
tmux send-keys -t "$SESSION:riscv-guest" \
    "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-phase5.sh" Enter

# Focus the FreeRTOS window so output is visible on attach
tmux select-window -t "$SESSION:freertos"

cat <<'EOF'

=== Phase 5 showcase starting (tmux session: freertos-showcase) ===

Windows:  0:arm-ft-server  1:riscv-ft-server  2:freertos  3:arm-guest  4:riscv-guest
Navigate: Ctrl-b 0..4

Once the Linux guests finish booting, run inside each QEMU console:

  ARM guest (window 3):
    busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong
    /mnt/pingpong/freertos-showcase/hello-arm-linux

  RISC-V guest (window 4):
    busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong
    /mnt/pingpong/freertos-showcase/hello-riscv-linux

Attaching...
EOF

tmux attach-session -t "$SESSION"
