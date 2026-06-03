#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

import os
import subprocess
import unittest


class ChimeraFreeRTOSMachineTest(unittest.TestCase):
    def test_machine_is_registered(self):
        qemu = os.environ["QEMU_RISCV64_BIN"]
        result = subprocess.run(
            [qemu, "-machine", "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("chimera-riscv-freertos-demo", result.stdout)

    def test_machine_requires_both_ivshmem_links(self):
        qemu = os.environ["QEMU_RISCV64_BIN"]
        result = subprocess.run(
            [qemu, "-M", "chimera-riscv-freertos-demo", "-nographic",
             "-display", "none"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ivshmem-arm-freertos", result.stderr)
        self.assertIn("ivshmem-riscv-freertos", result.stderr)


if __name__ == "__main__":
    unittest.main()
