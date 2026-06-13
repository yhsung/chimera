# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Chimera is a QEMU-based demo of a heterogeneous SoC: ARM-Linux, RISCV-Linux, and MIPS-Linux guests each run a sysinfo logging daemon that sends periodic system snapshots (CPU load, free memory, uptime) to a bare-metal RISCV FreeRTOS firmware over three independent ivshmem (inter-VM shared memory) channels using a HELLO/ACK wire protocol. A fourth ivshmem stats channel carries periodic per-channel message-count snapshots from FreeRTOS to ARM-Linux, logged to `/var/log/chimera-log/chimera-cross-domain.log`. A CAN bus (`xlnx-zynqmp-can` on FreeRTOS, `kvaser_pci` on ARM-Linux, both bridged to Lima's `vcan0`) lets a host `cansend` reach both guests; FreeRTOS forwards received frames over IVSHMEM5 to an ARM-Linux daemon that logs them to `/var/log/chimera-log/can-bus.log`.

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

## Naming: r52 (FreeRTOS's CPU) vs. the RISCV-Linux channel

The bare-metal FreeRTOS guest runs on a Cortex-R52 (`qemu-system-arm`,
machine `chimera-r52-freertos-demo`, binary `freertos-r52-demo.elf`). The
disambiguating prefix for FreeRTOS's *own* architecture is **`r52`** (not
`arm`, which is the Cortex-A53 ARM-Linux guest). This is independent of the
**RISCV-Linux ↔ FreeRTOS channel**, whose names describe that Linux guest's
link and are deliberately left untouched: `IVSHMEM_RISCV_FREERTOS_*`,
`riscv_link`/`riscv_count`, `guest-start-ivshmem-server-riscv-freertos.sh`,
`syslog-riscv-linux`, `bootlog-riscv-linux`. Do not conflate the two: `r52`
names the CPU FreeRTOS runs on; `riscv` (in channel names) names the Linux
guest on the other end of one ivshmem link. The wire-protocol sender id for
FreeRTOS stays numeric `3` (`HSOC_SENDER_R52_FREERTOS`).

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

Two harness scripts provide automated pass/fail CI testing inside the Lima VM.  Both use a detached tmux session, capture FreeRTOS UART output via `tmux capture-pane`, and exit 0 on PASS / 1 on FAIL.

### `guest-run-freertos-harness.sh` (lightweight, ~30 s)

Launches the FreeRTOS firmware plus ivshmem servers (ARM, RISCV, MIPS, stats, bootlog) and three Linux guests.  Designed for fast iteration when only FreeRTOS or ivshmem code changes.

**Pass conditions** (both must be met):
1. **CHIMERA banner** — `██████╗██╗` appears in FreeRTOS UART (proves `shell_init()` ran)
2. **Hello handshake** — `received hello from arm-linux` appears (proves IVSHMEM link works)

The harness also tracks (non-fatal) whether `[freertos] stats snapshot written` and `[bootlog]` lines appear, reported in the PASS/FAIL summary.

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-harness.sh
```

**Environment overrides:**
| Variable | Default | Use |
|---|---|---|
| `HARNESS_TIMEOUT` | 300 | seconds to wait for pass conditions |
| `HARNESS_LOG_DIR` | `/tmp/harness-logs` | directory for log files |
| `SKIP_BUILD` | (unset) | skip `guest-build-freertos-showcase.sh` if non-empty |

### `guest-run-debian-harness.sh` (full-stack, ~10 min)

Stage 1 installs prerequisites; Stage 2 fetches Debian kernel .debs, creates qcow2 rootfs disks, extracts kernels, builds FreeRTOS, boots all guests, and verifies FreeRTOS receives hello messages from **all three** Linux senders.

**Pass condition:** FreeRTOS UART contains `received hello from arm-linux`, `… riscv-linux`, and `… mips-linux`.

**Environment overrides:**  `HARNESS_TIMEOUT` (default 600), `SKIP_PREREQS`, `SKIP_ROOTFS`, `SKIP_FETCH`, `SKIP_BUILD`.

### `guest-run-freertos-shell-harness.sh` (lightweight, ~10 s)

Launches FreeRTOS QEMU with all mandatory ivshmem servers (no Linux
guests) and verifies the firmware boots, UART works, and the shell
initialises by monitoring the autonomous serial output.

**Pass conditions** (all must be met):
1. **CHIMERA banner** — `██████╗██╗` appears (proves `shell_init()` ran)
2. **Shell prompt** — `chimera>` appears (proves shell task is running)
3. **Showcase task** — `showcase task started` appears (proves main loop runs)
4. **CAN init** — `CAN controller enabled` appears (proves CAN driver init)

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-shell-harness.sh
```

**Environment overrides:** `SHELL_HARNESS_TIMEOUT` (default 60).

### `guest-run-can-e2e-harness.sh` (full-stack, ~1 min)

End-to-end CAN verification: launches FreeRTOS + ARM Linux (2-pane tmux,
all 6 ivshmem servers backgrounded) with CAN passthrough, sends a CAN
frame from Lima's `vcan0`, and verifies:
1. FreeRTOS decodes the frame (`CAN RX:` in FreeRTOS UART)
2. ARM `can-log-arm-linux` daemon logs `CAN/freertos` in
   `/var/log/chimera-log/can-bus.log` (proves IVSHMEM5 forwarding)
3. ARM daemon logs `CAN/socketcan` in the same file (proves the
   `kvaser_pci` → `can0` path)

Conditions 2 and 3 are checked by `tail -F`-ing `can-bus.log` into the
ARM pane (no SSH/netdev — `can-log-arm-linux` writes those lines only to
the log file, never to stdout) and grepping the captured pane.

Requires all showcase build artifacts (FreeRTOS ELF, ARM kernel/initrd,
ARM Debian qcow2, `can-log-arm-linux`). Exit 0 only when all three
conditions are met.

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh
```

**Environment overrides:** `CAN_E2E_TIMEOUT` (default 180), `CAN_TEST_ID` (default `123`), `CAN_TEST_DATA` (default `DEADBEEF`).

### `guest-run-riscv-hello-harness.sh` (full-stack, ~1-2 min)

End-to-end RISCV-Linux ↔ FreeRTOS HELLO/ACK verification over IVSHMEM1:
launches FreeRTOS (3 mandatory ivshmem channels: ARM/RISCV/MIPS) and a
RISC-V Linux guest running `syslog-riscv-linux` with
`SYSLOG_INTERVAL_SEC=1` for fast round trips. Verifies:
1. FreeRTOS boots and the IVSHMEM1 IRQ path is initialised
   (`showcase task started`)
2. RISCV-Linux completes >=5 HELLO/ACK round trips
   (`[riscv-linux] ACK`)

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh
```

**Environment overrides:** `RISCV_HELLO_TIMEOUT` (default 240).

### `guest-run-stats-e2e-harness.sh` (full-stack, ~1-2 min)

End-to-end ARM-side consumption of the stats snapshot channel (IVSHMEM3):
launches FreeRTOS (3 mandatory ivshmem channels + stats) and an ARM Linux
guest running `linux-arm-stats`. Verifies:
1. FreeRTOS publishes the stats magic (`showcase task started`)
2. `linux-arm-stats` finds the BAR2 via sysfs (`[stats] logging to ...`)
3. A generation change is logged (`[stats] gen=<N> logged`, N>=1)
4. `chimera-cross-domain.log` gets a correctly-formatted snapshot line
   (`gen=<N> arm=...`)

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh
```

**Environment overrides:** `STATS_E2E_TIMEOUT` (default 240).

### `guest-run-shell-e2e-harness.sh` (lightweight, ~15 s)

FreeRTOS-only interactive shell test: launches FreeRTOS with the 3
mandatory ivshmem channels plus the CAN ivshmem channel (`canft`, no
`canbus` object — makes `can status`'s `rx_frames` deterministic), then
drives all 6 shell commands (`help`, `stats`, `sysinfo`, `links`,
`loglevel`, `can status`) plus one unrecognized command over real UART RX
via `tmux send-keys`, checking each command's output against
`README.md`'s "Interactive Shell" table.

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

**Environment overrides:** `SHELL_E2E_TIMEOUT` (default 60).

### Harness implementation notes

- **`remain-on-exit on`** must be set on the tmux session.  Without it, a QEMU crash destroys its pane and tmux renumbers the remaining panes, breaking all `send-keys -t 0.N` targets.
- **Five ivshmem servers** are required: ARM, RISCV, MIPS, stats, and bootlog.  `guest-run-r52-freertos-phase5.sh` expects the bootlog socket to exist.  The data-channel servers run inside tmux panes; stats and bootlog run as background processes.
- **Socket directories** must be created with `mkdir -p` before launching ivshmem-server directly (the wrapper scripts handle this, but the harnesses invoke the binary).

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
- **`tmux set-option remain-on-exit on`** — always set this in harness scripts. When a QEMU process exits inside a tmux pane, tmux destroys the pane and renumbers all subsequent panes, silently breaking every `send-keys -t 0.N` target.  `remain-on-exit on` keeps the pane (marked "dead") so indices stay stable.
- **`pkill` without `-f`** — use `pkill ivshmem-server` (matches 15-char process name) rather than `pkill -f <long-regex>`.  The `-f` flag matches the full command line including the invoking shell's own `-c '...'` string, potentially killing the SSH/limactl session itself (exit 255).

## Deploy Path: Worktree → macOS → Lima-local

`host-install-lima-host.sh` deploys the worktree to `/Users/yhsung/chimera-src` on macOS.  Inside the Lima VM, `$HOME` resolves to `/home/yhsung.guest` and `~` expansion from the **local** shell (macOS) resolves to `/Users/yhsung`.  This creates two different source trees:

| Path | Populated by | Used by |
|---|---|---|
| `/Users/yhsung/chimera-src` | `host-install-lima-host.sh` | reference / diff |
| `/home/yhsung.guest/chimera-src` | manual deploy or `cp` from `/Users/…` | `guest-build-freertos-showcase.sh` |

**After editing source in the worktree, you must deploy to the Lima-local path:**
```bash
# Option A: Run host-install, then copy inside Lima
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- cp /Users/yhsung/chimera-src/path/to/file $HOME/chimera-src/path/to/file

# Option B: Transfer directly via base64 (avoids quoting issues)
base64 -i <worktree-file> | limactl shell qemu-dev -- bash -c 'base64 -d > /home/yhsung.guest/chimera-src/path/to/file'
```

## FreeRTOS Exception Handlers

`contrib/heterogeneous-soc/freertos-showcase/startup.S` defines the ARM exception vector table.  The handlers for Undefined, Prefetch Abort, and Data Abort were originally `b .` (branch-to-self → infinite loop at 100 % CPU).

This caused a **silent hang** whenever the firmware accessed unmapped MMIO regions — specifically the CAN controller (`0x50000000`) and IVSHMEM5 SHMEM (`0x4A000000`) when those QEMU devices are not instantiated (no `canbus` / no CAN ivshmem chardev on the QEMU command line).  The `can_init()` write to `can_ivshmem->magic` triggered a synchronous external abort, and the handler looped forever.

**Current handlers skip the faulting instruction and continue:**
```asm
undef_handler:  subs pc, lr, #0   /* return to faulting insn (will re-fault) */
pabt_handler:   subs pc, lr, #4   /* skip faulting insn, continue */
dabt_handler:   subs pc, lr, #4   /* skip faulting insn, continue */
```

`subs pc, lr, #N` subtracts N from the ABT-mode link register (faulting-insn + 8) and copies SPSR_abt to CPSR, returning to the instruction after the fault.  This means:
- Writes to unmapped CAN / IVSHMEM5 regions are silently dropped
- `can_init()` completes harmlessly whether CAN hardware is present or not
- The firmware always boots to the shell and prints the CHIMERA banner

**When adding new MMIO peripherals**, ensure addresses are always mapped in the QEMU machine model (`hw/arm/chimera_r52_freertos_demo.c`) OR verify the data-abort handler tolerates faults on those regions.

## Direct Lima Access (for debugging)

**Always use `limactl shell qemu-dev` to run commands directly** — do not ask the user to copy/paste diagnostics. The Lima VM is the control plane for everything: building, launching QEMU guests, and accessing guest serial consoles.

### Running commands in Lima
```bash
limactl shell qemu-dev -- <command>
```

### Accessing guest tmux panes
```bash
# Capture a tmux pane (pane numbering: 0.0–0.5 = top 5 ivshmem servers + FreeRTOS, 0.6 = ARM, 0.7 = RISCV, 0.8 = MIPS)
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.6 | tail -50

# Send a command to a running guest pane
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.6 "ls /var/log/chimera-log/boot-log/" Enter
```

### Accessing guest serial consoles (via chimera-ssh)
```bash
# SSH into ARM guest (port 2222), RISCV (2223), MIPS (2224)
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost '<command>'
```

### Getting boot logs from ARM guest
```bash
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'ls -la /var/log/chimera-log/boot-log/'
```

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
| `IVSHMEM_BOOTLOG_DIR` | `/tmp/ivshmem-bootlog` | Boot-log channel socket dir |
| `IVSHMEM_CAN_FREERTOS_DIR` | `/tmp/ivshmem-can-freertos` | CAN forwarding channel socket dir |
| `ASSET_DIR` | `$HOME/iso` | Debian ISOs and disk images |
| `LIMA_NAME` | `qemu-dev` | Lima VM name |
