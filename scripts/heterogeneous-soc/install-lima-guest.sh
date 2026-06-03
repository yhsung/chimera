#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y \
    build-essential \
    acpica-tools \
    bison \
    clang \
    flex \
    git \
    qemu-system-arm \
    qemu-system-misc \
    gcc-aarch64-linux-gnu \
    gcc-riscv64-linux-gnu \
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
