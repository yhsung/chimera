#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}"

if [[ -S "${IVSHMEM_ARM_FREERTOS_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_ARM_FREERTOS_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_ARM_FREERTOS_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -S "${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -l "${IVSHMEM_SIZE}" \
    -n "${IVSHMEM_VECTORS}" \
    -v
