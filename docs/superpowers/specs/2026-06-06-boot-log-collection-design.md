# Boot Log Collection via Dedicated Ivshmem Channel

**Date:** 2026-06-06
**Status:** Draft

## Overview

Add a cross-domain boot-log collection mechanism to the Chimera heterogeneous SoC
showcase. Each guest (ARM-Linux, RISCV-Linux, MIPS-Linux, FreeRTOS) writes its
kernel ring buffer / boot messages into a shared memory region as it boots.
FreeRTOS monitors all four completion flags and notifies ARM-Linux via ivshmem
doorbell when all guests have booted (or a 600 s timeout fires). ARM-Linux then
reads all four slots and saves them to its filesystem.

## Architecture

A new dedicated ivshmem server (Unix socket) connects all four guests. The
server provides a single shared memory BAR2 that every guest can read and write.

```
       ┌──────────────────────────────────────────────┐
       │          boot-log ivshmem server             │
       │          (shmem 5 MB, Unix socket)           │
       └──┬──────────┬──────────┬──────────┬──────────┘
          │          │          │          │
          ▼          ▼          ▼          ▼
      ARM-Linux  RISCV-Linux  MIPS-Linux  FreeRTOS
      (PCI        (PCI        (PCI        (ivshmem-flat
       doorbell)   doorbell)   doorbell)   IVSHMEM4)
```

**Existing channel mapping (for reference):**

| # | Server socket | FreeRTOS device | Linux device | Purpose |
|---|---|---|---|---|
| 0 | `IVSHMEM_ARM_FREERTOS_SOCKET` | ivshmem-flat IVSHMEM0 | PCI doorbell (ARM) | HELLO/ACK protocol |
| 1 | `IVSHMEM_RISCV_FREERTOS_SOCKET` | ivshmem-flat IVSHMEM1 | PCI doorbell (RISCV) | HELLO/ACK protocol |
| 2 | `IVSHMEM_MIPS_FREERTOS_SOCKET` | ivshmem-flat IVSHMEM2 | PCI doorbell (MIPS) | HELLO/ACK protocol |
| 3 | `IVSHMEM_STATS_FREERTOS_SOCKET` | ivshmem-flat IVSHMEM3 | PCI doorbell (ARM) | Stats snapshots |
| **4** | **`IVSHMEM_BOOTLOG_SOCKET`** | **ivshmem-flat IVSHMEM4** | **PCI doorbell (all)** | **Boot logs (NEW)** |

## Shared Memory Layout

Defined in `contrib/heterogeneous-soc/freertos-showcase/bootlog_proto.h`.

```
Offset      Size      Field
──────────────────────────────────────────────────
0x0000      32 B     struct hsoc_bootlog_header
                       magic          (uint32_t)  — "BTLG"
                       generation     (uint32_t)  — incremented on each collection event
                       collector_peer_id (uint32_t) — set by ARM-Linux at startup
                       pad            (uint32_t)
                       guests[4]:
                         status       (uint32_t)  — 0=BOOTING, 1=BOOT_COMPLETE
                         offset       (uint32_t)  — byte count of written data
0x0020      0xFE0    unused / reserved
0x1000      1 MiB    ARM-Linux boot log slot
0x101000   1 MiB    RISCV-Linux boot log slot
0x201000   1 MiB    MIPS-Linux boot log slot
0x301000   1 MiB    FreeRTOS boot log slot
Total: ~4 MiB + 4 KiB header
```

### `struct hsoc_bootlog_header`

```c
#define BOOTLOG_MAGIC      0x424C5447U  /* "BTLG" */
#define BOOTLOG_PROTO_VER  1U
#define BOOTLOG_SLOT_SIZE  0x100000U    /* 1 MiB per guest */
#define BOOTLOG_NUM_GUESTS 4U

enum hsoc_boot_status {
    HSOC_BOOT_BOOTING       = 0,
    HSOC_BOOT_COMPLETE      = 1,
};

enum hsoc_bootlog_guest {
    HSOC_GUEST_ARM_LINUX    = 0,
    HSOC_GUEST_RISCV_LINUX  = 1,
    HSOC_GUEST_MIPS_LINUX   = 2,
    HSOC_GUEST_FREERTOS     = 3,
};

struct hsoc_bootlog_guest_state {
    volatile uint32_t status;
    volatile uint32_t offset;   /* byte offset of next unwritten position */
    uint32_t          reserved[2];
};

struct hsoc_bootlog_header {
    uint32_t          magic;
    volatile uint32_t generation;
    volatile uint32_t collector_peer_id;  /* written by ARM-Linux once */
    uint32_t          reserved;
    struct hsoc_bootlog_guest_state guests[BOOTLOG_NUM_GUESTS];
};
```

## Data Flow

```
 Phase 1: Boot (all guests run in parallel)
 ─────────────────────────────────────────────────────────
    ARM-Linux       RISCV-Linux       MIPS-Linux       FreeRTOS
       │                │                │               │
       │ mmap BAR2      │ mmap BAR2      │ mmap BAR2     │ init IVSHMEM4
       │ discover peer  │ write log      │ write log     │ set collector_peer_id
       │ write log      │ status=1       │ status=1      │ once ARM writes it
       │ write ARM peer │                │               │ log to slot
       │ id to header   │                │               │ poll all 4 status
       │ status=1       │                │               │ countdown timer
       │                │                │               │
       └────────────────┴────────────────┴───────────────┘
                                                          │
 Phase 2: Notification                                      │
 ┌──────────────────────────────────────────────────────────┘
 │ All 4 status == BOOT_COMPLETE OR 600 s timeout?
 │ YES → FreeRTOS writes DOORBELL register:
 │        DOORBELL = (collector_peer_id << 16) | vector_0
 │        (doorbell is a best-effort notification; the kernel
 │         PCI driver acknowledges the interrupt. The primary
 │         wake mechanism is polling, described below.)
 │
 ▼
 Phase 3: Collection
    ARM-Linux boot-collector daemon
       │ Polls bootlog_header.generation every 2 s via mmap'd BAR2
       │ On generation change (or on startup if generation != 0):
       │   read all 4 slots via volatile byte loops
       │   write files:
       │     /var/log/boot-logs/guest-arm.log
       │     /var/log/boot-logs/guest-riscv.log
       │     /var/log/boot-logs/guest-mips.log
       │     /var/log/boot-logs/guest-freertos.log
       │   set generation++
       │ done
```

## QEMU Surface Changes

### FreeRTOS Machine (`hw/riscv/chimera_freertos_demo.c`)

Add a 5th `ivshmem-flat` device:

```c
// Memory map entries
[CHIMERA_FREERTOS_IVSHMEM4_MMIO]  = { 0x44000000, 0x00001000 },
[CHIMERA_FREERTOS_IVSHMEM4_SHMEM] = { 0x45000000, 0x00500000 },  /* 5 MiB */

// IRQ
CHIMERA_FREERTOS_IVSHMEM4_IRQ = 20

// Property
#define CHIMERA_FREERTOS_PROP_IVSHMEM_BOOTLOG "ivshmem-bootlog-freertos"
```

The `shmem-size` for this device is set to 5 MiB (slightly larger than the
maximum possible data to account for the header).

### Linux Launch Scripts

Each Linux guest (ARM, RISCV, MIPS) gets one additional chardev + PCI device:

```bash
# In guest-run-arm-phase5.sh, guest-run-riscv-phase5.sh, guest-run-chimera.sh:
-chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}"
-device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1
```

The Linux `bootlog_writer` daemon boots via the guest's existing systemd and
discovers the boot-log BAR2 by scanning `/sys/bus/pci/devices/*/resource2` for
the `BOOTLOG_MAGIC` signature (same pattern as the existing
`linux_stats.c`).

### New Ivshmem Server

```bash
# scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh
ivshmem-server -S "${IVSHMEM_BOOTLOG_SOCKET}" \
               -s 5242880 \     # 5 MiB shmem
               -n 4             # up to 4 vectors (1 per guest, though only 1 is used)
```

Socket path (from `common.sh`):
```bash
IVSHMEM_BOOTLOG_DIR="${IVSHMEM_BOOTLOG_DIR:-/tmp/ivshmem-bootlog}"
IVSHMEM_BOOTLOG_SOCKET="${IVSHMEM_BOOTLOG_SOCKET:-${IVSHMEM_BOOTLOG_DIR}/sock}"
```

## New Files

### `contrib/heterogeneous-soc/freertos-showcase/bootlog_proto.h`

Shared header defining the memory layout, magic, status enum, and guest index enum.
Used by all four guests' writer code and the ARM-Linux collector.

### `contrib/heterogeneous-soc/freertos-showcase/bootlog_writer.c`

**Linux per-guest daemon** — compiled for each target (`bootlog-arm-linux`,
`bootlog-riscv-linux`, `bootlog-mips-linux`). Runs as a systemd service
`bootlog-writer.service`.

- Takes one optional arg: BAR2 path (auto-discovers if omitted)
- Opens `/dev/kmsg` with `O_RDONLY | O_NONBLOCK`
- Reads all existing kernel messages and appends to own shmem slot
- Continues reading new messages (poll loop with short sleep)
- On systemd `boot-complete.target` (via `sd_notify` barrier), sets
  `status = BOOT_COMPLETE`
- Uses volatile byte loops for all shmem writes (NEON-safe)
- Log slot full → wraps with truncation marker

**ARM-Linux variant** additionally:
- Reads `IVPOSITION` from the boot-log BAR2 MMIO registers
- Writes its peer_id into `collector_peer_id` in the shared header
  (so FreeRTOS knows where to ring the doorbell)

### `contrib/heterogeneous-soc/freertos-showcase/boot_collector.c`

**ARM-Linux collector daemon** — runs as systemd service
`boot-collector.service`.

- Opens the boot-log BAR2 (`resource2`) via sysfs, mmap with
  `PROT_READ | PROT_WRITE`
- Polls `header.generation` every 2 s with `__sync_synchronize()`
- On change from `last_seen_generation`: reads all 4 guest slots via
  volatile byte loops
- Writes files to `/var/log/boot-logs/guest-<name>.log`
- Each file contains one contiguous dump of the slot data
- To handle the case where a daemon is killed mid-write: only reads up to
  `guests[i].offset` bytes, which is written atomically (fenced) after each
  write batch

### FreeRTOS Changes (`freertos_main.c`)

- New `freertos_ivshmem_link bootlog_link` initialized with `IVSHMEM4_MMIO`
  and `IVSHMEM4_SHMEM`
- In `showcase_task` poll loop:
  1. Poll `collector_peer_id` until non-zero (ARM-Linux has booted)
  2. Poll all 4 `guests[i].status` fields
  3. Increment a timer counter each cycle (task fires every 1 ms)
  4. When all status == `HSOC_BOOT_COMPLETE` OR timer reaches 600,000:
     - Read `collector_peer_id`
     - Write doorbell: `*(volatile uint32_t *)(mmio_base + DOORBELL) = (collector_peer_id << 16) | 0`
     - Wait (do not fire again until a reset condition, e.g., generation change)

### `scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh`

New ivshmem-server launch script, following the pattern of the existing server
scripts (e.g., `guest-start-ivshmem-server-arm-freertos.sh`).

## Tmux Launch Changes

In `guest-run-phase5-tmux.sh`:

1. Add a 5th ivshmem-server pane (or reuse the proportional layout to fit 5
   server panes, or keep 4 server panes + move boot-log server to run
   alongside)
2. Wait for the boot-log socket before launching guests
3. Pass `bootlog-writer` commands in the `auto_login_and_run` blocks for each
   Linux guest
4. Pass `boot-collector` for ARM-Linux

The tmux layout changes:

```
┌──────┬──────┬──────┬──────┬──────┐
│srv   │srv   │srv   │srv   │srv   │  panes 0-4 (server panes)
│ARM-FT│RISCV │MIPS  │STATS │BOOT  │
├──────┴──────┴──────┴──────┴──────┤
│            FreeRTOS               │  pane 5
├────────┬────────┬────────────────┤
│ARM-Lin │RISCV-L │ MIPS-Linux     │  panes 6,7,8
└────────┴────────┴────────────────┘
```

## Error Handling

| Scenario | Behavior |
|---|---|
| ARM-Linux never boots | FreeRTOS hits 600 s timeout, rings doorbell — nobody answers (daemon not started). Boot log data exists in shmem but stays uncollected. |
| Some guests never finish booting | FreeRTOS timer fires at 600 s, partial logs collected |
| Log exceeds 1 MiB slot | Writer wraps. A truncation header `--- truncated ---` is written before wrap so the collector can detect it |
| ARM-Linux not ready when doorbell fires | Doorbell interrupt is acknowledged by the kernel PCI driver but the collector daemon may not be running yet. This is safe because the collector uses polling as its primary wake mechanism — it detects the generation change on its next poll cycle after starting. |
| Guest crashes mid-write | The `offset` field is written with a fence after each batch of writes. A crash mid-write leaves `offset` pointing to the last complete write boundary, so the collector reads valid data up to that point. |
| ivshmem server restarts | All peers reconnect via the Unix socket. FreeRTOS re-initializes its link. Linux guests re-open BAR2. Slots are re-populated from scratch. |

## Build Integration

The `bootlog_writer.c` and `boot_collector.c` targets are added to the
existing `contrib/heterogeneous-soc/freertos-showcase/Makefile`, following the
same cross-compilation pattern as `linux_syslog.c`:

```
CC_arm     = aarch64-linux-gnu-gcc
CC_riscv   = riscv64-linux-gnu-gcc
CC_mips    = mipsel-linux-gnu-gcc

bootlog-arm-linux: bootlog_writer.c bootlog_proto.h
bootlog-riscv-linux: bootlog_writer.c bootlog_proto.h
bootlog-mips-linux: bootlog_writer.c bootlog_proto.h
boot-collector: boot_collector.c bootlog_proto.h
```

The FreeRTOS binary is re-linked with the new boot-log code (no separate
binary needed — it's built into `freertos_main.c`).

Variables in `common.sh`:
```bash
IVSHMEM_BOOTLOG_DIR="${IVSHMEM_BOOTLOG_DIR:-/tmp/ivshmem-bootlog}"
IVSHMEM_BOOTLOG_SOCKET="${IVSHMEM_BOOTLOG_SOCKET:-${IVSHMEM_BOOTLOG_DIR}/sock}"
BOOTLOG_ARM_BINARY="${BOOTLOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-arm-linux}"
BOOTLOG_RISCV_BINARY="${BOOTLOG_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-riscv-linux}"
BOOTLOG_MIPS_BINARY="${BOOTLOG_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-mips-linux}"
BOOT_COLLECTOR_BINARY="${BOOT_COLLECTOR_BINARY:-${FREERTOS_SHOWCASE_DIR}/boot-collector}"
```

## Testing

1. **Functional:** Boot the full Phase 5 showcase, verify that `boot-collector`
   creates four `.log` files in `/var/log/boot-logs/` with non-zero content
   within 600 s of the last guest booting.
2. **Timeout:** Boot only a subset of guests (e.g., disable RISCV-Linux).
   Verify that `boot-collector` still writes the available logs after 600 s.
3. **Wrap-around:** Artificially reduce the slot size in `bootlog_proto.h` to
   4 KiB and fill it. Verify that the truncation marker appears and no data
   is lost beyond the wrapped boundary.
4. **Polling wake-up:** Confirm that `boot-collector` detects the
   `generation` change within 5 s of FreeRTOS signaling completion.
5. **Stability:** Run the full showcase for 3 consecutive cycles. Verify the
   `boot-pingpong` HELLO/ACK exchange runs normally and boot-log collection
   does not interfere with the stats channel.
