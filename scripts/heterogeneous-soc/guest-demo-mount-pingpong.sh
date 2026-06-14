#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mount_cmd="busybox mkdir -p /mnt/pingpong && (busybox grep -q '^pingpong /mnt/pingpong 9p ' /etc/fstab || echo 'pingpong /mnt/pingpong 9p trans=virtio,version=9p2000.L 0 0' >> /etc/fstab) && (mount /mnt/pingpong 2>/dev/null || busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong) && busybox ls /mnt/pingpong"

bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" arm "${mount_cmd}"
bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" riscv "${mount_cmd}"
