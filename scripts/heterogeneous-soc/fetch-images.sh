#!/usr/bin/env bash
# fetch-images.sh
#
# Download Debian kernel .deb packages for all three architectures.
# Arm64 and riscv64 come from the main Debian archive.
# MIPS (big-endian) comes from debian-ports.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${ASSET_DIR}"
cd "${ASSET_DIR}"

_fetch() {
    local dst="$1" url="$2" label="$3"
    if [[ -f "${dst}" ]]; then
        echo "  skip: ${label} already present ($(du -sh "${dst}" | cut -f1))"
    else
        echo "  Downloading ${label}..."
        wget -q --show-progress -O "${dst}" "${url}" || {
            echo "  WARNING: failed to download ${label} from ${url}" >&2
            return 1
        }
        echo "  ok: ${label} fetched"
    fi
}

_fetch "${ARM_KERNEL_DEB}" \
    "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-arm64_6.1.124-1_arm64.deb" \
    "Debian arm64 kernel"

_fetch "${RISCV_KERNEL_DEB}" \
    "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-riscv64_6.1.124-1_riscv64.deb" \
    "Debian riscv64 kernel"

_fetch "${MIPS_KERNEL_DEB}" \
    "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-4kc-malta_6.1.124-1_mips.deb" \
    "Debian mips 4kc-malta kernel"
