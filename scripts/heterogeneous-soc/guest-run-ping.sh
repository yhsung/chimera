#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"

if [[ -x /usr/local/bin/ping ]]; then
    exec /usr/local/bin/ping "${BAR2_PATH}"
fi

if [[ -x /mnt/pingpong/ping ]]; then
    exec /mnt/pingpong/ping "${BAR2_PATH}"
fi

if [[ -x "${PING_BINARY}" ]]; then
    exec "${PING_BINARY}" "${BAR2_PATH}"
fi

die "ping binary not found in /usr/local/bin, /mnt/pingpong, or ${PING_BINARY}"
