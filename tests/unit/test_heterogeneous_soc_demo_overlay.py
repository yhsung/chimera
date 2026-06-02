#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
OVERLAY_SCRIPT = REPO_ROOT / "scripts" / "heterogeneous-soc" / "prepare-demo-guest-overlays.sh"
COMMON_SCRIPT = REPO_ROOT / "scripts" / "heterogeneous-soc" / "common.sh"


class DemoGuestOverlayTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmpdir.name)

        self.arm_initramfs = self.tmp / "arm-initramfs.cpio.gz"
        self.riscv_initramfs = self.tmp / "riscv-initramfs.cpio.gz"
        self.arm_boot_dir = self.tmp / "arm-boot"
        self.riscv_boot_dir = self.tmp / "riscv-boot"

        self._create_base_initramfs(self.arm_initramfs)
        self._create_base_initramfs(self.riscv_initramfs)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _create_base_initramfs(self, destination: Path) -> None:
        subprocess.run(
            [
                "sh",
                "-c",
                f"printf '.' | cpio -o -H newc 2>/dev/null | gzip -n9 > {destination}",
            ],
            check=True,
        )

    def _extract_archive(self, archive: Path, destination: Path) -> None:
        destination.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "sh",
                "-c",
                f"cd {destination} && gzip -dc {archive} | cpio -idmu --quiet 2>/dev/null",
            ],
            check=True,
        )

    def test_overlay_bootstraps_autologin_and_pingpong_mount(self):
        env = os.environ.copy()
        env.update(
            {
                "ARM_INITRAMFS_IMAGE": str(self.arm_initramfs),
                "RISCV_INITRAMFS_IMAGE": str(self.riscv_initramfs),
                "ARM_BOOT_ASSET_DIR": str(self.arm_boot_dir),
                "RISCV_BOOT_ASSET_DIR": str(self.riscv_boot_dir),
                "ARM_INITRAMFS_OVERLAY": str(self.arm_boot_dir / "arm-overlay.cpio.gz"),
                "RISCV_INITRAMFS_OVERLAY": str(self.riscv_boot_dir / "riscv-overlay.cpio.gz"),
                "ARM_INITRAMFS_COMBINED": str(self.arm_boot_dir / "arm-combined.cpio.gz"),
                "RISCV_INITRAMFS_COMBINED": str(self.riscv_boot_dir / "riscv-combined.cpio.gz"),
            }
        )

        result = subprocess.run(
            ["bash", str(OVERLAY_SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

        arm_root = self.tmp / "arm-root"
        riscv_root = self.tmp / "riscv-root"
        self._extract_archive(self.arm_boot_dir / "arm-overlay.cpio.gz", arm_root)
        self._extract_archive(self.riscv_boot_dir / "riscv-overlay.cpio.gz", riscv_root)

        for rootfs, tty in ((arm_root, "ttyAMA0"), (riscv_root, "ttyS0")):
            fstab = (rootfs / "etc" / "fstab").read_text(encoding="utf-8")
            inittab = (rootfs / "etc" / "inittab").read_text(encoding="utf-8")
            autologin = (rootfs / "usr" / "sbin" / "autologin").read_text(encoding="utf-8")

            self.assertIn("pingpong\t/mnt/pingpong\t9p\ttrans=virtio,version=9p2000.L 0 0", fstab)
            self.assertIn(
                f"{tty}::respawn:/sbin/getty -n -l /usr/sbin/autologin 115200 {tty} vt100",
                inittab,
            )
            self.assertIn("mount /mnt/pingpong", inittab)
            self.assertEqual(autologin.strip(), "#!/bin/sh\nexec /bin/login -f root")

    def test_default_kernel_cmdlines_preload_9p_modules(self):
        result = subprocess.run(
            [
                "bash",
                "-lc",
                f"source {COMMON_SCRIPT} && printf '%s\\n%s\\n' \"$ARM_KERNEL_CMDLINE\" \"$RISCV_KERNEL_CMDLINE\"",
            ],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        arm_cmdline, riscv_cmdline = result.stdout.strip().splitlines()

        for cmdline in (arm_cmdline, riscv_cmdline):
            self.assertIn("9p", cmdline)
            self.assertIn("9pnet", cmdline)
            self.assertIn("9pnet_virtio", cmdline)


if __name__ == "__main__":
    unittest.main()
