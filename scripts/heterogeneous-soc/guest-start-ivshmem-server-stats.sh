#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_STATS_FREERTOS_DIR}"

if [[ -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_STATS_FREERTOS_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_STATS_FREERTOS_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_STATS_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -M ivshmem-stats-ft \
    -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -l "${IVSHMEM_SIZE}" \
    -n "${IVSHMEM_VECTORS}" \
    -v
