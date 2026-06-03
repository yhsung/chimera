#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUN_SCRIPT = (
    REPO_ROOT / "scripts" / "heterogeneous-soc" / "run-riscv-freertos-phase5.sh"
)
SERVER_SCRIPT = (
    REPO_ROOT
    / "scripts"
    / "heterogeneous-soc"
    / "start-ivshmem-server-arm-freertos.sh"
)


class Phase5LaunchTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmpdir.name)
        self.bin_dir = self.tmp / "bin"
        self.bin_dir.mkdir()
        self.log_file = self.tmp / "commands.log"
        self.freertos_elf = self.tmp / "freertos-riscv-demo.elf"
        self.freertos_elf.write_bytes(b"ELF")
        self._write_stub(
            self.bin_dir / "qemu-system-riscv64",
            f"""#!/bin/sh
printf 'qemu|%s\\n' "$*" >> {self.log_file}
exit 0
""",
        )
        self._write_stub(
            self.bin_dir / "ivshmem-server",
            f"""#!/bin/sh
printf 'ivshmem-server|%s\\n' "$*" >> {self.log_file}
exit 0
""",
        )
        self._write_stub(self.bin_dir / "ss", "#!/bin/sh\nexit 1\n")

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_stub(self, path: Path, contents: str) -> None:
        path.write_text(textwrap.dedent(contents), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def test_freertos_runner_uses_custom_machine_and_two_chardevs(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "BUILD_DIR": str(self.bin_dir),
                "FREERTOS_DEMO_ELF": str(self.freertos_elf),
                "IVSHMEM_ARM_FREERTOS_SOCKET": "/tmp/ivshmem-arm-freertos/sock",
                "IVSHMEM_RISCV_FREERTOS_SOCKET": "/tmp/ivshmem-riscv-freertos/sock",
            }
        )

        result = subprocess.run(
            ["bash", str(RUN_SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log_file.read_text(encoding="utf-8")
        self.assertIn("chimera-riscv-freertos-demo", log)
        self.assertIn("ivshmem-arm-freertos=armft", log)
        self.assertIn("ivshmem-riscv-freertos=riscvft", log)
        self.assertIn("path=/tmp/ivshmem-arm-freertos/sock", log)
        self.assertIn("path=/tmp/ivshmem-riscv-freertos/sock", log)

    def test_arm_freertos_server_uses_dedicated_socket(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "BUILD_DIR": str(self.bin_dir),
                "IVSHMEM_ARM_FREERTOS_DIR": "/tmp/ivshmem-arm-freertos",
                "IVSHMEM_ARM_FREERTOS_SOCKET": "/tmp/ivshmem-arm-freertos/sock",
            }
        )

        result = subprocess.run(
            ["bash", str(SERVER_SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log_file.read_text(encoding="utf-8")
        self.assertIn("-S /tmp/ivshmem-arm-freertos/sock", log)


if __name__ == "__main__":
    unittest.main()
