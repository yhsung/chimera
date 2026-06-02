#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/demo-send-to-pane.sh" riscv "/mnt/pingpong/pong.sh"
