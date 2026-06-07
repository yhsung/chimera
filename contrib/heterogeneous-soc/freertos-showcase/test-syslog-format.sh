#!/usr/bin/env bash
# Verifies syslog-arm-linux's SYSINFO line format via its self-test mode
# (SYSLOG_SELFTEST=1 prints one line and exits — no ivshmem/FreeRTOS needed).
# Run on Linux with cross-compiled syslog-arm-linux present.
# Exit 77 = SKIP (binary not built yet).
set -euo pipefail
SHOWCASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SHOWCASE_DIR}/syslog-arm-linux"

if [[ ! -f "${BINARY}" ]]; then
    echo "SKIP: ${BINARY} not built"
    exit 77
fi

OUTPUT=$(SYSLOG_SELFTEST=1 timeout 8 "${BINARY}" 2>/dev/null | grep -m1 "SYSINFO" || true)

if echo "${OUTPUT}" | grep -qE '\[arm-linux\] SYSINFO #0 ld=[0-9]+\.[0-9]+ cpu=[0-9]+\.[0-9]+% mem=[0-9]+\.[0-9]+% mf=[0-9]+M up=[0-9]+s'; then
    echo "PASS: sysinfo format correct"
    echo "  output: ${OUTPUT}"
else
    echo "FAIL: unexpected output format"
    echo "  got: ${OUTPUT}"
    exit 1
fi
