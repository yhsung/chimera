#!/usr/bin/env bash
# guest-configure-getty-clear.sh
#
# Prepend a screen-clear escape sequence (ESC[2J ESC[H) to /etc/issue in each
# Debian guest qcow2 image, so the screen is blank by the time the login:
# prompt appears. agetty writes /etc/issue to the TTY verbatim just before
# printing the prompt, so this rides along on output agetty already produces.
#
# An earlier version of this script installed a serial-getty@.service
# ExecStartPre drop-in that wrote the escape sequence directly to the TTY
# (StandardOutput=tty / TTYPath=/dev/%I). That spawns a process which opens
# the serial TTY for writing — open() on a serial line blocks waiting for
# carrier-detect, so the control process intermittently hung, hit
# "start-pre operation timed out", got SIGTERM'd, and sent the unit into an
# endless restart loop (journalctl: "Scheduled restart job, restart counter
# is at N" / "Failed with result 'timeout'"). The screen looked "clean"
# because it kept resetting, but the shell never stayed up long enough for
# the daemon-launch automation to run. Piggy-backing on /etc/issue avoids
# spawning anything that touches the TTY, so no such race exists.
#
# Safe to run repeatedly — skips an already-prefixed /etc/issue, and removes
# any stale ExecStartPre drop-in left behind by the old approach.
# Requires: qemu-nbd (qemu-utils), nbd kernel module, sudo.  Linux only.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script must run on Linux (requires qemu-nbd and mount)"
fi

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_skip() { printf '\033[0;33m  ↷ skip: %s\033[0m\n' "$*"; }

CLEAR_PREFIX=$'\033[2J\033[H'
STALE_DROPIN="etc/systemd/system/serial-getty@.service.d/clear-screen.conf"

configure_issue_clear() {
    local disk="$1"
    local label="$2"

    if [[ ! -f "${disk}" ]]; then
        _skip "${label}: disk image missing (${disk})"
        return 0
    fi

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

    # Remove the stale ExecStartPre drop-in from the earlier (broken) approach
    # — it sends the getty unit into a restart loop if left in place.
    if [[ -f "${mnt}/${STALE_DROPIN}" ]]; then
        sudo rm -f "${mnt}/${STALE_DROPIN}"
        _info "${label}: removed stale getty drop-in that caused a restart loop"
    fi

    local issue_path="${mnt}/etc/issue"
    local current=""
    [[ -f "${issue_path}" ]] && current="$(sudo cat "${issue_path}")"

    if [[ "${current}" == "${CLEAR_PREFIX}"* ]]; then
        _skip "${label}: /etc/issue already prefixed with screen-clear"
    else
        printf '%s%s' "${CLEAR_PREFIX}" "${current}" | sudo tee "${issue_path}" > /dev/null
        _ok "${label}: screen-clear prefix installed in /etc/issue ($(basename "${disk}"))"
    fi
}

sudo modprobe nbd max_part=0 2>/dev/null || true

_info "Stopping any running QEMU guests to release disk locks..."
pkill -f "qemu-system-aarch64.*arm-phase5"  2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5" 2>/dev/null || true
pkill -f "qemu-system-mipsel.*run-chimera"   2>/dev/null || true
sleep 0.5

configure_issue_clear "${ARM_DEBIAN_DISK}"   "arm"
configure_issue_clear "${RISCV_DEBIAN_DISK}" "riscv"
configure_issue_clear "${MIPS_DEBIAN_DISK}"  "mips"
