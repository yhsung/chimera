# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Chimera is a fork of [QEMU](https://www.qemu.org/) that adds a custom
machine model (`chimera-r52-freertos-demo`, Cortex-R52) and an
`ivshmem-flat` sysbus device for bare-metal inter-VM shared memory without
PCI.

The heterogeneous SoC demo that uses this QEMU fork is maintained in
**[chimera-2](https://github.com/yhsung/chimera-2)** (Apache-2.0), which
consumes this repository as its `qemu/` git submodule.

## Building QEMU

```bash
./configure --target-list=aarch64-softmmu,arm-softmmu,riscv64-softmmu,mipsel-softmmu --enable-debug
ninja
```

Build output goes to the current directory. The chimera-2 scripts use
`BUILD_DIR` (default: `$HOME/chimera-build-linux` or `<chimera-2-root>/build-linux`).

## Naming: mipsel, not mips

The QEMU target for MIPS little-endian is `mipsel-softmmu`, producing `qemu-system-mipsel`. Build artifacts, binaries, and `pkill` patterns must use `mipsel` (not `mips`).

## Naming: r52 (FreeRTOS's CPU) vs. the RISCV-Linux channel

The bare-metal FreeRTOS guest runs on a Cortex-R52 (`qemu-system-arm`,
machine `chimera-r52-freertos-demo`, binary `freertos-r52-demo.elf`). The
disambiguating prefix for FreeRTOS's *own* architecture is **`r52`** (not
`arm`, which is the Cortex-A53 ARM-Linux guest).

## Wire Protocol (Critical Constraints)

These constraints bind both the firmware client (in chimera-2) and the
`ivshmem-flat` device (in this repo). Changes to either must respect both:

- All copies to/from ivshmem BAR2 use explicit volatile byte loops — `memcpy` and struct assignment are forbidden. ARM NEON instructions SIGBUS on non-cacheable PCI BAR2; GCC `-O2` LICM hoists non-volatile reads out of poll loops.
- `__sync_synchronize()` wraps every flag read/write (emits `fence iorw,iorw` on RISC-V, `dmb ish` on AArch64).

Full protocol details are in [chimera-2's README](https://github.com/yhsung/chimera-2#wire-protocol).

## FreeRTOS Exception Handlers (MMIO Mapping Obligation)

When adding new MMIO peripherals to the QEMU machine model, ensure addresses
are always mapped in `hw/arm/chimera_r52_freertos_demo.c`. The FreeRTOS
firmware's data-abort handler skips faulting instructions (`subs pc, lr, #4`)
— unmapped MMIO writes are silently dropped, not caught. Full handler
explanation: [chimera-2's CLAUDE.md](https://github.com/yhsung/chimera-2).

## Git Conventions

- Commit and push incrementally as each logical step completes — not all at once at the end.
- For commit/push tasks: stage, commit with a clear message, push, and (if a PR was opened) switch back to main after merge.
- Always add OS cruft like `.DS_Store` to `.gitignore` when creating or updating gitignore files.
