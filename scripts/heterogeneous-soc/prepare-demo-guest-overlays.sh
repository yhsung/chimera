#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${ARM_INITRAMFS_IMAGE}" "ARM initramfs image"
require_file "${RISCV_INITRAMFS_IMAGE}" "RISC-V initramfs image"

# write_overlay_tree OVERLAY_ROOT TTY_DEVICE [HELLO_BIN]
#
# HELLO_BIN: optional absolute path of the hello binary *inside* the guest
#            (e.g. /mnt/pingpong/freertos-showcase/hello-arm-linux).
#            When supplied, a ::once: inittab entry runs it automatically
#            after the 9p share is mounted — no interactive login required.
write_overlay_tree() {
    local overlay_root="$1"
    local tty_device="$2"
    local hello_bin="${3:-}"

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

    # Build the optional auto-run line.  Spin until 9p is mounted, then exec
    # the binary so it owns the process slot and its output goes to the console.
    local hello_run_line=""
    if [[ -n "${hello_bin}" ]]; then
        hello_run_line="::once:/bin/sh -c 'until mountpoint -q /mnt/pingpong 2>/dev/null; do sleep 1; done; exec ${hello_bin}'"
    fi

    cat > "${overlay_root}/etc/inittab" <<EOF
::sysinit:/sbin/openrc sysinit --quiet
::wait:/sbin/openrc boot --quiet
::wait:/sbin/openrc default --quiet
::once:/bin/sh -c 'mkdir -p /mnt/pingpong; mount /mnt/pingpong 2>/dev/null || mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong 2>/dev/null || true'
${hello_run_line}
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
${tty_device}::respawn:/sbin/getty -n -l /usr/sbin/autologin 115200 ${tty_device} vt100
EOF
}

# build_overlay_archive TTY_DEVICE OVERLAY_ARCHIVE BASE_INITRAMFS COMBINED_INITRAMFS [HELLO_BIN]
build_overlay_archive() {
    local tty_device="$1"
    local overlay_archive="$2"
    local base_initramfs="$3"
    local combined_initramfs="$4"
    local hello_bin="${5:-}"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    (
        cd "${tmpdir}"
        mkdir root overlay
        cd root
        gzip -dc "${base_initramfs}" | cpio -idmu --quiet 2>/dev/null
    )

    write_overlay_tree "${tmpdir}/overlay" "${tty_device}" "${hello_bin}"
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
build_overlay_archive "ttyAMA0" "${ARM_INITRAMFS_OVERLAY}" "${ARM_INITRAMFS_IMAGE}" \
    "${ARM_INITRAMFS_COMBINED}" "/mnt/pingpong/freertos-showcase/hello-arm-linux"
build_overlay_archive "ttyS0"   "${RISCV_INITRAMFS_OVERLAY}" "${RISCV_INITRAMFS_IMAGE}" \
    "${RISCV_INITRAMFS_COMBINED}" "/mnt/pingpong/freertos-showcase/hello-riscv-linux"

echo "ARM_INITRAMFS_COMBINED=${ARM_INITRAMFS_COMBINED}"
echo "RISCV_INITRAMFS_COMBINED=${RISCV_INITRAMFS_COMBINED}"
