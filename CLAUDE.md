# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Chimera is a QEMU-based demo of a heterogeneous SoC: ARM-Linux, RISCV-Linux, and MIPS-Linux guests each run a sysinfo logging daemon that sends periodic system snapshots (CPU load, free memory, uptime) to a bare-metal RISCV FreeRTOS firmware over three independent ivshmem (inter-VM shared memory) channels using a HELLO/ACK wire protocol. A fourth ivshmem stats channel carries periodic per-channel message-count snapshots from FreeRTOS to ARM-Linux, logged to `/tmp/freertos-stats.log`.

## Chimera-Specific Code

See `README.md` → **Chimera-Specific Code** for the full file/purpose table, ivshmem-flat vs ivshmem-doorbell explanation, and Kconfig relationships.

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

See `README.md` → **Building QEMU** for build commands, configure flags, and `BUILD_DIR` logic.

## Building the FreeRTOS Showcase Binaries

See `README.md` → **Building the FreeRTOS Showcase Binaries** for cross-compiler requirements, build commands, and expected outputs.

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
