#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"

if [[ -x /usr/local/bin/hello-riscv-linux ]]; then
    exec /usr/local/bin/hello-riscv-linux "${BAR2_PATH}"
fi

if [[ -x /mnt/pingpong/freertos-showcase/hello-riscv-linux ]]; then
    exec /mnt/pingpong/freertos-showcase/hello-riscv-linux "${BAR2_PATH}"
fi

if [[ -x "${HELLO_RISCV_BINARY}" ]]; then
    exec "${HELLO_RISCV_BINARY}" "${BAR2_PATH}"
fi

die "hello-riscv-linux binary not found in /usr/local/bin, /mnt/pingpong/freertos-showcase, or ${HELLO_RISCV_BINARY}"
