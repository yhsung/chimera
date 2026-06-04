#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${ASSET_DIR}"
cd "${ASSET_DIR}"

[[ -f "${ARM_ISO}" ]] || wget -O "${ARM_ISO}" https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-virt-3.21.7-aarch64.iso
[[ -f "${RISCV_ISO}" ]] || wget -O "${RISCV_ISO}" https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/riscv64/alpine-standard-3.23.4-riscv64.iso
[[ -f "${RISCV_UBOOT_ARCHIVE}" ]] || wget -O "${RISCV_UBOOT_ARCHIVE}" https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/riscv64/alpine-uboot-3.23.4-riscv64.tar.gz
[[ -f "${MIPS_ISO}" ]] || wget -O "${MIPS_ISO}" https://dl-cdn.alpinelinux.org/alpine/v3.10/releases/mips/alpine-standard-3.10.0-mips.iso
