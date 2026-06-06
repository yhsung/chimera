#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_BOOTLOG_DIR}"

if [[ -S "${IVSHMEM_BOOTLOG_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_BOOTLOG_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_BOOTLOG_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_BOOTLOG_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -M ivshmem-bootlog \
    -S "${IVSHMEM_BOOTLOG_SOCKET}" \
    -l "${IVSHMEM_BOOTLOG_SIZE}" \
    -n "${IVSHMEM_BOOTLOG_VECTORS}" \
    -v
