#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"

exec "${SCRIPT_DIR}/pong" "${BAR2_PATH}"
