#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_DIR}"

if [[ -S "${IVSHMEM_SOCKET}" ]] && ss -xl | grep -Fq "${IVSHMEM_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -S "${IVSHMEM_SOCKET}" \
    -l "${IVSHMEM_SIZE}" \
    -n "${IVSHMEM_VECTORS}" \
    -v
