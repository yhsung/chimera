#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_WAIT_SECONDS="${LOGIN_WAIT_SECONDS:-2}"

mount_cmd="busybox mkdir -p /mnt/pingpong && busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong 2>/dev/null || true && busybox ls /mnt/pingpong"

bash "${SCRIPT_DIR}/demo-login-root.sh"
sleep "${LOGIN_WAIT_SECONDS}"
bash "${SCRIPT_DIR}/demo-send-to-pane.sh" arm "${mount_cmd}"
bash "${SCRIPT_DIR}/demo-send-to-pane.sh" riscv "${mount_cmd}"
