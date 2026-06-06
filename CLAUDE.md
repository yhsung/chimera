# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Chimera is a QEMU fork that implements a heterogeneous SoC demo: ARM-Linux and RISCV-Linux guests exchange timestamped HELLO/ACK messages with a bare-metal RISCV FreeRTOS firmware over two independent ivshmem (inter-VM shared memory) channels.

## Chimera-Specific Code

All custom code lives in a small surface area on top of upstream QEMU:

| File | Purpose |
|---|---|
| `hw/riscv/chimera_freertos_demo.c` | Custom `chimera-riscv-freertos-demo` QEMU machine: one RV64 hart, CLINT, PLIC, UART, two `ivshmem-flat` devices |
| `include/hw/riscv/chimera_freertos_demo.h` | Machine state, memory map enum, IRQ numbers |
| `hw/misc/ivshmem-flat.c` | `ivshmem-flat` sysbus device — memory-mapped ivshmem without PCI, connects to ivshmem-server via Unix socket |
| `include/hw/misc/ivshmem-flat.h` | Device state and interface |
| `contrib/heterogeneous-soc/freertos-showcase/` | FreeRTOS ELF and Linux hello binaries (wire protocol, build system) |
| `scripts/heterogeneous-soc/` | All launch, build, and setup scripts |

The `ivshmem-flat` device is a sysbus alternative to the PCI `ivshmem-doorbell`; FreeRTOS uses it because bare-metal targets lack a PCI bus. Linux guests use the standard PCI `ivshmem-doorbell`.

`CONFIG_CHIMERA_FREERTOS_DEMO` (`hw/riscv/Kconfig`) selects `CONFIG_IVSHMEM_FLAT_DEVICE` (`hw/misc/Kconfig`) automatically. Both are `default y` for their respective targets.

## Quick Start (two commands)

**Step 1 — Deploy source and create Lima VM** (run on macOS host; re-run after every pull):

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
```

**Step 2 — Launch the full showcase** (inside Lima):

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

```bash
# Fetch FreeRTOS-Kernel source (needed once)
scripts/heterogeneous-soc/guest-fetch-freertos-kernel.sh

# Build all three binaries inside Lima (or natively on Linux with the right cross-compilers)
make -C contrib/heterogeneous-soc/freertos-showcase/ clean all
```

Outputs: `hello-arm-linux`, `hello-riscv-linux`, `hello-mips-linux`, `freertos-riscv-demo.elf`.

Cross-compilers required: `aarch64-linux-gnu-gcc`, `riscv64-linux-gnu-gcc`, `riscv64-unknown-elf-gcc`, `gcc-mipsel-linux-gnu`. The Makefile skips `hello-*-linux` targets silently if the corresponding compiler is absent.

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

Defined in `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h`. Each channel occupies two 4 KiB slots in shared memory (`struct hsoc_layout`): one slot for Linux→FreeRTOS, one for FreeRTOS→Linux. Each slot has a `volatile uint32_t flag` (0=empty, 1=ready) followed by a 96-byte `hsoc_hello_msg`.

**Critical implementation constraints:**
- All copies to/from ivshmem BAR2 use explicit volatile byte loops — `memcpy` and struct assignment are forbidden. ARM NEON instructions SIGBUS on non-cacheable PCI BAR2; GCC `-O2` LICM hoists non-volatile reads out of poll loops.
- `__sync_synchronize()` wraps every flag read/write (emits `fence iorw,iorw` on RISC-V, `dmb ish` on AArch64).

## Git Conventions

- Commit and push incrementally as each logical step completes — not all at once at the end.
- For commit/push tasks: stage, commit with a clear message, push, and (if a PR was opened) switch back to main after merge.
- Always add OS cruft like `.DS_Store` to `.gitignore` when creating or updating gitignore files.

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
| `ASSET_DIR` | `$HOME/iso` | Alpine ISOs and disk images |
| `LIMA_NAME` | `qemu-dev` | Lima VM name |
