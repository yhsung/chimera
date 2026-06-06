#!/usr/bin/env bash
# Verifies syslog-arm-linux outputs the expected sysinfo format.
# Run on Linux with cross-compiled syslog-arm-linux present.
# Exit 77 = SKIP (binary not built yet).
set -euo pipefail
SHOWCASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SHOWCASE_DIR}/syslog-arm-linux"

if [[ ! -f "${BINARY}" ]]; then
    echo "SKIP: ${BINARY} not built"
    exit 77
fi

TMP_SHM=$(mktemp)
dd if=/dev/zero of="${TMP_SHM}" bs=1M count=64 status=none
chmod 600 "${TMP_SHM}"

OUTPUT=$(timeout 8 "${BINARY}" "${TMP_SHM}" 2>/dev/null | head -1 || true)
rm -f "${TMP_SHM}"

if echo "${OUTPUT}" | grep -qE '\[arm-linux\] SYSINFO #0 ld=[0-9]+\.[0-9]+ mf=[0-9]+M up=[0-9]+s'; then
    echo "PASS: sysinfo format correct"
    echo "  output: ${OUTPUT}"
else
    echo "FAIL: unexpected output format"
    echo "  got: ${OUTPUT}"
    exit 1
fi
