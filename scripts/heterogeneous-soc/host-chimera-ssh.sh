#!/usr/bin/env bash
# host-chimera-ssh.sh
#
# SSH into a Chimera Debian guest via Lima ProxyJump.
# Resolves Lima's dynamic SSH port automatically.
#
# Usage:
#   bash host-chimera-ssh.sh root@debian-arm64.local
#   bash host-chimera-ssh.sh root@debian-riscv64.local
#   bash host-chimera-ssh.sh root@debian-mipsel.local

set -euo pipefail

LIMA_NAME="${LIMA_NAME:-qemu-dev}"
SSH_CONFIG="${HOME}/.lima/${LIMA_NAME}/ssh.config"

if [[ ! -f "${SSH_CONFIG}" ]]; then
    echo "Lima VM not running (no ssh.config at ${SSH_CONFIG})" >&2
    exit 1
fi

exec ssh -F "${SSH_CONFIG}" \
    -o ProxyCommand="ssh -F '${SSH_CONFIG}' -W %h:%p lima-${LIMA_NAME}" \
    -o PasswordAuthentication=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$@"
