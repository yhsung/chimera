#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

FREERTOS_DEPS_ROOT="${FREERTOS_DEPS_ROOT:-${HOME}/heterogeneous-soc-freertos}"
FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR:-${FREERTOS_DEPS_ROOT}/FreeRTOS-Kernel}"
FREERTOS_KERNEL_REMOTE="${FREERTOS_KERNEL_REMOTE:-https://github.com/FreeRTOS/FreeRTOS-Kernel.git}"

mkdir -p "${FREERTOS_DEPS_ROOT}"

if [[ ! -d "${FREERTOS_KERNEL_DIR}/.git" ]]; then
    git clone --depth 1 "${FREERTOS_KERNEL_REMOTE}" "${FREERTOS_KERNEL_DIR}"
else
    git -C "${FREERTOS_KERNEL_DIR}" pull --ff-only
fi
