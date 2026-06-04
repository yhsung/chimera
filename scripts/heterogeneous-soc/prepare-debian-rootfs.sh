#!/usr/bin/env bash
# prepare-debian-rootfs.sh
#
# Create minimal Debian rootfs qcow2 disk images via debootstrap.
# Each image is configured for serial-console auto-login and 9p virtio mount.
#
# Architectures:
#   arm64   -> ${ARM_DEBIAN_DISK}   (native debootstrap or qemu-debootstrap)
#   riscv64 -> ${RISCV_DEBIAN_DISK} (qemu-debootstrap)
#   mips    -> ${MIPS_DEBIAN_DISK}  (qemu-debootstrap via debian-ports)
#
# The images include:
#   - systemd with serial-getty auto-login for root
#   - mount utilities for 9p virtio
#   - /mnt/pingpong directory
#   - fstab entry for the 9p share
#
# Environment:
#   DEBIAN_MIRROR       Debian mirror URL (default: http://deb.debian.org/debian)
#   DEBIAN_PORTS_MIRROR Debian-ports mirror for MIPS (default: http://deb.debian.org/debian-ports)
#   DEBIAN_VERSION      Debian release (default: bookworm)
#   ROOTFS_SIZE         Disk image size (default: 1G)
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_PORTS_MIRROR="${DEBIAN_PORTS_MIRROR:-http://deb.debian.org/debian-ports}"
DEBIAN_VERSION="${DEBIAN_VERSION:-bookworm}"
ROOTFS_SIZE="${ROOTFS_SIZE:-1G}"
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus}"

# ── helpers ─────────────────────────────────────────────────────────────────

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# create_debian_disk ARCH QCOW2_PATH MIRROR_URL [EXTRA_DEBOOTSTRAP_ARGS...]
#
# Uses qemu-debootstrap for cross-arch when ARCH != host arch.
# Falls back to plain debootstrap when ARCH == host arch.
create_debian_disk() {
    local target_arch="$1"
    local qcow2_path="$2"
    local mirror_url="$3"
    shift 3
    local extra_args=("$@")

    if [[ -f "${qcow2_path}" ]]; then
        _ok "Disk image already exists: ${qcow2_path} ($(du -sh "${qcow2_path}" | cut -f1))"
        return 0
    fi

    _info "Creating Debian ${DEBIAN_VERSION} rootfs for ${target_arch}..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    local rootfs_dir="${tmpdir}/rootfs"

    # Stage 1: debootstrap
    local host_arch
    host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    if [[ "${target_arch}" == "${host_arch}" ]]; then
        _info "Native debootstrap (${target_arch})..."
        debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            "${extra_args[@]}" \
            "${DEBIAN_VERSION}" \
            "${rootfs_dir}" \
            "${mirror_url}"
    elif command -v qemu-debootstrap &>/dev/null; then
        _info "qemu-debootstrap for ${target_arch}..."
        qemu-debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            "${extra_args[@]}" \
            "${DEBIAN_VERSION}" \
            "${rootfs_dir}" \
            "${mirror_url}"
    else
        _info "qemu-debootstrap not found; using debootstrap --foreign..."
        debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            --foreign \
            "${extra_args[@]}" \
            "${DEBIAN_VERSION}" \
            "${rootfs_dir}" \
            "${mirror_url}"

        # Copy qemu-user-static binary for second stage
        local qemu_static
        case "${target_arch}" in
            arm64)     qemu_static="qemu-aarch64-static" ;;
            riscv64)   qemu_static="qemu-riscv64-static" ;;
            mips|mipseb) qemu_static="qemu-mips-static" ;;
            *)         _die "Unknown qemu-user-static binary for arch: ${target_arch}" ;;
        esac

        if command -v "${qemu_static}" &>/dev/null; then
            cp "$(command -v "${qemu_static}")" "${rootfs_dir}/usr/bin/"
            chroot "${rootfs_dir}" /debootstrap/debootstrap --second-stage
            rm -f "${rootfs_dir}/usr/bin/${qemu_static}"
        else
            _die "${qemu_static} not found. Install qemu-user-static package."
        fi
    fi

    # Stage 2: Configure the rootfs
    _configure_rootfs "${rootfs_dir}" "${target_arch}"

    # Stage 3: Create disk image
    _info "Creating disk image: ${qcow2_path}"
    local raw_img="${tmpdir}/debian-rootfs.raw"
    qemu-img create -f raw "${raw_img}" "${ROOTFS_SIZE}"

    # Format and populate
    mkfs.ext4 -q -F "${raw_img}"

    local mnt_dir="${tmpdir}/mnt"
    mkdir -p "${mnt_dir}"
    # Guard mount with an EXIT trap so the loop device is always released,
    # even when set -e aborts the shell mid-block (RETURN traps don't fire on exit).
    trap 'sudo umount "${mnt_dir}" 2>/dev/null || true' EXIT
    sudo mount -o loop "${raw_img}" "${mnt_dir}"
    sudo cp -a "${rootfs_dir}/." "${mnt_dir}/"
    sudo umount "${mnt_dir}"
    trap - EXIT

    qemu-img convert -f raw -O qcow2 "${raw_img}" "${qcow2_path}"
    rm -f "${raw_img}"

    _ok "Created: ${qcow2_path} ($(du -sh "${qcow2_path}" | cut -f1))"
}

# _configure_rootfs ROOTFS_DIR ARCH
_configure_rootfs() {
    local rootfs="$1"
    local arch="$2"

    local tty
    case "${arch}" in
        arm64)   tty="ttyAMA0" ;;
        riscv64) tty="ttyS0" ;;
        mips)    tty="ttyS0" ;;
        *)       tty="ttyS0" ;;
    esac

    # ── Serial console auto-login ─────────────────────────────────────────
    # Override getty@.service to auto-login root on the serial console
    local getty_override="${rootfs}/etc/systemd/system/getty@.service.d/override.conf"
    sudo mkdir -p "$(dirname "${getty_override}")"

    sudo tee "${getty_override}" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
Type=idle
EOF

    # Enable the serial getty
    sudo ln -sf /lib/systemd/system/getty@.service \
        "${rootfs}/etc/systemd/system/getty.target.wants/getty@${tty}.service" 2>/dev/null || true

    # ── 9p mount point and fstab ──────────────────────────────────────────
    sudo mkdir -p "${rootfs}/mnt/pingpong"

    sudo tee -a "${rootfs}/etc/fstab" >/dev/null <<EOF
pingpong /mnt/pingpong 9p trans=virtio,version=9p2000.L 0 0
EOF

    # ── Hostname ──────────────────────────────────────────────────────────
    echo "debian-${arch}" | sudo tee "${rootfs}/etc/hostname" >/dev/null

    # ── Root password (empty / passwordless) ──────────────────────────────
    # Allow root login with no password on serial console
    if [[ -f "${rootfs}/etc/pam.d/login" ]]; then
        sudo sed -i 's/^auth\s\+required\s\+pam_securetty\.so/#&/' "${rootfs}/etc/pam.d/login" 2>/dev/null || true
    fi
    # Ensure root account is unlocked
    if [[ -f "${rootfs}/etc/shadow" ]]; then
        sudo sed -i 's/^root:[^:]*:/root::/' "${rootfs}/etc/shadow"
    fi

    _ok "Rootfs configured for ${arch} (tty=${tty})"
}

# ── Main ────────────────────────────────────────────────────────────────────

# Check prerequisites
if [[ "$(uname -s)" != "Linux" ]]; then
    _die "This script must run on Linux (requires debootstrap, mount, ext4)"
fi
if ! sudo -n true 2>/dev/null; then
    _die "sudo requires a password; run with passwordless sudo or refresh your token first"
fi
for cmd in debootstrap qemu-img mkfs.ext4; do
    command -v "${cmd}" &>/dev/null || _die "${cmd} not found — install it first"
done

mkdir -p "${ASSET_DIR}"

# ARM64
create_debian_disk "arm64" "${ARM_DEBIAN_DISK}" "${DEBIAN_MIRROR}"

# RISC-V 64
create_debian_disk "riscv64" "${RISCV_DEBIAN_DISK}" "${DEBIAN_MIRROR}"

# MIPS (big-endian, uses debian-ports mirror)
create_debian_disk "mips" "${MIPS_DEBIAN_DISK}" "${DEBIAN_PORTS_MIRROR}" \
    --no-check-gpg
