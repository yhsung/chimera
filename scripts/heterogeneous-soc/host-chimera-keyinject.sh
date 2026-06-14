#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# host-chimera-keyinject.sh
#
# Inject the macOS host's SSH public key into all Debian guest disk images.
# Runs the guest-install-ssh-keys-to-guests.sh script inside the Lima VM.
#
# Usage:
#   bash host-chimera-keyinject.sh

set -euo pipefail

LIMA_NAME="${LIMA_NAME:-qemu-dev}"
VM_SCRIPT_DIR="${VM_SCRIPT_DIR:-${HOME}/chimera-src/scripts/heterogeneous-soc}"

echo "Injecting SSH public key into Chimera guests..."
echo "  (QEMU must not be running)"
echo ""

limactl shell "${LIMA_NAME}" -- \
    bash "${VM_SCRIPT_DIR}/guest-install-ssh-keys-to-guests.sh"
