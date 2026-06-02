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
SCRIPT = REPO_ROOT / "scripts" / "heterogeneous-soc" / "ghostty-demo.sh"


class GhosttyDemoTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmpdir.name)
        self.bin_dir = self.tmp / "bin"
        self.bin_dir.mkdir()
        self.tmux_log = self.tmp / "tmux.log"
        self.tmux_counter = self.tmp / "tmux-counter"
        self.home_dir = self.tmp / "home"
        self.home_dir.mkdir()

        self._write_stub(
            self.bin_dir / "tmux",
            f"""#!/bin/sh
set -eu
log_file={self.tmux_log}
counter_file={self.tmux_counter}
cmd="${{1:-}}"
shift || true

case "$cmd" in
  has-session)
    exit 1
    ;;
  new-session|select-pane|select-layout|attach)
    exit 0
    ;;
  display-message)
    printf '%%0\\n'
    ;;
  split-window)
    count=0
    if [ -f "$counter_file" ]; then
      count=$(cat "$counter_file")
    fi
    count=$((count + 1))
    printf '%s' "$count" > "$counter_file"
    printf '%%%%%s\\n' "$count"
    ;;
  send-keys)
    printf 'send-keys|%s\\n' "$*" >> "$log_file"
    exit 0
    ;;
  *)
    printf 'tmux-stub-unhandled|%s %s\\n' "$cmd" "$*" >> "$log_file"
    exit 0
    ;;
esac
""",
        )
        self._write_stub(self.bin_dir / "infocmp", "#!/bin/sh\nexit 0\n")
        self._write_stub(
            self.bin_dir / "limactl",
            f"""#!/bin/sh
set -eu
printf 'limactl|%s\\n' "$*" >> {self.tmux_log}
exit 0
""",
        )

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_stub(self, path: Path, contents: str) -> None:
        path.write_text(textwrap.dedent(contents), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def test_lima_mode_wraps_guest_launch_commands(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "HOME": str(self.home_dir),
                "RUN_IN_LIMA": "1",
                "LIMA_NAME": "qemu-dev",
                "BUILD_DIR": str(self.home_dir / "chimera-build-linux-2"),
                "VM_SOURCE_DIR": str(self.home_dir / "chimera-src"),
                "SESSION_NAME": "heterogeneous-soc-test",
                "SERVER_SCRIPT": "scripts/heterogeneous-soc/start-ivshmem-server.sh",
                "ARM_RUN_SCRIPT": "scripts/heterogeneous-soc/run-arm-phase1.sh",
                "RISCV_RUN_SCRIPT": "scripts/heterogeneous-soc/run-riscv-phase3.sh",
            }
        )

        result = subprocess.run(
            ["bash", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

        log = self.tmux_log.read_text(encoding="utf-8")
        self.assertIn("limactl shell qemu-dev -- sh -lc", log)
        self.assertIn("BUILD_DIR=\\$HOME/chimera-build-linux-2", log)
        self.assertIn("VM_SOURCE_DIR=\\$HOME/chimera-src", log)
        self.assertIn("scripts/heterogeneous-soc/start-ivshmem-server.sh", log)
        self.assertIn("scripts/heterogeneous-soc/run-arm-phase1.sh", log)
        self.assertIn("scripts/heterogeneous-soc/run-riscv-phase3.sh", log)

    def test_lima_mode_stops_stale_demo_guests_before_launch(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "HOME": str(self.home_dir),
                "RUN_IN_LIMA": "1",
                "LIMA_NAME": "qemu-dev",
                "BUILD_DIR": str(self.home_dir / "chimera-build-linux-2"),
                "VM_SOURCE_DIR": str(self.home_dir / "chimera-src"),
                "SESSION_NAME": "heterogeneous-soc-test",
                "SERVER_SCRIPT": "scripts/heterogeneous-soc/start-ivshmem-server.sh",
                "ARM_RUN_SCRIPT": "scripts/heterogeneous-soc/run-arm-phase1.sh",
                "RISCV_RUN_SCRIPT": "scripts/heterogeneous-soc/run-riscv-phase3.sh",
            }
        )

        result = subprocess.run(
            ["bash", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

        log_lines = self.tmux_log.read_text(encoding="utf-8").splitlines()
        self.assertTrue(log_lines, "expected stub log entries")
        self.assertIn("scripts/heterogeneous-soc/stop-demo-guests.sh", log_lines[0])

    def test_auto_prepare_guests_runs_in_control_pane(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "HOME": str(self.home_dir),
                "RUN_IN_LIMA": "1",
                "LIMA_NAME": "qemu-dev",
                "BUILD_DIR": str(self.home_dir / "chimera-build-linux-2"),
                "VM_SOURCE_DIR": str(self.home_dir / "chimera-src"),
                "SESSION_NAME": "heterogeneous-soc-test",
                "SERVER_SCRIPT": "scripts/heterogeneous-soc/start-ivshmem-server.sh",
                "ARM_RUN_SCRIPT": "scripts/heterogeneous-soc/run-arm-phase1.sh",
                "RISCV_RUN_SCRIPT": "scripts/heterogeneous-soc/run-riscv-phase3.sh",
            }
        )

        result = subprocess.run(
            ["bash", str(SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

        log = self.tmux_log.read_text(encoding="utf-8")
        self.assertIn("scripts/heterogeneous-soc/demo-auto-prepare-guests.sh", log)


if __name__ == "__main__":
    unittest.main()
