#!/usr/bin/env bash
# fetch-images.sh
#
# Download Debian kernel .deb packages for all three architectures.
# Uses apt-get download so the latest available version is always pulled —
# no hardcoded URLs that rot when kernel ABIs bump.
#
# Prerequisites:
#   Foreign architectures must be registered with dpkg --add-architecture.
#   install-lima-guest.sh handles this; if running standalone, ensure
#   'dpkg --print-foreign-architectures' includes arm64, riscv64, and mips.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${ASSET_DIR}"
cd "${ASSET_DIR}"

# ── Ensure foreign architectures are registered ────────────────────────────

NEED_UPDATE=0
_add_arch() {
    local arch="$1"
    if dpkg --print-foreign-architectures 2>/dev/null | grep -qxF "${arch}"; then
        return 0
    fi
    if [[ "$(dpkg --print-architecture 2>/dev/null)" == "${arch}" ]]; then
        return 0  # native arch, no --add-architecture needed
    fi
    echo "  Adding foreign architecture: ${arch}"
    sudo dpkg --add-architecture "${arch}" 2>/dev/null || {
        echo "  WARNING: could not add ${arch} architecture" >&2
        return 1
    }
    NEED_UPDATE=1
}

_add_arch arm64
_add_arch riscv64
_add_arch mips || true  # mips is debian-ports; may not be available

if [[ "${NEED_UPDATE}" -eq 1 ]]; then
    echo "  Updating apt cache..."
    sudo apt-get update -qq
fi

# ── Download helpers ──────────────────────────────────────────────────────

# _apt_fetch PKG DST LABEL
#
# Downloads $PKG (with optional :arch suffix, e.g. "linux-image-arm64:arm64")
# and moves the downloaded .deb to $DST.
_apt_fetch() {
    local pkg="$1"
    local dst="$2"
    local label="$3"

    if [[ -f "${dst}" ]]; then
        echo "  skip: ${label} already present ($(du -sh "${dst}" | cut -f1))"
        return 0
    fi

    echo "  Downloading ${label}..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    (
        cd "${tmpdir}"
        apt-get download "${pkg}" 2>&1
    ) || {
        rm -rf "${tmpdir}"
        echo "  WARNING: apt-get download ${pkg} failed" >&2
        echo "    Check that the package exists and apt sources include this architecture." >&2
        return 1
    }

    local downloaded
    downloaded="$(find "${tmpdir}" -maxdepth 1 -name '*.deb' | head -1)"
    if [[ -z "${downloaded}" ]]; then
        rm -rf "${tmpdir}"
        echo "  WARNING: no .deb found after downloading ${pkg}" >&2
        return 1
    fi
    mv "${downloaded}" "${dst}"
    rm -rf "${tmpdir}"
    echo "  ok: ${label} fetched ($(du -sh "${dst}" | cut -f1))"
}

# _apt_fetch_or_search PKG DST LABEL
#
# Like _apt_fetch, but if the exact package name is not found, searches
# for a matching kernel package and downloads the first hit.
_apt_fetch_or_search() {
    local pkg="$1"
    local dst="$2"
    local label="$3"

    if [[ -f "${dst}" ]]; then
        echo "  skip: ${label} already present ($(du -sh "${dst}" | cut -f1))"
        return 0
    fi

    # Try the exact name first.
    if apt-cache show "${pkg}" &>/dev/null; then
        _apt_fetch "${pkg}" "${dst}" "${label}" && return 0
    fi

    # Fall back to a search.
    echo "  Searching for kernel package matching '${pkg}'..."
    local found
    found="$(apt-cache search linux-image 2>/dev/null | grep -E "${pkg}" | head -1 | awk '{print $1}')"
    if [[ -n "${found}" ]]; then
        echo "  Found: ${found}"
        _apt_fetch "${found}" "${dst}" "${label}" && return 0
    fi

    echo "  WARNING: no kernel package found for ${label} (searched: ${pkg})" >&2
    return 1
}

# ── Download kernel packages ──────────────────────────────────────────────

# ARM64: the metapackage linux-image-arm64 always pulls the latest arm64 kernel.
_apt_fetch_or_search "linux-image-arm64" \
    "${ARM_KERNEL_DEB}" \
    "Debian arm64 kernel"

# RISC-V: the metapackage linux-image-riscv64 may not exist in older Debian
# releases; fall back to searching for the versioned package name.
_apt_fetch_or_search "linux-image-riscv64" \
    "${RISCV_KERNEL_DEB}" \
    "Debian riscv64 kernel"

# MIPS: the Malta board kernel is linux-image-*-4kc-malta from debian-ports.
# The metapackage may not exist, so we search by the flavour name.
_apt_fetch_or_search "4kc-malta" \
    "${MIPS_KERNEL_DEB}" \
    "Debian mips 4kc-malta kernel"
