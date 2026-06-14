#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-prepare-debian-boot-assets.sh
#
# Verify that vmlinuz and initrd.img exist in each architecture's boot asset
# directory.  These files are created by guest-prepare-debian-rootfs.sh when it
# installs the kernel .deb inside the debootstrap rootfs (which triggers
# update-initramfs).  If they are missing, the rootfs must be (re)created.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_boot_assets() {
    local arch="$1"
    local vmlinuz="$2"
    local initrd="$3"

    if [[ -f "${vmlinuz}" ]] && [[ -f "${initrd}" ]]; then
        echo "  ok: ${arch} boot assets present"
        echo "       vmlinuz: ${vmlinuz} ($(du -sh "${vmlinuz}" | cut -f1))"
        echo "       initrd:  ${initrd} ($(du -sh "${initrd}" | cut -f1))"
        return 0
    fi

    echo "ERROR: ${arch} boot assets missing." >&2
    echo "  Expected:" >&2
    echo "    vmlinuz: ${vmlinuz}" >&2
    echo "    initrd:  ${initrd}" >&2
    echo "  Re-run guest-prepare-debian-rootfs.sh to recreate the rootfs with kernel." >&2
    return 1
}

require_boot_assets "ARM"    "${ARM_KERNEL_IMAGE}"   "${ARM_INITRD_IMAGE}"
require_boot_assets "RISCV"  "${RISCV_KERNEL_IMAGE}" "${RISCV_INITRD_IMAGE}"
require_boot_assets "MIPS"   "${MIPS_KERNEL_IMAGE}"  "${MIPS_INITRD_IMAGE}"
