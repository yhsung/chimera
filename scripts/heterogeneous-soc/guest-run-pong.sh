#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"

if [[ -x /usr/local/bin/pong ]]; then
    exec /usr/local/bin/pong "${BAR2_PATH}"
fi

if [[ -x /mnt/pingpong/pong ]]; then
    exec /mnt/pingpong/pong "${BAR2_PATH}"
fi

if [[ -x "${PONG_BINARY}" ]]; then
    exec "${PONG_BINARY}" "${BAR2_PATH}"
fi

die "pong binary not found in /usr/local/bin, /mnt/pingpong, or ${PONG_BINARY}"
