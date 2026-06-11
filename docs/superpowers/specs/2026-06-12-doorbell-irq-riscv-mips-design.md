# IVSHMEM1/IVSHMEM2 Doorbell IRQ Extension Design

**Date:** 2026-06-12
**Status:** Draft

## Goal

Extend the doorbell + GIC interrupt path activated for IVSHMEM0 (ARM-Linux ↔
FreeRTOS, see `2026-06-10-doorbell-irq-design.md`) to the two remaining
HELLO/ACK channels:

- **IVSHMEM1** (RISCV-Linux ↔ FreeRTOS, GIC SPI 2 → INTID 34)
- **IVSHMEM2** (MIPS-Linux ↔ FreeRTOS, GIC SPI 3 → INTID 35)

Same wire protocol, same hardware (`ivshmem-doorbell` PCI device is already
present on both Linux guests with `vectors=4`), same `freertos_ivshmem_isr()`
function — this is a mechanical extension of an already-proven pattern, not a
new mechanism.

Out of scope: IVSHMEM3 (stats), IVSHMEM4 (boot log), IVSHMEM5 (CAN). These use
different protocols/directions and are not covered here.

## Dependency

This design builds directly on the unmerged `worktree-doorbell-irq-activation`
branch (`.claude/worktrees/doorbell-irq-activation`, currently at
`7bbde4a822`, 10 commits ahead of `master`). That branch is the baseline for
all file references below. In particular:

- `freertos_ivshmem_isr()` already exists with signature
  `(link, count, cpu_pct, mem_pct, last_hello_ticks)` and is called for
  `arm_link` on GIC SPI 33 (INTID 33).
- `linux_syslog.c` already has `doorbell_init()`, `doorbell_ring()`,
  `hybrid_wait_ack()`, `find_ivshmem_doorbell()`, `bind_uio_pci_generic()` —
  currently gated to `HSOC_SENDER_ID == HSOC_SENDER_ARM_LINUX`.
- The GIC SPI-enable block for INTID 33 (iprio/itarget/ISENABLER/ICFGR,
  edge-triggered) lives inline in `showcase_task()`.

Implementation should continue on this same worktree/branch (per
`CLAUDE.md`'s worktree rules), not branch fresh from `master`.

## Architecture

```
FreeRTOS (R52)                          Linux guest (ARM/RISCV/MIPS)
┌──────────────────────┐                ┌──────────────────────┐
│ arm_link   → SPI33    │◄──doorbell────►│ syslog-arm-linux      │ (existing)
│ riscv_link → SPI34    │◄──doorbell────►│ syslog-riscv-linux    │ (NEW)
│ mips_link  → SPI35    │◄──doorbell────►│ syslog-mips-linux     │ (NEW)
└──────────────────────┘                └──────────────────────┘
```

For each channel: Linux writes HELLO + rings FreeRTOS's doorbell (BAR0+0x0c,
value `0` = peer 0/FreeRTOS, vector 0) → FreeRTOS GIC IRQ fires →
`freertos_ivshmem_isr()` reads HELLO, sends ACK, rings the Linux guest's
doorbell with a per-channel `doorbell_ring_value` → Linux's
`hybrid_wait_ack()` (ppoll on `/dev/uio0`, 200 ms timeout, flag-read fallback)
returns.

All three channels become "interrupt-driven, poll-fallback-on-Linux-side, no
FreeRTOS-side poll" — matching IVSHMEM0's end state exactly.

## Component Changes

### 1. FreeRTOS — `freertos_main.c`

**New INTID defines**, alongside `R52_IVSHMEM0_INTID`:

```c
#define R52_IVSHMEM1_INTID 34U /* IVSHMEM1 (riscv-linux) on GIC SPI 2 → INTID 34 */
#define R52_IVSHMEM2_INTID 35U /* IVSHMEM2 (mips-linux)  on GIC SPI 3 → INTID 35 */
```

**New helper `gic_enable_ivshmem_spi(uint32_t intid)`** — extracts the
existing inline SPI33-enable block (iprio=0xA0, itarget=0x01,
`isen[intid/32] |= (1U << (intid%32))`, edge-triggered
`icfgr[intid/16] |= (1U << (((intid%16)*2)+1))` with its existing comment
explaining why `|=` is required to share words with `R52_CAN_INTID` and the
other IVSHMEM SPIs). `showcase_task()` calls it three times:

```c
gic_enable_ivshmem_spi(R52_IVSHMEM0_INTID);
gic_enable_ivshmem_spi(R52_IVSHMEM1_INTID);
gic_enable_ivshmem_spi(R52_IVSHMEM2_INTID);
```

**`vApplicationIRQHandler()` dispatch** gains two branches mirroring the
existing SPI33 one (each with its own pre-dispatch log line and a
`doorbell_ring_value` of `(1U << 16) | 0U` — see "Peer ID assumption" below):

```c
} else if (intid == R52_IVSHMEM1_INTID) {
    log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem1: SPI34 dispatched\n");
    freertos_ivshmem_isr(&riscv_link, &riscv_count, &riscv_cpu_pct, &riscv_mem_pct,
                          &riscv_last_hello_ticks, (1U << 16) | 0U);
} else if (intid == R52_IVSHMEM2_INTID) {
    log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem2: SPI35 dispatched\n");
    freertos_ivshmem_isr(&mips_link, &mips_count, &mips_cpu_pct, &mips_mem_pct,
                          &mips_last_hello_ticks, (1U << 16) | 0U);
}
```

The existing IVSHMEM0/SPI33 branch also gains the `(1U << 16) | 0U` argument
for consistency.

**Poll loop**: remove `riscv_link` and `mips_link` from the
`maybe_service_link()` calls in `showcase_task()`'s `for(;;)` loop, with a
comment matching `arm_link`'s existing one — polling would race the ISR for
`linux_to_freertos.flag`. Stats/heartbeat bookkeeping (`*_count`, `*_cpu_pct`,
`*_mem_pct`, `*_last_hello_ticks`) is updated inside `freertos_ivshmem_isr()`
for all three links, so `write_stats_snapshot()` and the 30s heartbeat
watchdog keep working unchanged.

### 2. FreeRTOS — `freertos_ivshmem_flat.c` / `.h`

**`freertos_ivshmem_isr()` gains a `uint32_t doorbell_ring_value` parameter**,
replacing the hardcoded `(1U << 16) | 0U` in its body:

```c
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks,
                          uint32_t doorbell_ring_value);
```

**Log messages use `link->name`** instead of the hardcoded `"ivshmem0"`, so
the success log (`"[irq] HELLO handled via IRQ"`) and the validation-failure
log (magic/version/type mismatch) are correctly attributed to
`arm-linux`/`riscv-linux`/`mips-linux`:

```c
log_uart(HSOC_LOG_INFO, "[irq] ");
log_uart(HSOC_LOG_INFO, link->name);
log_uart(HSOC_LOG_INFO, ": HELLO handled via IRQ\n");
```

(same prefix pattern applied to the validation-failure branch)

### 3. Linux — `linux_syslog.c`

**Relax `doorbell_init()`'s sender gate.** Remove:

```c
if (HSOC_SENDER_ID != HSOC_SENDER_ARM_LINUX) {
    return -1;
}
```

and rewrite the comment above it: doorbell/IRQ support now applies to all
three senders. FreeRTOS rings each link's *own* per-channel doorbell, so
`find_ivshmem_doorbell()` locating *this guest's own* syslog channel
(excluding its BOOTLOG-magic channel) is exactly the desired behavior — it is
no longer the "wrong channel for a peer with no ISR" problem the original
comment warned about.

No other changes to `linux_syslog.c`: `find_ivshmem_doorbell()`,
`doorbell_ring()` (writes constant `0` = "ring peer 0, vector 0"),
`hybrid_wait_ack()`, and `bind_uio_pci_generic()` are already
architecture-generic.

### 4. QEMU Machine Definitions

**No changes.** RISCV-Linux (`guest-run-riscv-phase5.sh`) and MIPS-Linux
(`guest-run-chimera.sh`) already instantiate
`ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}"` (vectors=4)
for IVSHMEM1/IVSHMEM2, identical to ARM-Linux's IVSHMEM0 device.

### 5. Build & Launch Scripts

**No changes.** `syslog-riscv-linux` and `syslog-mips-linux` Makefile targets
already define the correct `HSOC_SENDER_ID`/`HSOC_SENDER_LABEL`.
`guest-install-syslog-to-guests.sh` already injects both binaries. Rebuilding
and redeploying is sufficient.

## Peer ID assumption

`freertos_ivshmem_isr()` rings `(1U << 16) | 0U` (peer 1, vector 0) on
IVSHMEM0 — confirmed via the existing startup IVPOSITION diagnostic
(`arm_link` IVPOSITION == 0, i.e. FreeRTOS is peer 0, Linux is peer 1) and via
`linux_syslog.c`'s `doorbell_ring()` writing `0` (peer 0 = FreeRTOS) on the
Linux side. The same `(1U << 16) | 0U` value is used for `riscv_link` and
`mips_link` under the assumption that FreeRTOS also joins as peer 0 on those
per-channel ivshmem-servers (each server has only FreeRTOS + one Linux guest,
and FreeRTOS connects to all six servers at its single startup before any
Linux guest's QEMU process starts).

This assumption is verified at test time via the existing IVPOSITION
diagnostic (already logs `riscv=` and `mips=` IVPOSITION values). Because
`doorbell_ring_value` is now a parameter rather than hardcoded inside
`freertos_ivshmem_isr()`, if either channel's IVPOSITION is non-zero, fixing
it is a one-line change at that channel's `vApplicationIRQHandler()` call
site — no function-body changes needed.

## ivshmem Channel Map (updated)

| Channel | MMIO | SHMEM | SPI | INTID | Mechanism |
|---------|------|-------|-----|-------|-----------|
| IVSHMEM0 | 0x30000000 | 0x31000000 | 1 | 33 | Interrupt + 200ms poll (existing) |
| **IVSHMEM1** | 0x35000000 | 0x36000000 | 2 | 34 | **Interrupt + 200ms poll (NEW)** |
| **IVSHMEM2** | 0x3A000000 | 0x3B000000 | 3 | 35 | **Interrupt + 200ms poll (NEW)** |
| IVSHMEM3 | 0x3F000000 | 0x40000000 | 4 | 36 | Stats FreeRTOS→ARM (poll) |
| IVSHMEM4 | 0x44000000 | 0x45000000 | 5 | 37 | Boot log (poll) |
| IVSHMEM5 | 0x49000000 | 0x4A000000 | 7 | 39 | CAN frames FreeRTOS→ARM (poll) |

`2026-06-10-doorbell-irq-design.md`'s channel map and "Three concurrent
mechanisms" section, and the equivalent table in `README.md`, should be
updated to reflect this (generalize "on IVSHMEM0" → "on IVSHMEM0/1/2").

## Testing

1. Build `freertos-r52-demo.elf`, `syslog-riscv-linux`, `syslog-mips-linux`
   (and `syslog-arm-linux` for regression).
2. Deploy via `guest-install-syslog-to-guests.sh`, launch showcase.
3. FreeRTOS UART: confirm `[irq] ivshmem1: SPI34 dispatched` /
   `riscv-linux: HELLO handled via IRQ`, and the IVSHMEM2/mips-linux
   equivalents.
4. Check the IVPOSITION diagnostic line: confirm `riscv=0` and `mips=0`
   (validates the `(1U<<16)|0U` constants — see "Peer ID assumption").
5. Confirm ACK sequence numbers increment on all three Linux guests'
   `/var/log/chimera-log/chimera-cross-domain.log`.
6. On riscv-linux/mips-linux guests, check the syslog daemon's stderr for
   `doorbell: init OK (uio_fd=N, bdf=...)`. If `uio_fd=-1`,
   `uio_pci_generic` is unavailable on that kernel — confirm ACKs still
   arrive via the busy-wait fallback (see Risks).
7. Regression: CAN bus demo, stats snapshots, boot-log collection still work.

## Risks / Open Items

- **`uio_pci_generic` availability on riscv64/mipsel — checked, present as a
  module.** Mounted both guest qcow2 images directly (no kernel configs are
  checked into this repo; RISCV/MIPS use stock Debian images) and confirmed
  `uio_pci_generic.ko` exists under `/lib/modules/<ver>/kernel/drivers/uio/`
  for both: riscv64 (`6.12.73+deb13-riscv64`, as `.ko.xz`) and mipsel
  (`6.1.0-42-4kc-malta`, as `.ko`) — same as ARM-Linux, not built-in either.
  `modprobe uio_pci_generic` should therefore succeed on both guests. Test
  step 6 still confirms the full path (modprobe → driver_override → bind →
  `/dev/uio0` appears) end-to-end at runtime, since module presence doesn't
  guarantee the bind succeeds. If it doesn't: `doorbell_init()` still mmaps
  BAR0, so `doorbell_ring()` still works (FreeRTOS still gets IRQ-driven wake
  from Linux's HELLO) — only `hybrid_wait_ack()` on that guest falls back to
  its existing `uio_fd < 0` busy-wait path (unchanged from current behavior,
  no regression, just no latency win for that guest's ACK wait).
- **IVPOSITION assumption** for IVSHMEM1/IVSHMEM2 — see "Peer ID assumption"
  above; checked in test step 4, one-line fix if wrong.
