#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
# DEPRECATED: guest-prepare-demo-guest-overlays.sh has been replaced by
# guest-prepare-debian-rootfs.sh (which configures systemd directly in the rootfs).
# This stub exists for backward compatibility only.
echo "WARNING: guest-prepare-demo-guest-overlays.sh is deprecated." >&2
echo "  Guest overlays are no longer needed; Debian rootfs configuration is" >&2
echo "  handled by guest-prepare-debian-rootfs.sh (systemd direct configuration)." >&2
exit 0
