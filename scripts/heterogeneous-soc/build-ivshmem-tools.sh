#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_vm_source_tree

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -f build.ninja ]]; then
    "${VM_SOURCE_DIR}/configure" \
        --target-list=aarch64-softmmu,riscv64-softmmu \
        --enable-debug
fi

ninja contrib/ivshmem-server/ivshmem-server \
      contrib/ivshmem-client/ivshmem-client
