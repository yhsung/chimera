# FreeRTOS Stats Forwarding to ARM-Linux

**Date:** 2026-06-06
**Status:** Approved

## Goal

Extend Chimera so that FreeRTOS collects message-exchange statistics (per-channel HELLO counts and FreeRTOS tick time) and periodically forwards them to ARM-Linux over a dedicated ivshmem stats channel. ARM-Linux saves each snapshot as a line in `/tmp/freertos-stats.log`.

## Architecture

A 4th ivshmem channel ("stats channel") is added alongside the three existing HELLO/ACK channels. FreeRTOS is the sole writer; ARM-Linux is the sole reader. No ARM-Linux→FreeRTOS direction is needed.

```
FreeRTOS (RISC-V)                    ARM-Linux (AArch64)
  showcase_task                         linux_stats daemon
  - counts HELLOs/ACKs per channel      - polls stats shmem every 2s
  - every 5s: writes snapshot           - on generation change: appends log
    to IVSHMEM3 shmem                     line to /tmp/freertos-stats.log
        |                                        |
        +---- ivshmem-flat(3) ----[shmem]---- ivshmem-doorbell(1) ----+
                              ivshmem-server
                         /tmp/ivshmem-stats-freertos/sock
```

**Data flow:** FreeRTOS increments a monotonic `generation` counter on each snapshot write. ARM-Linux detects new data by comparing the current generation to the last seen value — no acknowledgement handshake required.

## Files Changed or Added

| File | Change |
|---|---|
| `contrib/heterogeneous-soc/freertos-showcase/stats_proto.h` | New — shared memory layout |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Track message counts; write periodic snapshot |
| `contrib/heterogeneous-soc/freertos-showcase/linux_stats.c` | New — ARM-Linux poll-and-log binary |
| `contrib/heterogeneous-soc/freertos-showcase/Makefile` | Add `linux-arm-stats` build target |
| `include/hw/riscv/chimera_freertos_demo.h` | Add IVSHMEM3 memory map entries, IRQ, property name |
| `hw/riscv/chimera_freertos_demo.c` | Add 4th ivshmem-flat device and machine property |
| `scripts/heterogeneous-soc/common.sh` | Add `IVSHMEM_STATS_FREERTOS_DIR/SOCKET` defaults |
| `scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh` | New — launch stats ivshmem-server |
| `scripts/heterogeneous-soc/guest-run-arm-phase5.sh` | Add 2nd `ivshmem-doorbell` |
| `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh` | Add stats machine property |
| `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` | Launch stats server + `linux_stats` after ARM boots |

## Section 1 — Shared Memory Layout (`stats_proto.h`)

```c
#define HSOC_STATS_MAGIC 0x53544154U  /* "STAT" */

struct hsoc_stats_snapshot {
    uint32_t         magic;       /* HSOC_STATS_MAGIC, written once at FreeRTOS init */
    volatile uint32_t generation; /* incremented by FreeRTOS after each snapshot write */
    uint32_t arm_count;    /* total HELLOs received from ARM-Linux */
    uint32_t riscv_count;
    uint32_t mips_count;
    uint32_t pad;
    int64_t  tick_sec;     /* FreeRTOS tick time when snapshot was taken */
    int64_t  tick_nsec;
};
```

**Write protocol (FreeRTOS):**
1. Write all payload fields (arm_count, riscv_count, mips_count, tick_sec, tick_nsec) via volatile byte loop — no `memcpy`, matching the existing hello protocol discipline.
2. `__sync_synchronize()`
3. Increment `generation` via volatile write + fence.
4. `magic` is written once at init and never changed.

**Read protocol (ARM-Linux):**
1. `shm_read` the whole struct into a local copy.
2. `__sync_synchronize()`
3. If `local.generation == last_seen_generation`, skip.
4. Verify `local.magic == HSOC_STATS_MAGIC`.
5. Process and log, update `last_seen_generation`.

**Device identification:** `linux_stats` scans all PCI ivshmem devices (vendor 0x1af4), maps each BAR2, and selects the first one whose first 4 bytes equal `HSOC_STATS_MAGIC`. This avoids any ordinal assumptions about which PCI slot the stats device occupies. Falls back to accepting a BAR2 path via `argv[1]`.

## Section 2 — FreeRTOS Changes (`freertos_main.c`)

**New MMIO/SHMEM addresses:**
```c
#define IVSHMEM3_MMIO  0x3F000000UL
#define IVSHMEM3_SHMEM 0x40000000UL
```

`IVSHMEM3_SHMEM` at `0x40000000` is 64 MiB after `IVSHMEM2_SHMEM` (`0x3B000000`), fitting cleanly without overlapping any existing region.

**New state:**
```c
static struct freertos_ivshmem_link stats_link;
static uint32_t arm_count, riscv_count, mips_count;
static uint32_t stats_tick;
```

**`maybe_service_link` signature change:**
```c
static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count);
```
Increments `*count` when a HELLO is successfully serviced. No other behavior change.

**Stats write helper** (`write_stats_snapshot`): writes `hsoc_stats_snapshot` using a `volatile struct hsoc_stats_snapshot *stats_shmem` pointer initialized directly to `(volatile struct hsoc_stats_snapshot *)IVSHMEM3_SHMEM`. This avoids a type conflict with `stats_link.layout` (which is typed `struct hsoc_layout *`). `freertos_ivshmem_init` is still called on `stats_link` for MMIO register setup; shmem is accessed solely through `stats_shmem`.

**Periodic trigger** — appended to the main showcase loop:
```c
if (++stats_tick >= 5000) {
    stats_tick = 0;
    write_stats_snapshot();
}
```

At `configTICK_RATE_HZ = 1000` and `vTaskDelay(pdMS_TO_TICKS(1))` per iteration, this fires every ~5 seconds.

`magic` is written once via `write_stats_magic()` called at startup before the scheduler.

## Section 3 — ARM-Linux Binary (`linux_stats.c`)

**Device discovery:** scans `/sys/bus/pci/devices` for vendor 0x1af4, maps each `resource2`, checks first 4 bytes against `HSOC_STATS_MAGIC`. Retries every 2 seconds for up to 30 seconds if no device found yet (FreeRTOS writes magic before `vTaskStartScheduler()`, but ARM-Linux may scan before FreeRTOS QEMU has started). Accepts optional `argv[1]` override to skip discovery entirely.

**Poll loop:**
```c
uint32_t last_gen = 0;
while (true) {
    struct hsoc_stats_snapshot snap;
    shm_read(&snap, shm, sizeof(snap));
    __sync_synchronize();
    if (snap.generation != last_gen && snap.magic == HSOC_STATS_MAGIC) {
        last_gen = snap.generation;
        /* format timestamp + fields, append to log file */
    }
    sleep(2);
}
```

**Log line format:**
```
[2026-06-06T12:34:56Z] gen=42 arm=100 riscv=98 mips=95 tick=42.000000000
```

Log file path: `FREERTOS_STATS_LOG` env var, defaulting to `/tmp/freertos-stats.log`.

**Build target (`Makefile`):**
```makefile
linux-arm-stats: linux_stats.c stats_proto.h hello_proto.h
	$(CC_ARM) $(CFLAGS) -o $@ linux_stats.c
```
Where `CC_ARM = aarch64-linux-gnu-gcc`.

## Section 4 — QEMU Machine (`chimera_freertos_demo.h` / `.c`)

**`chimera_freertos_demo.h` additions:**
- Memory map: `CHIMERA_FREERTOS_IVSHMEM3_MMIO`, `CHIMERA_FREERTOS_IVSHMEM3_SHMEM`
- IRQ: `CHIMERA_FREERTOS_IVSHMEM3_IRQ = 19`
- Property name: `CHIMERA_FREERTOS_PROP_IVSHMEM_STATS "ivshmem-stats-freertos"`
- Machine state field: `char *ivshmem_stats_freertos`

**`chimera_freertos_demo.c` additions:**
- Memmap entries: `[CHIMERA_FREERTOS_IVSHMEM3_MMIO] = { 0x3F000000, 0x00001000 }`, `[CHIMERA_FREERTOS_IVSHMEM3_SHMEM] = { 0x40000000, CHIMERA_FREERTOS_IVSHMEM_SIZE }`
- Property get/set handlers for `ivshmem-stats-freertos` (same pattern as the other three)
- 4th `chimera_freertos_connect_ivshmem` call in `chimera_freertos_init`

## Section 5 — Scripts

**`common.sh`:**
```bash
IVSHMEM_STATS_FREERTOS_DIR="${IVSHMEM_STATS_FREERTOS_DIR:-/tmp/ivshmem-stats-freertos}"
IVSHMEM_STATS_FREERTOS_SOCKET="${IVSHMEM_STATS_FREERTOS_SOCKET:-${IVSHMEM_STATS_FREERTOS_DIR}/sock}"
```

**`guest-start-ivshmem-server-stats.sh`** (new): same structure as `guest-start-ivshmem-server-arm-freertos.sh`; uses `IVSHMEM_STATS_FREERTOS_DIR`, `-M ivshmem-stats-ft`.

**`guest-run-arm-phase5.sh`:** add second ivshmem-doorbell:
```bash
-chardev socket,id=ivshmem_stats,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
-device ivshmem-doorbell,chardev=ivshmem_stats,vectors="${IVSHMEM_VECTORS}" \
```

**`guest-run-riscv-freertos-phase5.sh`:** add stats machine property (same `-machine chimera-riscv-freertos-demo,...` extension pattern as the other ivshmem properties).

**`guest-run-phase5-tmux.sh`:** add a 3rd ivshmem-server pane; after ARM-Linux boots and `hello-arm-linux` is running, launch `linux_stats` (copied to `/tmp/linux-arm-stats` via 9p, then executed).

## Success Criteria

1. FreeRTOS prints `[freertos] stats snapshot written gen=N` every ~5 seconds.
2. ARM-Linux `linux_stats` prints `[stats] gen=N logged` to stdout for each new snapshot.
3. `/tmp/freertos-stats.log` on ARM-Linux accumulates lines with non-zero `arm_count` after the hello loop has been running.
4. Existing HELLO/ACK exchange on all three channels continues unaffected.
5. `run-freertos-harness.sh` still passes (harness does not depend on stats channel).
