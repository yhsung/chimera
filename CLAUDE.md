# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Chimera is a QEMU-based demo of a heterogeneous SoC: ARM-Linux, RISCV-Linux, and MIPS-Linux guests each run a sysinfo logging daemon that sends periodic system snapshots (CPU load, free memory, uptime) to a bare-metal RISCV FreeRTOS firmware over three independent ivshmem (inter-VM shared memory) channels using a HELLO/ACK wire protocol. A fourth ivshmem stats channel carries periodic per-channel message-count snapshots from FreeRTOS to ARM-Linux, logged to `/tmp/freertos-stats.log`.

## Chimera-Specific Code

All custom code lives in a small surface area on top of upstream QEMU:

| File | Purpose |
|---|---|
| `hw/riscv/chimera_freertos_demo.c` | Custom `chimera-riscv-freertos-demo` QEMU machine: one RV64 hart, CLINT, PLIC, UART, four `ivshmem-flat` devices (3 HELLO/ACK + 1 stats) |
| `include/hw/riscv/chimera_freertos_demo.h` | Machine state, memory map enum, IRQ numbers |
| `hw/misc/ivshmem-flat.c` | `ivshmem-flat` sysbus device — memory-mapped ivshmem without PCI, connects to ivshmem-server via Unix socket |
| `include/hw/misc/ivshmem-flat.h` | Device state and interface |
| `contrib/heterogeneous-soc/freertos-showcase/` | FreeRTOS ELF and Linux syslog daemon binaries (wire protocol, build system) |
| `scripts/heterogeneous-soc/` | All launch, build, and setup scripts |

The `ivshmem-flat` device is a sysbus alternative to the PCI `ivshmem-doorbell`; FreeRTOS uses it because bare-metal targets lack a PCI bus. Linux guests use the standard PCI `ivshmem-doorbell`.

`CONFIG_CHIMERA_FREERTOS_DEMO` (`hw/riscv/Kconfig`) selects `CONFIG_IVSHMEM_FLAT_DEVICE` (`hw/misc/Kconfig`) automatically. Both are `default y` for their respective targets.

## Architecture

See `README.md` → **Architecture** for the full component table, ivshmem channel map (MMIO/SHMEM addresses), and device type breakdown.

## Quick Start (two commands)

**Step 1 — Deploy source and create Lima VM** (run on macOS host; re-run after every pull):

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
```

**Step 2 — Launch the full showcase** (from macOS host; re-run any time):

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

`guest-run-chimera-showcase.sh` handles all prerequisites, builds, and opens the 8-pane tmux session.

---

## Building QEMU

QEMU must be built inside the Lima VM (`qemu-dev`) because `ivshmem-server` requires Linux `eventfd`. Cross-compilation toolchains are also only available there.

```bash
# One-time: create Lima VM and install deps (runs apt-get inside the VM)
scripts/heterogeneous-soc/guest-install-lima-guest.sh

# Build QEMU + ivshmem-server (runs inside Lima)
BUILD_DIR=$HOME/chimera-build-linux VM_SOURCE_DIR=$HOME/chimera-src \
    scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh
```

Internally this runs:
```bash
./configure --target-list=aarch64-softmmu,riscv64-softmmu,mipsel-softmmu --enable-debug
ninja contrib/ivshmem-server/ivshmem-server contrib/ivshmem-client/ivshmem-client
```

`BUILD_DIR` defaults to `<repo>/build-linux` when the repo is under `/Users/` and writable, otherwise `$HOME/chimera-build-linux`. `common.sh` has the exact logic.

## Building the FreeRTOS Showcase Binaries

Cross-compilers (`aarch64-linux-gnu-gcc`, `riscv64-linux-gnu-gcc`, `mipsel-linux-gnu-gcc`, `riscv64-unknown-elf-gcc`) are **only available inside the Lima VM** — they are not present on macOS. Always build freertos-showcase binaries via Lima.

**From macOS** (recommended — rsyncs source then builds):
```bash
CHIMERA_ROOT=/Users/yhsung/dev-projects/chimera \
    limactl shell qemu-dev -- bash /Users/yhsung/dev-projects/chimera/scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
```

**From inside Lima** (after `limactl shell qemu-dev`):
```bash
CHIMERA_ROOT=/Users/yhsung/dev-projects/chimera \
    bash ~/chimera-src/scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
```

Both commands rsync the current macOS source tree into `~/chimera-src` inside Lima before building, so they always pick up uncommitted or branch-local changes.

Outputs (in `~/chimera-src/contrib/heterogeneous-soc/freertos-showcase/` inside Lima): `syslog-arm-linux`, `syslog-riscv-linux`, `syslog-mips-linux`, `linux-arm-stats`, `freertos-riscv-demo.elf`.

The Makefile skips `syslog-*-linux` targets silently if the corresponding compiler is absent. `FREERTOS_KERNEL_DIR` defaults to `$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel`.

`FREERTOS_KERNEL_DIR` defaults to `$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel`.

## Running the Demo

```bash
scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
```

On first run (no ELF present): does one-time Lima setup, disk image fetch, and ivshmem-server build. On every run: rebuilds FreeRTOS/Linux binaries, then opens a tmux session with eight panes (4 ivshmem-servers, 1 FreeRTOS, 1 ARM-Linux, 1 RISCV-Linux, 1 MIPS-Linux). Navigate with **Ctrl-b + arrow keys**.

To launch components individually:
```bash
scripts/heterogeneous-soc/guest-start-ivshmem-server-arm-freertos.sh   # ARM channel
scripts/heterogeneous-soc/guest-start-ivshmem-server-riscv-freertos.sh # RISCV channel
scripts/heterogeneous-soc/guest-start-ivshmem-server-mips-freertos.sh  # MIPS channel
scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh          # Stats channel
scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh           # FreeRTOS QEMU
scripts/heterogeneous-soc/guest-run-arm-phase5.sh                      # ARM-Linux QEMU
scripts/heterogeneous-soc/guest-run-riscv-phase5.sh                    # RISCV-Linux QEMU
scripts/heterogeneous-soc/guest-run-chimera.sh                         # MIPS-Linux QEMU
```

The FreeRTOS machine requires all four ivshmem servers to be listening before it starts (the tmux script polls for the Unix sockets).

**QEMU staleness enforcement:** Both `guest-run-chimera-showcase.sh` and
`guest-run-phase5-tmux.sh` probe the built `qemu-system-riscv64` for expected
machine properties (via `-M chimera-riscv-freertos-demo,help`) before
declaring the build current. A stale binary built from an older commit will
trigger a rebuild instead of failing at runtime with "Property not found".
When adding new machine properties, no special action is needed — just add
the property in C and reference it in the launch scripts; the probe will
naturally detect staleness.

## Naming: mipsel, not mips

The QEMU target for MIPS little-endian is `mipsel-softmmu`, producing `qemu-system-mipsel`. Build artifacts, binaries, and `pkill` patterns must use `mipsel` (not `mips`) throughout — the Debian Bookworm distro is also `mipsel`.

## Debugging Sessions

Before context runs low, write `DEBUG_STATE.md` summarizing: root causes found, fixes applied, what's still unverified, and the exact next command to run to resume.

## QEMU/FreeRTOS Workflow

- After any QEMU restart, kill orphan processes and remove stale sockets before re-running: `pkill qemu-system; rm -f /tmp/*.sock`.
- When debugging ivshmem/shared-memory comms, verify shmem name uniqueness and MMIO register initialization before assuming a code logic bug.

### Autonomous Debug Loop

When asked to debug the FreeRTOS ivshmem demo autonomously, build a harness script that:
1. Kills orphan QEMU processes and removes stale socket files before each run.
2. Launches the SoC showcase and captures serial output.
3. Returns pass/fail based on whether FreeRTOS prints the received shared-memory hello message.

Then iterate: run the harness → diagnose root cause from logs → apply a fix → re-run. Continue until the demo passes 3 consecutive times. Report each iteration's hypothesis and result.

## Wire Protocol

See `README.md` → **Wire Protocol** for the full message layout, shared memory layout, handshake sequence diagram, and stats snapshot protocol.

**Critical implementation constraints (must not deviate):**
- All copies to/from ivshmem BAR2 use explicit volatile byte loops — `memcpy` and struct assignment are forbidden. ARM NEON instructions SIGBUS on non-cacheable PCI BAR2; GCC `-O2` LICM hoists non-volatile reads out of poll loops.
- `__sync_synchronize()` wraps every flag read/write (emits `fence iorw,iorw` on RISC-V, `dmb ish` on AArch64).

## Guest Networking & Avahi

See `README.md` → **Guest Networking & Avahi Discovery** for the full bridge/TAP layout, IP assignments, Avahi service browsing commands, SSH ProxyJump config, and instructions for rebuilding stale disk images that predate Avahi support.

## CI / Headless Testing

See `README.md` → **CI / Headless Testing** for the two harness scripts (`guest-run-debian-harness.sh`, `guest-run-freertos-harness.sh`), their pass conditions, timeouts, and environment overrides.

## Git Conventions

- Commit and push incrementally as each logical step completes — not all at once at the end.
- For commit/push tasks: stage, commit with a clear message, push, and (if a PR was opened) switch back to main after merge.
- Always add OS cruft like `.DS_Store` to `.gitignore` when creating or updating gitignore files.

## Git Worktree Usage for Multi-Agent Work

When the master agent is working inside a git worktree (isolated branch), **all spawned subagents must operate in the same worktree**. This rule is non-negotiable:

- Before spawning any subagent, determine the current worktree path (`git worktree list`).
- Pass the worktree path explicitly in the subagent prompt so it changes into that directory first.
- Subagents must never commit to `master` or any branch other than the worktree's checked-out branch.
- After each subagent completes, verify that commits landed on the correct branch (`git log --oneline -1 --decorate` in the worktree), not on `master`.
- If a subagent accidentally commits to `master`, do not silently proceed — surface it immediately and reset.

## Shell Scripting

- Target tmux 3.4+: use `-l N%` for pane sizing (the `-p N` flag was removed), handle pane renumbering explicitly after splits, and account for read-only mounted paths.

## Key Environment Variables

All scripts inherit defaults from `scripts/heterogeneous-soc/common.sh`. Commonly overridden:

| Variable | Default | Use |
|---|---|---|
| `BUILD_DIR` | `<repo>/build-linux` or `$HOME/chimera-build-linux` | QEMU build output |
| `FREERTOS_KERNEL_DIR` | `$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel` | FreeRTOS source |
| `IVSHMEM_ARM_FREERTOS_DIR` | `/tmp/ivshmem-arm-freertos` | ARM channel socket dir |
| `IVSHMEM_RISCV_FREERTOS_DIR` | `/tmp/ivshmem-riscv-freertos` | RISCV channel socket dir |
| `IVSHMEM_MIPS_FREERTOS_DIR` | `/tmp/ivshmem-mips-freertos` | MIPS channel socket dir |
| `IVSHMEM_STATS_FREERTOS_DIR` | `/tmp/ivshmem-stats-freertos` | Stats channel socket dir |
| `ASSET_DIR` | `$HOME/iso` | Debian ISOs and disk images |
| `LIMA_NAME` | `qemu-dev` | Lima VM name |
