# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

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
./configure --target-list=aarch64-softmmu,arm-softmmu,mipsel-softmmu --enable-debug
ninja
```

## Naming: mipsel, not mips

The QEMU target for MIPS little-endian is `mipsel-softmmu`, producing `qemu-system-mipsel`. Build artifacts, binaries, and `pkill` patterns must use `mipsel` (not `mips`).

## Wire Protocol (Critical Constraints)

These constraints bind both the firmware client (in chimera-2) and the
`ivshmem-flat` device (in this repo):

- All copies to/from ivshmem BAR2 use explicit volatile byte loops — `memcpy` and struct assignment are forbidden.
- `__sync_synchronize()` wraps every flag read/write (emits `fence iorw,iorw` on RISC-V, `dmb ish` on AArch64).

## Git Conventions

- Commit and push incrementally as each logical step completes — not all at once at the end.
- For commit/push tasks: stage, commit with a clear message, push, and (if a PR was opened) switch back to main after merge.
- Always add OS cruft like `.DS_Store` to `.gitignore` when creating or updating gitignore files.
