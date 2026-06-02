#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "ivshmem helper tools are only built in a Linux environment; run this script inside the Lima guest"
fi

prepare_vm_source_tree

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [[ ! -f build.ninja ]]; then
    "${VM_SOURCE_DIR}/configure" \
        --target-list=aarch64-softmmu,riscv64-softmmu \
        --enable-debug
fi

if grep -q '^#undef CONFIG_EVENTFD' config-host.h 2>/dev/null; then
    die "this build directory was configured without Linux eventfd support; use a fresh Linux-local BUILD_DIR such as BUILD_DIR=\$HOME/chimera-build-linux VM_SOURCE_DIR=\$HOME/chimera-src"
fi

if ! ninja -t targets all | grep -Eq '(^|[[:space:]])ivshmem-server:'; then
    die "ivshmem-server target is unavailable in this build directory; re-run inside the Linux/Lima environment after configure succeeds with ivshmem support"
fi

ninja ivshmem-server ivshmem-client
