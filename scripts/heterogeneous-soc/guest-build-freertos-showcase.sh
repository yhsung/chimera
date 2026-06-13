#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_vm_source_tree
bash "${SCRIPT_DIR}/guest-fetch-freertos-kernel.sh"
make -C "${FREERTOS_SHOWCASE_DIR}" clean all

echo "[build] Running unit tests (make check)..."
if make -C "${FREERTOS_SHOWCASE_DIR}" check; then
    echo "[build] All unit tests PASSED"
else
    echo "[build] ERROR: unit tests FAILED" >&2
    exit 1
fi

echo "[build] Running syslog format validation..."
if bash "${FREERTOS_SHOWCASE_DIR}/test-syslog-format.sh"; then
    echo "[build] Syslog format validated"
else
    echo "[build] WARNING: syslog format test skipped or failed (binary may not be built)"
fi
