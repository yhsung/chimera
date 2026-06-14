#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
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
        --target-list=aarch64-softmmu,arm-softmmu,riscv64-softmmu,mipsel-softmmu \
        --enable-debug
fi

if grep -q '^#undef CONFIG_EVENTFD' config-host.h 2>/dev/null; then
    die "this build directory was configured without Linux eventfd support; use a fresh Linux-local BUILD_DIR such as BUILD_DIR=\$HOME/chimera-build-linux VM_SOURCE_DIR=\$HOME/chimera-src"
fi

if ! grep -q 'build contrib/ivshmem-server/ivshmem-server:' build.ninja; then
    die "ivshmem-server target is unavailable in this build directory even though Linux eventfd is enabled; inspect the generated Ninja targets in ${BUILD_DIR}"
fi

ninja contrib/ivshmem-server/ivshmem-server \
      contrib/ivshmem-client/ivshmem-client \
      qemu-system-aarch64 \
      qemu-system-arm \
      qemu-system-riscv64 \
      qemu-system-mipsel
