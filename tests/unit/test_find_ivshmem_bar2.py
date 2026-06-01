#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "heterogeneous-soc" / "find_ivshmem_bar2.py"


class FindIvshmemBar2Test(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.sysfs_root = Path(self.tmpdir.name)

    def tearDown(self):
        self.tmpdir.cleanup()

    def _create_device(self, bdf: str, vendor: str, resources=3):
        device_dir = self.sysfs_root / bdf
        device_dir.mkdir(parents=True)
        (device_dir / "vendor").write_text(vendor, encoding="utf-8")
        for index in range(resources):
            (device_dir / f"resource{index}").write_text("", encoding="utf-8")
        return device_dir

    def test_returns_first_matching_bar2_path(self):
        self._create_device("0000:00:01.0", "0x1234")
        match = self._create_device("0000:00:02.0", "0x1af4")

        result = subprocess.run(
            ["python3", str(SCRIPT), "--sysfs-root", str(self.sysfs_root)],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(match / "resource2"))

    def test_fails_when_matching_device_has_no_bar2(self):
        device_dir = self._create_device("0000:00:03.0", "0x1af4", resources=2)
        os.remove(device_dir / "resource1")

        result = subprocess.run(
            ["python3", str(SCRIPT), "--sysfs-root", str(self.sysfs_root)],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("resource2", result.stderr)

    def test_fails_when_no_matching_device_exists(self):
        self._create_device("0000:00:04.0", "0x1234")

        result = subprocess.run(
            ["python3", str(SCRIPT), "--sysfs-root", str(self.sysfs_root)],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No PCI device found", result.stderr)


if __name__ == "__main__":
    unittest.main()
