#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# DEPRECATED: guest-prepare-riscv-uboot.sh has been replaced by direct OpenSBI boot
# (no U-Boot needed for Debian). This stub exists for backward compatibility only.
echo "WARNING: guest-prepare-riscv-uboot.sh is deprecated." >&2
echo "  Debian kernels boot directly with OpenSBI; U-Boot is no longer required." >&2
echo "  Use guest-prepare-debian-boot-assets.sh to extract kernel + initrd from .deb packages." >&2
exit 0
