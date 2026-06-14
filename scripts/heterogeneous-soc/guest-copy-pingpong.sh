#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${PING_BINARY}" "ARM ping binary"
require_file "${PONG_BINARY}" "RISC-V pong binary"

scp -P "${ARM_SSH_PORT}" "${PING_BINARY}" root@localhost:/usr/local/bin/
scp -P "${RISCV_SSH_PORT}" "${PONG_BINARY}" root@localhost:/usr/local/bin/
