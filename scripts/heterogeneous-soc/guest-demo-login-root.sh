#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" arm "root"
bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" riscv "root"
