#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${RISCV_UBOOT_ARCHIVE}" "RISC-V U-Boot archive"

rm -rf "${RISCV_UBOOT_DIR}"
mkdir -p "${RISCV_UBOOT_DIR}"
tar -C "${RISCV_UBOOT_DIR}" -xf "${RISCV_UBOOT_ARCHIVE}"

require_file "${RISCV_UBOOT_BIN}" "RISC-V U-Boot binary"
