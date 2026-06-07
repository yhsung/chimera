#!/usr/bin/env bash
# guest-configure-getty-clear.sh
#
# Install a serial-getty@.service drop-in into each Debian guest qcow2 image
# so the terminal is cleared before the login: prompt is displayed.
#
# serial-getty@.service already sets StandardOutput=tty / TTYPath=/dev/%I, so
# an ExecStartPre that writes to stdout goes directly to the serial console.
# The ANSI sequences used: ESC[2J = erase display, ESC[H = cursor home.
#
# Safe to run repeatedly — overwrites the drop-in on each invocation.
# Requires: qemu-nbd (qemu-utils), nbd kernel module, sudo.  Linux only.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script must run on Linux (requires qemu-nbd and mount)"
fi

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_skip() { printf '\033[0;33m  ↷ skip: %s\033[0m\n' "$*"; }

DROPIN_DIR="etc/systemd/system/serial-getty@.service.d"
DROPIN_NAME="clear-screen.conf"

# ExecStartPre runs with StandardOutput=tty inherited from the unit, so printf
# writes to the serial console.  \033[2J clears the screen; \033[H homes the
# cursor.  Double-backslash so the shell inside -c receives a single backslash.
DROPIN_CONTENT='[Service]
ExecStartPre=/bin/sh -c "printf \"\\033[2J\\033[H\""
'

install_getty_clear() {
    local disk="$1"
    local label="$2"

    if [[ ! -f "${disk}" ]]; then
        _skip "${label}: disk image missing (${disk})"
        return 0
    fi

    local dest_path="${DROPIN_DIR}/${DROPIN_NAME}"

    # Skip if the drop-in is already current.
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

    if [[ -f "${mnt}/${dest_path}" ]] &&
       [[ "$(sudo cat "${mnt}/${dest_path}")" == "${DROPIN_CONTENT}" ]]; then
        sudo umount "${mnt}"
        sudo qemu-nbd --disconnect "${nbd_dev}"
        rmdir "${mnt}"
        trap - RETURN
        _skip "${label}: getty clear drop-in already current"
        return 0
    fi

    sudo mkdir -p "${mnt}/${DROPIN_DIR}"
    printf '%s' "${DROPIN_CONTENT}" | sudo tee "${mnt}/${dest_path}" > /dev/null
    sudo umount "${mnt}"
    sudo qemu-nbd --disconnect "${nbd_dev}"
    rmdir "${mnt}"
    trap - RETURN

    _ok "${label}: getty clear drop-in installed ($(basename "${disk}"))"
}

sudo modprobe nbd max_part=0 2>/dev/null || true

_info "Stopping any running QEMU guests to release disk locks..."
pkill -f "qemu-system-aarch64.*arm-phase5"  2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5" 2>/dev/null || true
pkill -f "qemu-system-mipsel.*run-chimera"   2>/dev/null || true
sleep 0.5

install_getty_clear "${ARM_DEBIAN_DISK}"   "arm"
install_getty_clear "${RISCV_DEBIAN_DISK}" "riscv"
install_getty_clear "${MIPS_DEBIAN_DISK}"  "mips"
