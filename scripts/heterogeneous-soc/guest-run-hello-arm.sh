#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"

if [[ -x /usr/local/bin/hello-arm-linux ]]; then
    exec /usr/local/bin/hello-arm-linux "${BAR2_PATH}"
fi

if [[ -x /mnt/pingpong/freertos-showcase/hello-arm-linux ]]; then
    exec /mnt/pingpong/freertos-showcase/hello-arm-linux "${BAR2_PATH}"
fi

if [[ -x "${HELLO_ARM_BINARY}" ]]; then
    exec "${HELLO_ARM_BINARY}" "${BAR2_PATH}"
fi

die "hello-arm-linux binary not found in /usr/local/bin, /mnt/pingpong/freertos-showcase, or ${HELLO_ARM_BINARY}"
