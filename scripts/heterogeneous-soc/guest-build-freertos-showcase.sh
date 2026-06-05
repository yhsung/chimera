#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_vm_source_tree
bash "${SCRIPT_DIR}/guest-fetch-freertos-kernel.sh"
make -C "${FREERTOS_SHOWCASE_DIR}" clean all
