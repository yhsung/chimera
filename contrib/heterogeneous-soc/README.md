# Heterogeneous SoC — Guest-Side Payloads

This directory contains the **guest-side payloads** for the Chimera heterogeneous SoC demo. The payloads run inside QEMU VMs (ARM-Linux, RISC-V-Linux, MIPS-Linux, and bare-metal RISC-V FreeRTOS) and communicate over ivshmem (inter-VM shared memory) channels.

The directory has two layers:

1. **Original ping/pong demo** (top-level) — ARM ↔ RISC-V ivshmem round-trip.
2. **freertos-showcase** (subdirectory) — Three Linux guests sending sysinfo HELLO messages to a bare-metal RISC-V FreeRTOS firmware, with boot-log collection and per-channel stats.

---

## File Overview

### Top-Level — Ping/Pong Demo

| File | Purpose |
|---|---|
| `ivshmem_proto.h` | Shared-memory protocol layout for one bidirectional channel (ARM→RISC-V and RISC-V→ARM) |
| `ping.c` | ARM-Linux sender: sends `PING` messages with wall-clock timestamps, waits for `PONG` reply, measures RTT |
| `pong.c` | RISC-V-Linux responder: polls for `PING`, echoes timestamps back as `PONG` |
| `ping.sh` | Shell wrapper that launches `ping` with BAR2 path discovery |
| `pong.sh` | Shell wrapper that launches `pong` with BAR2 path discovery |
| `Makefile` | Cross-compiles `ping` (`aarch64-linux-gnu-gcc`) and `pong` (`riscv64-linux-gnu-gcc`) as static binaries |

### freertos-showcase — Multi-Guest Showcase

#### Protocol Headers

| File | Purpose |
|---|---|
| `hello_proto.h` | HELLO/ACK protocol between Linux guests and FreeRTOS. Defines `hsoc_hello_msg`, `hsoc_channel`, `hsoc_layout`, sender IDs (`HSOC_SENDER_ARM_LINUX`, `_RISCV_LINUX`, `_MIPS_LINUX`, `_RISCV_FREERTOS`), message types (`HELLO`, `ACK`), and the 64-byte text payload |
| `stats_proto.h` | Stats snapshot protocol (FreeRTOS → ARM-Linux over IVSHMEM3). Defines `hsoc_stats_snapshot` with per-channel HELLO counters and FreeRTOS tick time. Written exclusively by FreeRTOS; polled by `linux-arm-stats` and logged to `/tmp/freertos-stats.log` |
| `bootlog_proto.h` | Boot-log collection protocol (all guests → ARM boot-collector over IVSHMEM4). Defines `hsoc_bootlog_header` with 4 × 1 MiB per-guest slots, guest status tracking, and a doorbell mechanism via `collector_peer_id` |

#### FreeRTOS Firmware (bare-metal RISC-V)

| File | Purpose |
|---|---|
| `freertos_main.c` | **Main firmware entry.** Creates the `showcase` task which: initializes 4 ivshmem links (ARM, RISC-V, MIPS, boot-log), polls each for HELLO messages, sends ACKs, maintains per-channel counters, writes periodic stats snapshots, and runs the boot-log monitor. Also implements `log_uart()` (UART-0 output + boot-log capture) and `vApplicationMallocFailedHook`/`vApplicationStackOverflowHook` |
| `freertos_ivshmem_flat.h` | ivshmem flat BAR2 driver header. Defines MMIO register offsets (`INTMASK`, `INTSTATUS`, `IVPOSITION`, `DOORBELL`) and `freertos_ivshmem_link` struct |
| `freertos_ivshmem_flat.c` | ivshmem flat BAR2 driver implementation. Uses explicit volatile byte loops (`shmem_read`/`shmem_write`) to prevent GCC LICM from hoisting shared-memory reads out of poll loops. Implements `init`, `poll_hello` (flag + magic/version/type validation), and `send_ack` |
| `boot_log.h` | FreeRTOS boot-log monitor interface |
| `boot_log.c` | FreeRTOS boot-log writer: initializes the BAR2 header with `BOOTLOG_MAGIC`, writes `log_uart()` output into the FreeRTOS slot, tracks all 4 guest boot statuses, and rings the doorbell via MMIO when all guests have booted (or a 600 s timeout elapses) |
| `FreeRTOSConfig.h` | FreeRTOS kernel configuration: 10 MHz CPU clock, 1 kHz tick rate, 64 KiB heap, stack overflow checking, MLSP timer addresses |
| `startup.S` | RISC-V assembly startup: sets stack pointer (`_stack_top`), installs `freertos_risc_v_trap_handler` into `mtvec`, clears BSS, calls `main` |
| `linker.ld` | Linker script: RAM at `0x80000000` (8 MiB), text/data/bss sections, `--gc-sections` compatible |
| `freertos_libc.c` | Minimal freestanding libc: `memcpy`, `memmove`, `memset`, `memcmp`, `strcpy`, `strlen` |
| `stdlib.h` | Freestanding `<stdlib.h>` subset (`EXIT_SUCCESS`, `EXIT_FAILURE`) |
| `string.h` | Freestanding `<string.h>` declarations |

#### Linux Guest Binaries (cross-compiled)

| File | Purpose |
|---|---|
| `linux_syslog.c` | **Sysinfo sender.** Compiled three times via `-D` flags to produce `syslog-arm-linux`, `syslog-riscv-linux`, `syslog-mips-linux`. Each reads `/proc/loadavg`, `/proc/meminfo`, and `/proc/uptime`, packs them into a `hsoc_hello_msg` with `SYSINFO #N ld=... mf=...M up=...s` text, sends it to FreeRTOS, waits for ACK, logs the round trip. Sleeps `$SYSLOG_INTERVAL_SEC` (default 5 s) between iterations |
| `linux_stats.c` | **Stats reader.** Produces `linux-arm-stats`. Scans ivshmem BAR2 devices for `HSOC_STATS_MAGIC`, polls `generation` field, logs `[timestamp] gen=N arm=M riscv=M mips=M tick=S.NS` to `/tmp/freertos-stats.log` |
| `bootlog_writer.c` | **Boot-log sender.** Compiled three times for `bootlog-arm-linux`, `bootlog-riscv-linux`, `bootlog-mips-linux`. Scans BAR2 for `BOOTLOG_MAGIC`, writes a boot header timestamp, marks guest status as `HSOC_BOOT_COMPLETE`, then drains `/dev/kmsg` in a polling loop |
| `boot_collector.c` | **Boot-log collector.** Produces `boot-collector`. Runs on ARM-Linux; monitors `generation` in the boot-log BAR2, writes each guest's slot to `/var/log/boot-logs/<guest>.log` when a new generation is signaled. Uses volatile byte loops for all shared-memory reads |

#### Build & Test Infrastructure

| File | Purpose |
|---|---|
| `Makefile` | Top-level Makefile for the showcase. Conditionally builds targets based on available cross-compilers. Produces all Linux binaries + `freertos-riscv-demo.elf` |
| `test-syslog-format.sh` | Validates that `syslog-arm-linux` produces the expected `SYSINFO #N ld=... mf=...M up=...s` format |
| `.gitignore` | Ignores built binaries (`*.elf`, `syslog-*-linux`, `linux-arm-stats`) |

---

## Architecture

### ivshmem Channel Map

| Channel | Name | QEMU Device | Shared Memory | MMIO | Writer | Reader | Protocol |
|---|---|---|---|---|---|---|---|
| 0 | ARM↔FreeRTOS | `ivshmem-flat` | `0x31000000` | `0x30000000` | ARM-Linux `syslog-arm-linux` | RISC-V FreeRTOS | `hello_proto.h` |
| 1 | RISC-V↔FreeRTOS | `ivshmem-flat` | `0x36000000` | `0x35000000` | RISC-V-Linux `syslog-riscv-linux` | RISC-V FreeRTOS | `hello_proto.h` |
| 2 | MIPS↔FreeRTOS | `ivshmem-flat` | `0x3B000000` | `0x3A000000` | MIPS-Linux `syslog-mips-linux` | RISC-V FreeRTOS | `hello_proto.h` |
| 3 | Stats (FreeRTOS→ARM) | `ivshmem-flat` | `0x40000000` | `0x3F000000` | RISC-V FreeRTOS | ARM-Linux `linux-arm-stats` | `stats_proto.h` |
| 4 | Boot-log (all guests) | `ivshmem-flat` | `0x45000000` | `0x44000000` | All Linux guests + FreeRTOS | ARM-Linux `boot-collector` | `bootlog_proto.h` |

### Device Types

All five ivshmem channels use **ivshmem-flat** (not ivshmem-doorbell). The flat variant exposes a directly-accessible shared memory BAR (BAR2) with a polling-based flag protocol — no MSI-X interrupts are needed. Doorbell registers at MMIO offset `0x0c` are available but used only by the boot-log channel for the one-shot collector notification.

### Wire Protocol

All channels follow the same handshake pattern:

```
Linux Guest                          FreeRTOS
     │                                  │
     │   ┌─────────────────────────┐    │
     │   │ 1. Write msg fields via  │    │
     │   │    volatile byte stores  │    │
     │   ├─────────────────────────┤    │
     │   │ 2. __sync_synchronize() │    │
     │   ├─────────────────────────┤    │
     │   │ 3. Set flag = 1         │    │
     │   └──────────┬──────────────┘    │
     │              │                   │
     │              │  flag == 1        │
     │              ├──────────────────►│
     │              │                   │
     │              │    ┌──────────────────────────┐
     │              │    │ 4. Read msg via volatile │
     │              │    │    byte loop             │
     │              │    ├──────────────────────────┤
     │              │    │ 5. Validate magic/       │
     │              │    │    version/type          │
     │              │    ├──────────────────────────┤
     │              │    │ 6. Set flag = 0          │
     │              │    └──────────────────────────┘
     │              │                   │
     │              │    ┌──────────────────────────┐
     │              │    │ 7. Write ACK msg via     │
     │              │    │    volatile byte stores  │
     │              │    ├──────────────────────────┤
     │              │    │ 8. __sync_synchronize()  │
     │              │    ├──────────────────────────┤
     │              │    │ 9. Set flag = 1          │
     │              │    └──────────┬───────────────┘
     │              │                   │
     │              │  flag == 1        │
     │◄─────────────├───────────────────┤
     │              │                   │
     │   ┌──────────┴──────────────┐    │
     │   │ 10. Read ACK, clear     │    │
     │   │     flag, log result    │    │
     │   └─────────────────────────┘    │
     │              │                   │
```

**Critical constraints (must not deviate):**
- All copies to/from ivshmem BAR2 use explicit volatile byte loops — `memcpy` and struct assignment are forbidden. ARM NEON instructions SIGBUS on non-cacheable PCI BAR2; GCC `-O2` LICM hoists non-volatile reads out of poll loops.
- `__sync_synchronize()` wraps every flag read/write (emits `fence iorw,iorw` on RISC-V, `dmb ish` on AArch64).

### Boot-Log Protocol

The boot-log channel (IVSHMEM4) is a higher-level protocol layered on the same flat shared memory:

1. FreeRTOS initializes the header with `BOOTLOG_MAGIC` at BAR2 offset 0.
2. Each Linux guest (`bootlog-arm-linux`, `bootlog-riscv-linux`, `bootlog-mips-linux`) discovers the BAR2, writes a timestamped boot header, sets its `status = HSOC_BOOT_COMPLETE`, and begins draining `/dev/kmsg` into its 1 MiB slot.
3. ARM-Linux `bootlog-writer` additionally reads `IVPOSITION` from BAR0 and writes `collector_peer_id`.
4. FreeRTOS `bootlog_tick()` monitors all 4 guest statuses. When all report boot-complete (or 600 s timeout), it increments `generation` and rings the doorbell with `(peer_id << 16) | 0`.
5. ARM-Linux `boot-collector` polls `generation`, reads each guest's slot via volatile byte loops, and writes individual log files to `/var/log/boot-logs/<guest>.log`.

---

## Building

### Prerequisites

Cross-compilers must be installed for the targets you want to build:

| Binary | Toolchain |
|---|---|
| `ping` | `aarch64-linux-gnu-gcc` |
| `pong` | `riscv64-linux-gnu-gcc` |
| `syslog-arm-linux`, `bootlog-arm-linux`, `boot-collector` | `aarch64-linux-gnu-gcc` |
| `syslog-riscv-linux`, `bootlog-riscv-linux` | `riscv64-linux-gnu-gcc` |
| `syslog-mips-linux`, `bootlog-mips-linux` | `mipsel-linux-gnu-gcc` |
| `freertos-riscv-demo.elf` | `riscv64-unknown-elf-gcc` |

### Build Commands

```bash
# Build everything in the top-level ping/pong demo
cd contrib/heterogeneous-soc
make

# Build everything in the freertos-showcase
cd contrib/heterogeneous-soc/freertos-showcase
make
```

Environment variables for the showcase build:

| Variable | Default | Purpose |
|---|---|---|
| `CC_ARM` | `aarch64-linux-gnu-gcc` | ARM Linux cross-compiler |
| `CC_RISCV` | `riscv64-linux-gnu-gcc` | RISC-V Linux cross-compiler |
| `CC_MIPS` | `mipsel-linux-gnu-gcc` | MIPS Linux cross-compiler |
| `CROSS_COMPILE` | `riscv64-unknown-elf-` | FreeRTOS bare-metal cross-compiler prefix |
| `FREERTOS_KERNEL_DIR` | `$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel` | FreeRTOS kernel source |

### Build Artifacts

| File | Description |
|---|---|
| `ping` | ARM-Linux static binary — ping/pong demo |
| `pong` | RISC-V-Linux static binary — ping/pong demo |
| `freertos-showcase/syslog-arm-linux` | ARM-Linux sysinfo sender |
| `freertos-showcase/syslog-riscv-linux` | RISC-V-Linux sysinfo sender |
| `freertos-showcase/syslog-mips-linux` | MIPS-Linux sysinfo sender |
| `freertos-showcase/linux-arm-stats` | ARM-Linux stats reader |
| `freertos-showcase/bootlog-arm-linux` | ARM-Linux boot-log writer |
| `freertos-showcase/bootlog-riscv-linux` | RISC-V-Linux boot-log writer |
| `freertos-showcase/bootlog-mips-linux` | MIPS-Linux boot-log writer |
| `freertos-showcase/boot-collector` | ARM-Linux boot-log collector |
| `freertos-showcase/freertos-riscv-demo.elf` | RISC-V FreeRTOS bare-metal firmware |

The Makefile automatically skips targets whose toolchain is not found.

---

## Running

These binaries are launched by the `scripts/heterogeneous-soc/` orchestration scripts inside the Lima `qemu-dev` VM. See the top-level [Quick Start](../../README.md#quick-start-two-commands) for the full bring-up sequence.

The helper scripts handle:
- ivshmem server startup (one per channel)
- QEMU launch for each of the 4 guests (ARM, RISC-V, MIPS, FreeRTOS)
- Binary transfer to guest filesystems
- tmux session management (8 panes)

---

## Testing

```bash
# Validate syslog format
cd freertos-showcase
bash test-syslog-format.sh
```

Expected output: `PASS: sysinfo format correct`

---

## Protocol History

This directory evolved in phases:

- **Phase 1:** Original ping/pong demo (ARM → RISC-V, one bidirectional channel)
- **Phase 5:** Three-way Linux → FreeRTOS HELLO/ACK showcase with sysinfo text payloads
- **Phase 6:** Per-channel message-count stats snapshot (FreeRTOS → ARM-Linux)
- **Phase 7:** Boot-log collection with per-guest slots, doorbell signaling, and `/dev/kmsg` capture

The original ping/pong demo is preserved at the top level; the `freertos-showcase/` subtree adds the full multi-guest capabilities without replacing the original.
