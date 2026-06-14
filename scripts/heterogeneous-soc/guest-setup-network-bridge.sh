#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-setup-network-bridge.sh
#
# Creates bridge chbr0 (172.16.100.0/24) and tap-arm, tap-riscv, tap-mips
# devices inside the Lima VM so all three Linux guests share one L2 segment
# with the Lima host.  Avahi mDNS multicast flows across the bridge.
#
# Idempotent: safe to call on every showcase launch.
# Requires sudo (same privilege level as guest-prepare-debian-rootfs.sh).
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script must run on Linux (inside the Lima VM)"
fi

sudo -v 2>/dev/null || die "sudo privileges are required; refresh your sudo token and re-run"

BRIDGE_NAME="${CHIMERA_BRIDGE:-chbr0}"
BRIDGE_IP="${CHIMERA_BRIDGE_IP:-172.16.100.1/24}"

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

# Create bridge if it doesn't exist
if ! ip link show "${BRIDGE_NAME}" &>/dev/null; then
    _info "Creating bridge ${BRIDGE_NAME}..."
    sudo ip link add name "${BRIDGE_NAME}" type bridge
fi

# Assign IP if not already present
if ! ip addr show "${BRIDGE_NAME}" 2>/dev/null | grep -q "${BRIDGE_IP%%/*}"; then
    _info "Assigning ${BRIDGE_IP} to ${BRIDGE_NAME}..."
    sudo ip addr add "${BRIDGE_IP}" dev "${BRIDGE_NAME}" || true
fi

sudo ip link set "${BRIDGE_NAME}" up
_ok "Bridge ${BRIDGE_NAME} up (${BRIDGE_IP})"

# Create each TAP device, attach to bridge
for tap in tap-arm tap-riscv tap-mips; do
    if ! ip link show "${tap}" &>/dev/null; then
        _info "Creating TAP device ${tap}..."
        sudo ip tuntap add dev "${tap}" mode tap user "$(id -un)"
    fi
    # Attach to bridge if not already a bridge member
    if ! bridge link show 2>/dev/null | grep -qE "^[0-9]+: ${tap}[@:]"; then
        sudo ip link set "${tap}" master "${BRIDGE_NAME}" || true
    fi
    sudo ip link set "${tap}" up
    _ok "${tap} up and attached to ${BRIDGE_NAME}"
done
