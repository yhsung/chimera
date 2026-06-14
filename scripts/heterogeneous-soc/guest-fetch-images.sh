#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# guest-fetch-images.sh
#
# Download versioned Debian kernel .deb packages for all three architectures.
# Each package includes both vmlinuz AND initrd.img (unlike Ubuntu kernels which
# require post-install initrd generation via update-initramfs).
#
# Sources:
#   arm64    — Debian Bookworm main (arm64 is fully supported in Bookworm)
#   riscv64  — Debian Trixie main  (riscv64 was added in Trixie; not in Bookworm)
#   mipsel   — Debian Bookworm main (mipsel is in Bookworm; removed in Trixie)
#
# All three use a direct curl-based download from the Debian package index so
# the script works on both Debian and Ubuntu hosts without mixing apt sources.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${ASSET_DIR}"
cd "${ASSET_DIR}"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"

# _fetch_debian_kernel ARCH SUITE PKG_PATTERN DST LABEL
#
# Downloads the versioned Debian kernel .deb for ARCH from Debian SUITE.
# PKG_PATTERN is a regex matched against Package: lines to find the versioned
# binary (e.g. "linux-image-[0-9].*arm64$" skips the metapackage).
# DST is the local output path.
_fetch_debian_kernel() {
    local arch="$1"
    local suite="$2"
    local pkg_pattern="$3"
    local dst="$4"
    local label="$5"

    if [[ -f "${dst}" ]] && [[ -s "${dst}" ]]; then
        # Real kernel .debs are several MB; metapackages are < 100 KB.
        # Use size as the skip heuristic — it avoids dpkg-deb SIGPIPE races
        # and works correctly for both vmlinuz (arm64/mipsel) and vmlinux (riscv64).
        local pkg_size
        pkg_size="$(wc -c < "${dst}" 2>/dev/null || echo 0)"
        if [[ "${pkg_size}" -gt 1000000 ]]; then
            echo "  skip: ${label} already present ($(du -sh "${dst}" | cut -f1))"
            return 0
        fi
        echo "  ${dst} is too small (${pkg_size} bytes) — stale metapackage, re-downloading..."
        rm -f "${dst}"
    fi
    rm -f "${dst}"

    local pkg_idx="${DEBIAN_MIRROR}/dists/${suite}/main/binary-${arch}/Packages.gz"
    echo "  Fetching ${arch} (${suite}) package index..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    if ! curl -fsSL --connect-timeout 30 "${pkg_idx}" \
            | zcat > "${tmpdir}/Packages" 2>/dev/null; then
        echo "  WARNING: could not fetch Debian ${suite} ${arch} package index" >&2
        return 1
    fi

    # Find the first versioned kernel package matching the pattern.
    local pkg_path
    pkg_path="$(awk -v pat="${pkg_pattern}" '
        /^Package:/ { pkg = $2; matched = (pkg ~ pat) }
        matched && /^Filename:/ { print $2; matched=0; exit }
    ' "${tmpdir}/Packages")"

    if [[ -z "${pkg_path}" ]]; then
        echo "  WARNING: no package matching '${pkg_pattern}' found in Debian ${suite} ${arch}" >&2
        return 1
    fi

    echo "  Downloading ${label} (${pkg_path##*/})..."
    if ! curl -fsSL --connect-timeout 60 "${DEBIAN_MIRROR}/${pkg_path}" -o "${dst}"; then
        rm -f "${dst}"
        echo "  WARNING: could not download ${label}" >&2
        return 1
    fi

    echo "  ok: ${label} fetched ($(du -sh "${dst}" | cut -f1))"
}

# ── Download kernel packages ──────────────────────────────────────────────

# ARM64: Debian Bookworm — versioned arm64 kernel (includes vmlinuz + initrd)
_fetch_debian_kernel \
    arm64 bookworm \
    "^linux-image-[0-9].*-arm64$" \
    "${ARM_KERNEL_DEB}" \
    "Debian arm64 kernel"

# RISCV64: Debian Trixie — riscv64 first appeared in Trixie
_fetch_debian_kernel \
    riscv64 trixie \
    "^linux-image-[0-9].*-riscv64$" \
    "${RISCV_KERNEL_DEB}" \
    "Debian riscv64 kernel"

# MIPSEL: Debian Bookworm — 4kc-malta flavour (removed in Trixie)
_fetch_debian_kernel \
    mipsel bookworm \
    "^linux-image-[0-9].*-4kc-malta$" \
    "${MIPS_KERNEL_DEB}" \
    "Debian mipsel 4kc-malta kernel"
