#!/usr/bin/env bash
# guest-prepare-debian-rootfs.sh
#
# Create minimal Debian rootfs qcow2 disk images via debootstrap.
# Each image is configured for serial-console auto-login and 9p virtio mount.
# Installs the kernel .deb inside the chroot so that update-initramfs generates
# a proper initrd; vmlinuz and initrd.img are copied to the boot asset directory
# before the qcow2 is created.
#
# Architectures:
#   arm64   -> ${ARM_DEBIAN_DISK}   (Debian Bookworm)
#   riscv64 -> ${RISCV_DEBIAN_DISK} (Debian Trixie; riscv64 not in Bookworm)
#   mipsel  -> ${MIPS_DEBIAN_DISK}  (Debian Bookworm)
#
# Environment:
#   DEBIAN_MIRROR          Debian mirror URL (default: http://deb.debian.org/debian)
#   DEBIAN_VERSION         Debian release for arm64/mipsel (default: bookworm)
#   DEBIAN_RISCV_VERSION   Debian release for riscv64 (default: trixie)
#   ROOTFS_SIZE            Disk image size (default: 1G)
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_VERSION="${DEBIAN_VERSION:-bookworm}"
DEBIAN_RISCV_VERSION="${DEBIAN_RISCV_VERSION:-trixie}"
ROOTFS_SIZE="${ROOTFS_SIZE:-1G}"
# initramfs-tools: generates initrd in kernel postinst
# kmod: needed by depmod (called during kernel install)
# linux-base: required by Debian kernel postinst scripts
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus,initramfs-tools,kmod,linux-base,avahi-daemon,libnss-mdns,iproute2,openssh-server}"

# ── helpers ─────────────────────────────────────────────────────────────────

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# create_debian_disk ARCH QCOW2_PATH MIRROR_URL KERNEL_DEB BOOT_DIR [EXTRA...]
#
# KERNEL_DEB: path to the versioned kernel .deb (e.g. linux-image-6.1.0-42-arm64)
# BOOT_DIR:   directory where vmlinuz and initrd.img will be placed
#
# Installs KERNEL_DEB inside the rootfs chroot so update-initramfs runs and
# generates /boot/initrd.img-*.  Both vmlinuz and initrd.img are then copied
# to BOOT_DIR before the qcow2 is created.
create_debian_disk() {
    local target_arch="$1"
    local qcow2_path="$2"
    local mirror_url="$3"
    local kernel_deb="$4"
    local boot_dir="$5"
    shift 5
    local extra_args=("$@")

    # riscv64 was added in Debian Trixie; arm64 and mipsel use Bookworm.
    local debian_version
    case "${target_arch}" in
        riscv64) debian_version="${DEBIAN_RISCV_VERSION}" ;;
        *)       debian_version="${DEBIAN_VERSION}" ;;
    esac

    # Skip if both qcow2 and boot assets already exist.
    if [[ -f "${qcow2_path}" ]] && \
       [[ -f "${boot_dir}/vmlinuz" ]] && \
       [[ -f "${boot_dir}/initrd.img" ]]; then
        _ok "Disk image and boot assets already exist: ${qcow2_path##*/}"
        return 0
    fi

    _info "Creating Debian ${debian_version} rootfs for ${target_arch}..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'sudo rm -rf "${tmpdir}"' RETURN

    local rootfs_dir="${tmpdir}/rootfs"

    # Stage 1: debootstrap
    local host_arch
    host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    if [[ "${target_arch}" == "${host_arch}" ]]; then
        _info "Native debootstrap (${target_arch})..."
        sudo debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            "${extra_args[@]}" \
            "${debian_version}" \
            "${rootfs_dir}" \
            "${mirror_url}"
    elif command -v qemu-debootstrap &>/dev/null; then
        _info "qemu-debootstrap for ${target_arch}..."
        sudo qemu-debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            "${extra_args[@]}" \
            "${debian_version}" \
            "${rootfs_dir}" \
            "${mirror_url}"
    else
        _info "qemu-debootstrap not found; using debootstrap --foreign..."
        sudo debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            --foreign \
            "${extra_args[@]}" \
            "${debian_version}" \
            "${rootfs_dir}" \
            "${mirror_url}"

        local qemu_static
        case "${target_arch}" in
            arm64)   qemu_static="qemu-aarch64-static" ;;
            riscv64) qemu_static="qemu-riscv64-static" ;;
            mipsel)  qemu_static="qemu-mipsel-static" ;;
            *)       _die "Unknown qemu-user-static binary for arch: ${target_arch}" ;;
        esac

        if command -v "${qemu_static}" &>/dev/null; then
            sudo cp "$(command -v "${qemu_static}")" "${rootfs_dir}/usr/bin/"
            sudo chroot "${rootfs_dir}" /debootstrap/debootstrap --second-stage
            sudo rm -f "${rootfs_dir}/usr/bin/${qemu_static}"
        else
            _die "${qemu_static} not found. Install qemu-user-static package."
        fi
    fi

    # Stage 2: Install kernel .deb inside the rootfs.
    # The kernel's postinst calls update-initramfs which generates initrd.img.
    if [[ -f "${kernel_deb}" ]]; then
        _info "Installing kernel in rootfs (this triggers initrd generation)..."

        # Ensure VirtIO and 9p modules are loaded early by the initrd so QEMU
        # guests can mount the virtio-blk root disk and the 9p pingpong share.
        sudo mkdir -p "${rootfs_dir}/etc/initramfs-tools"
        sudo tee "${rootfs_dir}/etc/initramfs-tools/modules" >/dev/null <<'MODS'
# Force-load drivers so the initrd can find the root block device.
# Architecture-specific drivers are added by create_debian_disk() below
# at call time; the common set is kept here.
9p
9pnet
9pnet_virtio
MODS

        # Append architecture-specific block device drivers so the initrd can
        # find the root disk.  ARM/RISCV use virtio-blk-pci; MIPS uses the
        # Malta board's native PIIX4 IDE (ata_piix) for the root disk because
        # virtio-pci does not enumerate correctly on the Malta machine for
        # the disk controller.  However the network is still on virtio-net-pci,
        # so the initrd must also pull in virtio_pci + virtio_net or the
        # interface never comes up (the kernel can't enumerate the PCI virtio
        # device until those modules are loaded).
        local block_driver
        case "${target_arch}" in
            mipsel) block_driver="ata_piix virtio_pci virtio_net" ;;
            *)      block_driver="virtio_pci virtio_blk virtio_mmio" ;;
        esac
        for d in ${block_driver}; do
            echo "${d}" | sudo tee -a "${rootfs_dir}/etc/initramfs-tools/modules" >/dev/null
        done

        local kern_basename
        kern_basename="$(basename "${kernel_deb}")"
        sudo cp "${kernel_deb}" "${rootfs_dir}/tmp/${kern_basename}"
        # --force-depends in case not all dependencies are in the minbase rootfs.
        sudo chroot "${rootfs_dir}" dpkg --force-depends -i "/tmp/${kern_basename}" \
            2>&1 | grep -v "^(Reading database" | tail -20 || true
        sudo rm -f "${rootfs_dir}/tmp/${kern_basename}"
    fi

    # Stage 3: Copy vmlinuz (or vmlinux for riscv64) and initrd to boot_dir.
    local vmlinuz_src initrd_src
    # Debian riscv64 ships vmlinux (uncompressed ELF); others use vmlinuz.
    vmlinuz_src="$(find "${rootfs_dir}/boot" -maxdepth 1 \
        \( -name 'vmlinuz-*' -o -name 'vmlinux-*' \) \
        -not -name '*.old-dkms' 2>/dev/null | head -1)" || true
    initrd_src="$(find "${rootfs_dir}/boot" -maxdepth 1 \
        -name 'initrd.img-*' 2>/dev/null | head -1)" || true

    if [[ -z "${vmlinuz_src}" ]]; then
        _die "No vmlinuz/vmlinux found in ${rootfs_dir}/boot after kernel install"
    fi
    if [[ -z "${initrd_src}" ]]; then
        _die "No initrd.img found in ${rootfs_dir}/boot after kernel install"
    fi

    mkdir -p "${boot_dir}"
    cp "${vmlinuz_src}" "${boot_dir}/vmlinuz"
    cp "${initrd_src}"  "${boot_dir}/initrd.img"
    _ok "Boot assets extracted to ${boot_dir}/"

    # Stage 4: Configure the rootfs
    _configure_rootfs "${rootfs_dir}" "${target_arch}"

    # Stage 5: Create disk image
    _info "Creating disk image: ${qcow2_path}"
    local raw_img="${tmpdir}/debian-rootfs.raw"
    qemu-img create -f raw "${raw_img}" "${ROOTFS_SIZE}"

    mkfs.ext4 -q -F "${raw_img}"

    local mnt_dir="${tmpdir}/mnt"
    mkdir -p "${mnt_dir}"
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
        mipsel)  tty="ttyS0" ;;
        *)       tty="ttyS0" ;;
    esac

    local getty_override="${rootfs}/etc/systemd/system/getty@.service.d/override.conf"
    sudo mkdir -p "$(dirname "${getty_override}")"

    sudo tee "${getty_override}" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
Type=idle
EOF

    sudo ln -sf /lib/systemd/system/getty@.service \
        "${rootfs}/etc/systemd/system/getty.target.wants/getty@${tty}.service" 2>/dev/null || true

    sudo mkdir -p "${rootfs}/mnt/pingpong"

    sudo tee -a "${rootfs}/etc/fstab" >/dev/null <<EOF
pingpong /mnt/pingpong 9p trans=virtio,version=9p2000.L,nofail 0 0
EOF

    echo "debian-${arch}" | sudo tee "${rootfs}/etc/hostname" >/dev/null

    # minbase debootstrap may not run update-alternatives for init-system-helpers,
    # leaving /usr/sbin/init missing.  Create it manually so the kernel can exec
    # systemd as PID 1.  With usr-is-merged, /lib -> usr/lib so the target path
    # /lib/systemd/systemd resolves correctly via the symlink chain.
    if [[ -e "${rootfs}/lib/systemd/systemd" ]] && [[ ! -e "${rootfs}/usr/sbin/init" ]]; then
        sudo ln -sf /lib/systemd/systemd "${rootfs}/usr/sbin/init"
    fi

    if [[ -f "${rootfs}/etc/pam.d/login" ]]; then
        sudo sed -i 's/^auth\s\+required\s\+pam_securetty\.so/#&/' "${rootfs}/etc/pam.d/login" 2>/dev/null || true
    fi
    if [[ -f "${rootfs}/etc/shadow" ]]; then
        sudo sed -i 's/^root:[^:]*:/root::/' "${rootfs}/etc/shadow"
    fi

    # ── Network: static IP via systemd-networkd ──────────────────────────────
    local guest_ip
    case "${arch}" in
        arm64)   guest_ip="172.16.100.10" ;;
        riscv64) guest_ip="172.16.100.11" ;;
        mipsel)  guest_ip="172.16.100.12" ;;
        *)       guest_ip="172.16.100.99" ;;
    esac

    sudo mkdir -p "${rootfs}/etc/systemd/network"
    sudo tee "${rootfs}/etc/systemd/network/10-eth.network" >/dev/null <<EOF
[Match]
Name=e*

[Network]
Address=${guest_ip}/24
EOF

    # ── NSS: .local mDNS resolution via libnss-mdns ──────────────────────────
    if [[ -f "${rootfs}/etc/nsswitch.conf" ]]; then
        sudo sed -i \
            's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' \
            "${rootfs}/etc/nsswitch.conf"
    else
        sudo tee "${rootfs}/etc/nsswitch.conf" >/dev/null <<'NSSEOF'
passwd:         files
group:          files
hosts:          files mdns4_minimal [NOTFOUND=return] dns
networks:       files
protocols:      db files
services:       db files
NSSEOF
    fi

    # ── Enable systemd-networkd ───────────────────────────────────────────────
    sudo mkdir -p "${rootfs}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /lib/systemd/system/systemd-networkd.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
        2>/dev/null || true

    # ── Avahi service definitions ─────────────────────────────────────────────
    local avahi_arch
    case "${arch}" in
        arm64)   avahi_arch="arm64" ;;
        riscv64) avahi_arch="riscv64" ;;
        mipsel)  avahi_arch="mipsel" ;;
        *)       avahi_arch="unknown" ;;
    esac

    sudo mkdir -p "${rootfs}/etc/avahi/services"

    sudo tee "${rootfs}/etc/avahi/services/ssh.service" >/dev/null <<'XMLEOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">SSH on %h</name>
  <service>
    <type>_ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
XMLEOF

    sudo tee "${rootfs}/etc/avahi/services/chimera-syslog.service" >/dev/null <<XMLEOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Chimera syslog on %h</name>
  <service>
    <type>_chimera-syslog._tcp</type>
    <port>0</port>
    <txt-record>arch=${avahi_arch}</txt-record>
  </service>
</service-group>
XMLEOF

    # ── Enable avahi-daemon ───────────────────────────────────────────────────
    sudo ln -sf /lib/systemd/system/avahi-daemon.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/avahi-daemon.service" \
        2>/dev/null || true

    # ── Enable sshd (Debian unit is ssh.service) ──────────────────────────────
    sudo ln -sf /lib/systemd/system/ssh.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/ssh.service" \
        2>/dev/null || true

    _ok "Rootfs configured for ${arch} (tty=${tty})"
}

# ── Main ────────────────────────────────────────────────────────────────────

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

# ARM64 — Debian Bookworm
create_debian_disk "arm64" "${ARM_DEBIAN_DISK}" "${DEBIAN_MIRROR}" \
    "${ARM_KERNEL_DEB}" "${ARM_BOOT_ASSET_DIR}"

# RISC-V 64 — Debian Trixie
create_debian_disk "riscv64" "${RISCV_DEBIAN_DISK}" "${DEBIAN_MIRROR}" \
    "${RISCV_KERNEL_DEB}" "${RISCV_BOOT_ASSET_DIR}"

# MIPS (little-endian mipsel) — Debian Bookworm
create_debian_disk "mipsel" "${MIPS_DEBIAN_DISK}" "${DEBIAN_MIRROR}" \
    "${MIPS_KERNEL_DEB}" "${MIPS_BOOT_ASSET_DIR}"
