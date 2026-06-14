#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-install-ssh-keys-to-guests.sh
#
# Inject macOS SSH public key into each Debian guest qcow2 image so
# chimera-ssh (ProxyJump via Lima) works without a password.
#
# Key discovery order:
#   1. ~/.ssh/id_ed25519.pub  (Lima VM home)
#   2. ~/.ssh/id_rsa.pub      (Lima VM home)
#   3. /Users/yhsung/.ssh/id_ed25519.pub  (macOS home, read-only mount)
#   4. /Users/yhsung/.ssh/id_rsa.pub      (macOS home, read-only mount)
#
# Idempotent — safe to re-run (appends to authorized_keys without duplicates).
#
# Requires: qemu-nbd (qemu-utils package), nbd kernel module, sudo (for mount).
# Must run on Linux inside the Lima VM.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script must run on Linux (requires qemu-nbd and mount)"
fi

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_skip() { printf '\033[0;33m  ↷ skip: %s\033[0m\n' "$*"; }

# ── Locate SSH public key ──────────────────────────────────────────────────────

locate_pubkey() {
    local candidates=(
        "${HOME}/.ssh/id_ed25519.pub"
        "${HOME}/.ssh/id_rsa.pub"
        "/Users/${USER}/.ssh/id_ed25519.pub"
        "/Users/${USER}/.ssh/id_rsa.pub"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "${f}" ]]; then
            printf '%s' "${f}"
            return 0
        fi
    done
    return 1
}

PUBKEY_PATH="$(locate_pubkey)" || true
if [[ -z "${PUBKEY_PATH}" ]]; then
    _info "No SSH public key found in Lima VM or macOS mount."
    _info "Generating a dedicated key pair ~/.ssh/chimera-guest ..."
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t ed25519 -f "${HOME}/.ssh/chimera-guest" -N "" -C "chimera-guest" -q
    PUBKEY_PATH="${HOME}/.ssh/chimera-guest.pub"
    _ok "Generated ${PUBKEY_PATH}"
    _info "To use this key from macOS, copy it: limactl copy qemu-dev:${HOME}/.ssh/chimera-guest ~/.ssh/"
fi

_info "Using SSH public key: ${PUBKEY_PATH}"
read -r PUBKEY < "${PUBKEY_PATH}"

# ── Inject into each guest disk image ──────────────────────────────────────────

inject_key() {
    local disk="$1"
    local label="$2"

    if [[ ! -f "${disk}" ]]; then
        _skip "${label}: disk image missing (${disk})"
        return 0
    fi

    _info "Injecting key into ${label}"

    local nbd_dev="/dev/nbd0"
    local mnt
    mnt="$(mktemp -d)"

    _cleanup() {
        sudo umount "${mnt}" 2>/dev/null || true
        sudo qemu-nbd --disconnect "${nbd_dev}" 2>/dev/null || true
        rmdir "${mnt}" 2>/dev/null || true
    }
    trap _cleanup RETURN

    sudo qemu-nbd --connect="${nbd_dev}" "${disk}"
    sleep 0.3
    sudo mount "${nbd_dev}" "${mnt}"

    sudo mkdir -p "${mnt}/root/.ssh"
    # Create authorized_keys if missing; append without duplicating
    if [[ -f "${mnt}/root/.ssh/authorized_keys" ]]; then
        if grep -qF "${PUBKEY}" "${mnt}/root/.ssh/authorized_keys" 2>/dev/null; then
            _info "  key already present — skipping"
            sudo umount "${mnt}"
            sudo qemu-nbd --disconnect "${nbd_dev}"
            rmdir "${mnt}"
            trap - RETURN
            _ok "${label}"
            return 0
        fi
    fi
    printf '%s\n' "${PUBKEY}" | sudo tee -a "${mnt}/root/.ssh/authorized_keys" >/dev/null
    sudo chmod 600 "${mnt}/root/.ssh/authorized_keys"

    sudo umount "${mnt}"
    sudo qemu-nbd --disconnect "${nbd_dev}"
    rmdir "${mnt}"
    trap - RETURN

    _ok "${label}"
}

sudo modprobe nbd max_part=0 2>/dev/null || true

# Kill any running QEMU guests that hold locks on the disk images.
_info "Stopping any running QEMU guests to release disk locks..."
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
pkill -f "qemu-system-mipsel.*run-chimera"            2>/dev/null || true
sleep 0.5

inject_key "${ARM_DEBIAN_DISK}"   "arm64"
inject_key "${RISCV_DEBIAN_DISK}" "riscv64"
inject_key "${MIPS_DEBIAN_DISK}"  "mipsel"
