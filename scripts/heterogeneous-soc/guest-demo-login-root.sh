#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" arm "root"
bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" riscv "root"
