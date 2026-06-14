#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-tmux-pane.sh
#
# Address panes of the "freertos-showcase" tmux session (see
# guest-run-phase5-tmux.sh) by name instead of numeric index.
#
# Usage:
#   guest-tmux-pane.sh list
#   guest-tmux-pane.sh <name> send "<command>"
#   guest-tmux-pane.sh <name> capture [N]
#
# Run this from inside the Lima VM:
#   limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos capture
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SESSION="${SESSION:-freertos-showcase}"

declare -A PANES=(
    [ivshmem-arm]="0.0"
    [ivshmem-riscv]="0.1"
    [ivshmem-mips]="0.2"
    [ivshmem-stats]="0.3"
    [ivshmem-bootlog]="0.4"
    [freertos]="0.5"
    [arm-linux]="0.6"
    [riscv-linux]="0.7"
    [mips-linux]="0.8"
)

PANE_ORDER=(ivshmem-arm ivshmem-riscv ivshmem-mips ivshmem-stats ivshmem-bootlog freertos arm-linux riscv-linux mips-linux)

usage() {
    cat <<'EOF'
Usage:
  guest-tmux-pane.sh list
  guest-tmux-pane.sh <name> send "<command>"
  guest-tmux-pane.sh <name> capture [N]

Names: ivshmem-arm ivshmem-riscv ivshmem-mips ivshmem-stats ivshmem-bootlog
       freertos arm-linux riscv-linux mips-linux
EOF
}

if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "$1" == "list" ]]; then
    printf '%-15s %s\n' "NAME" "PANE"
    for name in "${PANE_ORDER[@]}"; do
        printf '%-15s %s\n' "${name}" "${PANES[${name}]}"
    done
    exit 0
fi

NAME="$1"
ACTION="${2:-}"

[[ -n "${PANES[${NAME}]+x}" ]] || die "unknown pane name '${NAME}'. Valid names: ${PANE_ORDER[*]}"

TARGET="${SESSION}:${PANES[${NAME}]}"

tmux has-session -t "${SESSION}" 2>/dev/null || die "tmux session '${SESSION}' not running. Launch it with guest-run-chimera-showcase.sh"

case "${ACTION}" in
    send)
        CMD="${3:-}"
        [[ -n "${CMD}" ]] || die "usage: guest-tmux-pane.sh ${NAME} send \"<command>\""
        tmux send-keys -t "${TARGET}" "${CMD}" Enter
        ;;
    capture)
        LINES="${3:-}"
        if [[ -n "${LINES}" ]]; then
            tmux capture-pane -p -t "${TARGET}" | tail -n "${LINES}"
        else
            tmux capture-pane -p -t "${TARGET}"
        fi
        ;;
    *)
        usage
        exit 1
        ;;
esac
