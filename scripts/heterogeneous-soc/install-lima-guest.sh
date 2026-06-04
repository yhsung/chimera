#!/usr/bin/env bash
set -euo pipefail

# ── Register foreign architectures for cross-arch kernel downloads ────────
# fetch-images.sh uses apt-get download to pull Debian kernel .deb packages
# for arm64, riscv64, and mips.  dpkg needs each foreign arch registered
# before apt-get update so the package indices include those architectures.
for _arch in arm64 riscv64 mips; do
    if dpkg --print-architecture 2>/dev/null | grep -qxF "${_arch}"; then
        continue  # native arch
    fi
    if dpkg --print-foreign-architectures 2>/dev/null | grep -qxF "${_arch}"; then
        continue  # already registered
    fi
    echo "Adding foreign architecture: ${_arch}"
    sudo dpkg --add-architecture "${_arch}" 2>/dev/null || true
done

sudo apt-get update
sudo apt-get install -y \
    build-essential \
    acpica-tools \
    bison \
    clang \
    debootstrap \
    flex \
    git \
    qemu-system-arm \
    qemu-system-misc \
    qemu-user-static \
    gcc-aarch64-linux-gnu \
    gcc-riscv64-linux-gnu \
    gcc-mips-linux-gnu \
    gcc-riscv64-unknown-elf \
    binutils-riscv64-unknown-elf \
    libarchive-tools \
    libglib2.0-dev \
    libpixman-1-dev \
    libssl-dev \
    lld \
    ninja-build \
    opensbi \
    pciutils \
    pkg-config \
    python3-pip \
    python3-serial \
    python3-venv \
    rsync \
    ssh \
    zlib1g-dev
