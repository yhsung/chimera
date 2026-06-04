#!/usr/bin/env bash
# prepare-debian-boot-assets.sh
#
# Extract vmlinuz and initrd.img from a Debian kernel .deb package.
# Called per architecture: the arch is inferred from the .deb filename.
#
# Expected kernel .deb files (downloaded by fetch-images.sh):
#   ${ARM_KERNEL_DEB}    -> arm64 kernel
#   ${RISCV_KERNEL_DEB}  -> riscv64 kernel
#   ${MIPS_KERNEL_DEB}   -> mips kernel
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

_extract_kernel_deb() {
    local deb_path="$1"
    local boot_dir="$2"

    require_file "${deb_path}" "kernel .deb package"

    mkdir -p "${boot_dir}"

    # Extract vmlinuz and initrd.img from the .deb
    # Debian kernel packages contain ./boot/vmlinuz-* and ./boot/initrd.img-*
    dpkg-deb -x "${deb_path}" "${boot_dir}"

    # Find the extracted files (version suffix varies)
    local vmlinuz_src
    vmlinuz_src="$(find "${boot_dir}/boot" -maxdepth 1 -name 'vmlinuz-*' -not -name '*.old-dkms' 2>/dev/null | head -1)"
    local initrd_src
    initrd_src="$(find "${boot_dir}/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | head -1)"

    if [[ -z "${vmlinuz_src}" ]]; then
        # Fallback: the deb may extract to ./boot directly with a flat structure
        vmlinuz_src="$(find "${boot_dir}" -maxdepth 3 -name 'vmlinuz-*' -not -name '*.old-dkms' 2>/dev/null | head -1)"
        initrd_src="$(find "${boot_dir}" -maxdepth 3 -name 'initrd.img-*' 2>/dev/null | head -1)"
    fi

    if [[ -z "${vmlinuz_src}" ]]; then
        echo "ERROR: could not find vmlinuz in extracted .deb at ${boot_dir}" >&2
        echo "Contents:" >&2
        find "${boot_dir}" -type f | head -20 >&2
        exit 1
    fi

    # Copy to the expected flat path
    cp "${vmlinuz_src}" "${boot_dir}/vmlinuz"
    cp "${initrd_src}" "${boot_dir}/initrd.img"

    echo "Extracted: ${boot_dir}/vmlinuz"
    echo "Extracted: ${boot_dir}/initrd.img"
}

# ARM
_extract_kernel_deb "${ARM_KERNEL_DEB}" "${ARM_BOOT_ASSET_DIR}"
echo "ARM_KERNEL_IMAGE=${ARM_BOOT_ASSET_DIR}/vmlinuz"
echo "ARM_INITRD_IMAGE=${ARM_BOOT_ASSET_DIR}/initrd.img"

# RISC-V
_extract_kernel_deb "${RISCV_KERNEL_DEB}" "${RISCV_BOOT_ASSET_DIR}"
echo "RISCV_KERNEL_IMAGE=${RISCV_BOOT_ASSET_DIR}/vmlinuz"
echo "RISCV_INITRD_IMAGE=${RISCV_BOOT_ASSET_DIR}/initrd.img"

# MIPS
_extract_kernel_deb "${MIPS_KERNEL_DEB}" "${MIPS_BOOT_ASSET_DIR}"
echo "MIPS_KERNEL_IMAGE=${MIPS_BOOT_ASSET_DIR}/vmlinuz"
echo "MIPS_INITRD_IMAGE=${MIPS_BOOT_ASSET_DIR}/initrd.img"
