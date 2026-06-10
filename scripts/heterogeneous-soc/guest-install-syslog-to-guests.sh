#!/usr/bin/env bash
# guest-install-syslog-to-guests.sh
#
# Inject syslog-*-linux daemons into each Debian guest qcow2 image at
# /usr/local/bin/ so guests can launch the daemon without the 9p pingpong share.
# Safe to run repeatedly — overwrites the binary on each invocation.
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

# inject_binary DISK BINARY DESTNAME
# Mounts DISK via qemu-nbd, copies BINARY to /usr/local/bin/DESTNAME, unmounts.
inject_binary() {
    local disk="$1"
    local binary="$2"
    local dest_name="$3"

    if [[ ! -f "${disk}" ]]; then
        _skip "${dest_name}: disk image missing (${disk})"
        return 0
    fi
    if [[ ! -f "${binary}" ]]; then
        _skip "${dest_name}: binary not built (cross-compiler absent)"
        return 0
    fi

    _info "Installing ${dest_name} → $(basename "${disk}"):/usr/local/bin/${dest_name}"

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
    sudo mkdir -p "${mnt}/usr/local/bin"
    sudo cp "${binary}" "${mnt}/usr/local/bin/${dest_name}"
    sudo chmod 755 "${mnt}/usr/local/bin/${dest_name}"
    sudo umount "${mnt}"
    sudo qemu-nbd --disconnect "${nbd_dev}"
    rmdir "${mnt}"
    trap - RETURN

    _ok "${dest_name} installed in $(basename "${disk}")"
}

sudo modprobe nbd max_part=0 2>/dev/null || true

# Kill any QEMU guests that have the disk images open so qemu-nbd can acquire
# a write lock.  These are the same patterns used in guest-run-chimera-showcase.sh.
_info "Stopping any running QEMU guests to release disk locks..."
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
pkill -f "qemu-system-mipsel.*run-chimera"            2>/dev/null || true
sleep 0.5   # allow processes to exit and release file locks

inject_binary "${ARM_DEBIAN_DISK}"   "${SYSLOG_ARM_BINARY}"   "syslog-arm-linux"
inject_binary "${ARM_DEBIAN_DISK}"   "${CAN_LOG_ARM_BINARY}"  "can-log-arm-linux"
inject_binary "${RISCV_DEBIAN_DISK}" "${SYSLOG_RISCV_BINARY}" "syslog-riscv-linux"
inject_binary "${MIPS_DEBIAN_DISK}"  "${SYSLOG_MIPS_BINARY}"  "syslog-mips-linux"
