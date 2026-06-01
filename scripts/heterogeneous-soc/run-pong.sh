#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

BAR2_PATH="${1:-$(python3 "${SCRIPT_DIR}/find_ivshmem_bar2.py")}"
exec /usr/local/bin/pong "${BAR2_PATH}"
