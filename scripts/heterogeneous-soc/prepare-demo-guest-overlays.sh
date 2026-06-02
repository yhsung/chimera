#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${ARM_INITRAMFS_IMAGE}" "ARM initramfs image"
require_file "${RISCV_INITRAMFS_IMAGE}" "RISC-V initramfs image"

write_overlay_tree() {
    local overlay_root="$1"
    local tty_device="$2"

    mkdir -p \
        "${overlay_root}/etc" \
        "${overlay_root}/mnt/pingpong" \
        "${overlay_root}/usr/sbin"

    cat > "${overlay_root}/etc/fstab" <<EOF
/dev/cdrom	/media/cdrom	iso9660	noauto,ro 0 0
/dev/fd0	/media/floppy	vfat	noauto	0 0
/dev/usbdisk	/media/usb	vfat	noauto	0 0
pingpong	/mnt/pingpong	9p	trans=virtio,version=9p2000.L 0 0
EOF

    cat > "${overlay_root}/usr/sbin/autologin" <<'EOF'
#!/bin/sh
exec /bin/login -f root
EOF
    chmod +x "${overlay_root}/usr/sbin/autologin"

    cat > "${overlay_root}/etc/inittab" <<EOF
::sysinit:/sbin/openrc sysinit --quiet
::wait:/sbin/openrc boot --quiet
::wait:/sbin/openrc default --quiet
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
${tty_device}::respawn:/sbin/getty -n -l /usr/sbin/autologin 115200 ${tty_device} vt100
EOF
}

build_overlay_archive() {
    local tty_device="$1"
    local overlay_archive="$2"
    local base_initramfs="$3"
    local combined_initramfs="$4"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    (
        cd "${tmpdir}"
        mkdir root overlay
        cd root
        gzip -dc "${base_initramfs}" | cpio -idmu --quiet 2>/dev/null
    )

    write_overlay_tree "${tmpdir}/overlay" "${tty_device}"
    cp -R "${tmpdir}/overlay/." "${tmpdir}/root/"

    (
        cd "${tmpdir}/root"
        find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -n9 > "${combined_initramfs}"
    )

    (
        cd "${tmpdir}/overlay"
        find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -n9 > "${overlay_archive}"
    )
    rm -rf "${tmpdir}"
    trap - RETURN
}

mkdir -p "${ARM_BOOT_ASSET_DIR}" "${RISCV_BOOT_ASSET_DIR}"
build_overlay_archive "ttyAMA0" "${ARM_INITRAMFS_OVERLAY}" "${ARM_INITRAMFS_IMAGE}" "${ARM_INITRAMFS_COMBINED}"
build_overlay_archive "ttyS0" "${RISCV_INITRAMFS_OVERLAY}" "${RISCV_INITRAMFS_IMAGE}" "${RISCV_INITRAMFS_COMBINED}"

echo "ARM_INITRAMFS_COMBINED=${ARM_INITRAMFS_COMBINED}"
echo "RISCV_INITRAMFS_COMBINED=${RISCV_INITRAMFS_COMBINED}"
