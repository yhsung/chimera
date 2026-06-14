#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

STOP_WAIT_SECONDS="${STOP_WAIT_SECONDS:-5}"

find_demo_qemu_pids() {
    local line
    local pid
    local cmd

    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        pid="${line%% *}"
        cmd="${line#* }"

        case "${cmd}" in
            *qemu-system-aarch64*"-chardev socket,id=ivshmem,path=${IVSHMEM_SOCKET}"*"-virtfs local,path=${PINGPONG_DIR},mount_tag=${PINGPONG_SHARE_TAG}"*)
                printf '%s\n' "${pid}"
                ;;
            *qemu-system-riscv64*"-chardev socket,id=ivshmem,path=${IVSHMEM_SOCKET}"*"-virtfs local,path=${PINGPONG_DIR},mount_tag=${PINGPONG_SHARE_TAG}"*)
                printf '%s\n' "${pid}"
                ;;
        esac
    done < <(pgrep -af 'qemu-system-(aarch64|riscv64)' || true)
}

wait_for_exit() {
    local deadline
    local pid

    deadline=$((SECONDS + STOP_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        for pid in "$@"; do
            if kill -0 "${pid}" 2>/dev/null; then
                sleep 1
                continue 2
            fi
        done
        return 0
    done

    return 1
}

mapfile -t demo_pids < <(find_demo_qemu_pids)

if (( ${#demo_pids[@]} == 0 )); then
    echo "No stale heterogeneous-soc demo QEMU processes found."
    exit 0
fi

echo "Stopping stale heterogeneous-soc demo QEMU processes: ${demo_pids[*]}"
kill "${demo_pids[@]}"

if ! wait_for_exit "${demo_pids[@]}"; then
    echo "Forcing remaining heterogeneous-soc demo QEMU processes to exit: ${demo_pids[*]}"
    kill -KILL "${demo_pids[@]}" 2>/dev/null || true
fi
