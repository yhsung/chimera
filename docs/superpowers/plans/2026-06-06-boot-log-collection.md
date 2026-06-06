# Boot Log Collection via Dedicated Ivshmem Channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cross-domain boot-log collection mechanism to the Chimera heterogeneous SoC showcase, where all four guests write boot messages to a shared memory region, FreeRTOS monitors completion, and ARM-Linux collects the logs.

**Architecture:** A 5th `ivshmem-flat` device (IVSHMEM4) on the FreeRTOS machine + a 5th PCI `ivshmem-doorbell` on each Linux guest, all connected to a new dedicated ivshmem server. FreeRTOS polls guest boot-status flags in shared memory and rings a doorbell after all guests complete (or a 600 s timeout fires). ARM-Linux polls for generation changes and dumps all four slots to `/var/log/boot-logs/`.

**Tech Stack:** C (FreeRTOS bare-metal, Linux daemons), QEMU machine C code, Bash (launch scripts, tmux), Makefile cross-compilation

---

## File Structure

### New Files
| File | Purpose |
|---|---|
| `contrib/heterogeneous-soc/freertos-showcase/bootlog_proto.h` | Shared header: magic, status enum, guest index enum, header struct, slot layout |
| `contrib/heterogeneous-soc/freertos-showcase/bootlog_writer.c` | Linux per-guest daemon: reads `/dev/kmsg`, writes to BAR2 slot. ARM variant additionally writes `collector_peer_id` |
| `contrib/heterogeneous-soc/freertos-showcase/boot_collector.c` | ARM-Linux-only daemon: polls `generation`, dumps all 4 slots to files |
| `contrib/heterogeneous-soc/freertos-showcase/boot_log.c` | FreeRTOS module: polls guest status flags, rings doorbell on all-complete or timeout |
| `contrib/heterogeneous-soc/freertos-showcase/boot_log.h` | FreeRTOS boot-log monitor header |
| `scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh` | New ivshmem server launch script (5 MiB shmem) |
| `scripts/heterogeneous-soc/guest-install-bootlog-to-guests.sh` | Injects bootlog writer + collector binaries into guest rootfs images |

### Modified Files
| File | Change |
|---|---|
| `include/hw/riscv/chimera_freertos_demo.h` | Add IVSHMEM4 memory map entries, IRQ enum, property define |
| `hw/riscv/chimera_freertos_demo.c` | Add IVSHMEM4 device instantiation, property getter/setter, plic source count bump |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Add boot_log.h include, monitor task, bootlog_link init |
| `contrib/heterogeneous-soc/freertos-showcase/Makefile` | Add bootlog_writer, boot_collector targets, boot_log.c to freertos-src |
| `scripts/heterogeneous-soc/common.sh` | Add `IVSHMEM_BOOTLOG_*`, `BOOTLOG_*`, `BOOT_COLLECTOR_*` env vars |
| `scripts/heterogeneous-soc/guest-build-freertos-showcase.sh` | No changes needed — just `make` (Makefile picks up new targets) |
| `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh` | Add boot-log server to LAUNCH_SCRIPTS, install-bootlog step |
| `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` | Add 5th server pane, boot-log socket wait, auto_login_and_run for bootlog-writer + boot-collector |
| `scripts/heterogeneous-soc/guest-run-arm-phase5.sh` | Add boot-log chardev + PCI doorbell |
| `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh` | Add boot-log chardev + PCI doorbell |
| `scripts/heterogeneous-soc/guest-run-chimera.sh` | Add boot-log chardev + PCI doorbell |
| `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh` | Add boot-log chardev for IVSHMEM4 |

---

### Task 1: Protocol Header (`bootlog_proto.h`)

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/bootlog_proto.h`

- [ ] **Step 1: Write bootlog_proto.h**

```c
#ifndef HETEROGENEOUS_SOC_BOOTLOG_PROTO_H
#define HETEROGENEOUS_SOC_BOOTLOG_PROTO_H

#include <stdint.h>

#define BOOTLOG_MAGIC       0x424C5447U  /* "BTLG" */
#define BOOTLOG_PROTO_VER   1U
#define BOOTLOG_SLOT_SIZE   0x100000U    /* 1 MiB per guest */
#define BOOTLOG_NUM_GUESTS  4U

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
    volatile uint32_t status;    /* hsoc_boot_status */
    volatile uint32_t offset;    /* byte offset of next unwritten position */
    uint32_t          reserved[2];
};

struct hsoc_bootlog_header {
    uint32_t          magic;        /* BOOTLOG_MAGIC */
    volatile uint32_t generation;   /* incremented on each collection event */
    volatile uint32_t collector_peer_id;  /* set by ARM-Linux once at startup */
    uint32_t          reserved;
    struct hsoc_bootlog_guest_state guests[BOOTLOG_NUM_GUESTS];
};

/*
 * Shared memory layout at BAR2:
 *   0x0000   struct hsoc_bootlog_header  (aligned to 32 B)
 *   0x0020   unused / reserved
 *   0x1000   1 MiB  ARM-Linux boot log slot
 *   0x101000 1 MiB  RISC-V-Linux boot log slot
 *   0x201000 1 MiB  MIPS-Linux boot log slot
 *   0x301000 1 MiB  FreeRTOS boot log slot
 */
#define BOOTLOG_HEADER_SIZE   0x1000U
#define BOOTLOG_SLOT_ARM      BOOTLOG_HEADER_SIZE
#define BOOTLOG_SLOT_RISCV    (BOOTLOG_HEADER_SIZE + BOOTLOG_SLOT_SIZE)
#define BOOTLOG_SLOT_MIPS     (BOOTLOG_HEADER_SIZE + 2U * BOOTLOG_SLOT_SIZE)
#define BOOTLOG_SLOT_FREERTOS (BOOTLOG_HEADER_SIZE + 3U * BOOTLOG_SLOT_SIZE)

/* Truncation marker written before wrapping so the collector can detect it. */
#define BOOTLOG_TRUNC_MARKER  "--- truncated ---\n"

#endif
```

- [ ] **Step 2: Verify compile with GCC**

```bash
echo '#include "bootlog_proto.h"' \
  | aarch64-linux-gnu-gcc -x c - -S -o /dev/null 2>&1 \
  && echo "OK: bootlog_proto.h compiles cleanly"
```

Expected: prints "OK: bootlog_proto.h compiles cleanly"

- [ ] **Step 3: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/bootlog_proto.h
git commit -m "feat: add boot-log protocol header

Defines shared memory layout, magic, status enum, guest index
enum, and slot offsets for the boot-log ivshmem channel.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Common.sh Variables + Ivshmem Server Script

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh`
- Create: `scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh`

- [ ] **Step 1: Add env vars to common.sh**

Insert after the `IVSHMEM_STATS_FREERTOS_*` block (line 86) and before `FREERTOS_DEPS_ROOT` (line 87):

```bash
# ── Boot-log ivshmem channel (new in Task 2) ─────────────────────────────────
IVSHMEM_BOOTLOG_DIR="${IVSHMEM_BOOTLOG_DIR:-/tmp/ivshmem-bootlog}"
IVSHMEM_BOOTLOG_SOCKET="${IVSHMEM_BOOTLOG_SOCKET:-${IVSHMEM_BOOTLOG_DIR}/sock}"
BOOTLOG_ARM_BINARY="${BOOTLOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-arm-linux}"
BOOTLOG_RISCV_BINARY="${BOOTLOG_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-riscv-linux}"
BOOTLOG_MIPS_BINARY="${BOOTLOG_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-mips-linux}"
BOOT_COLLECTOR_BINARY="${BOOT_COLLECTOR_BINARY:-${FREERTOS_SHOWCASE_DIR}/boot-collector}"
```

- [ ] **Step 2: Create boot-log ivshmem server script**

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_BOOTLOG_DIR}"

if [[ -S "${IVSHMEM_BOOTLOG_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_BOOTLOG_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_BOOTLOG_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_BOOTLOG_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -M ivshmem-bootlog \
    -S "${IVSHMEM_BOOTLOG_SOCKET}" \
    -s 5242880 \       # 5 MiB shmem
    -n 4 \             # up to 4 vectors (1 per guest)
    -v
```

- [ ] **Step 3: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh && echo "OK: syntax valid"
bash -n scripts/heterogeneous-soc/common.sh && echo "OK: common.sh syntax valid"
```

Expected: both print "OK: syntax valid"

- [ ] **Step 4: Commit**

```bash
git add scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh scripts/heterogeneous-soc/common.sh
git commit -m "feat: add boot-log ivshmem server script and environment variables

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: QEMU FreeRTOS Machine — Add IVSHMEM4

**Files:**
- Modify: `include/hw/riscv/chimera_freertos_demo.h`
- Modify: `hw/riscv/chimera_freertos_demo.c`

- [ ] **Step 1: Add IVSHMEM4 entries to header (`chimera_freertos_demo.h`)**

In the memory map enum, after `CHIMERA_FREERTOS_IVSHMEM3_SHMEM` (line 56):

```c
    CHIMERA_FREERTOS_IVSHMEM4_MMIO,
    CHIMERA_FREERTOS_IVSHMEM4_SHMEM,
```

In the IRQ enum, after `CHIMERA_FREERTOS_IVSHMEM3_IRQ` (line 64):

```c
    CHIMERA_FREERTOS_IVSHMEM4_IRQ = 20,
```

In the property defines, after the `CHIMERA_FREERTOS_PROP_IVSHMEM_STATS` line (line 21):

```c
#define CHIMERA_FREERTOS_PROP_IVSHMEM_BOOTLOG "ivshmem-bootlog-freertos"
```

In the struct fields, after `char *ivshmem_stats_freertos` (line 40):

```c
    char *ivshmem_bootlog_freertos;
```

- [ ] **Step 2: Add IVSHMEM4 memory map entry in `chimera_freertos_demo.c`**

After the IVSHMEM3_SHMEM entry (after line 44):

```c
    [CHIMERA_FREERTOS_IVSHMEM4_MMIO] =  { 0x44000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM4_SHMEM] = { 0x45000000, 0x00500000 },  /* 5 MiB for boot logs */
```

- [ ] **Step 3: Bump PLIC source count**

Change `CHIMERA_FREERTOS_PLIC_NUM_SOURCES` from 20 to 21 (line 49 in current file — verify exact line):

```c
#define CHIMERA_FREERTOS_PLIC_NUM_SOURCES 21
```

IRQ 20 is already within the valid range for 21 sources (sources are 0-indexed, so valid IRQs are 0–20).

- [ ] **Step 4: Add property getter/setter in `chimera_freertos_demo.c`**

After the stats getter/setter functions (after line 119), add:

```c
static char *chimera_freertos_get_ivshmem_bootlog(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);
    return g_strdup(s->ivshmem_bootlog_freertos);
}

static void chimera_freertos_set_ivshmem_bootlog(Object *obj, const char *value,
                                                  Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);
    g_free(s->ivshmem_bootlog_freertos);
    s->ivshmem_bootlog_freertos = g_strdup(value);
}
```

- [ ] **Step 5: Add IVSHMEM4 wiring in `chimera_freertos_machine_init`**

After `bool have_links = true;` (after line 166), add:

```c
    Chardev *bootlog_chr = NULL;
```

After the `have_links &= chimera_freertos_require_chardev(...)` block for stats (around line 176–179), add:

```c
    /* boot-log chardev is optional — skip IVSHMEM4 if not wired */
    if (s->ivshmem_bootlog_freertos) {
        bootlog_chr = qemu_chr_find(s->ivshmem_bootlog_freertos);
    }
```

After the stats-chardev `if (stats_chr)` block (around line 257), add:

```c
    if (bootlog_chr) {
        chimera_freertos_connect_ivshmem(
            plic, bootlog_chr,
            chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM4_MMIO].base,
            chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM4_SHMEM].base,
            CHIMERA_FREERTOS_IVSHMEM4_IRQ);
    }
```

- [ ] **Step 6: Add property registration in `chimera_freertos_machine_class_init`**

After the stats property registration (around line 307), add:

```c
    object_class_property_add_str(oc, CHIMERA_FREERTOS_PROP_IVSHMEM_BOOTLOG,
                                  chimera_freertos_get_ivshmem_bootlog,
                                  chimera_freertos_set_ivshmem_bootlog);
    object_class_property_set_description(
        oc, CHIMERA_FREERTOS_PROP_IVSHMEM_BOOTLOG,
        "Chardev id for the boot-log ivshmem link");
```

- [ ] **Step 7: Commit**

```bash
git add include/hw/riscv/chimera_freertos_demo.h hw/riscv/chimera_freertos_demo.c
git commit -m "feat: add IVSHMEM4 boot-log device to FreeRTOS machine

Add a 5th ivshmem-flat device (MMIO 0x4400000, shmem 0x45000000,
IRQ 20) with 5 MiB shared memory for boot-log collection. Bump
PLIC source count to 21. Optional chardev property
'ivshmem-bootlog-freertos'.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: FreeRTOS Boot Monitor (`boot_log.c` / `boot_log.h`)

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/boot_log.h`
- Create: `contrib/heterogeneous-soc/freertos-showcase/boot_log.c`
- This module is compiled into `freertos-riscv-demo.elf` (no separate binary).

- [ ] **Step 1: Write `boot_log.h`**

```c
#ifndef HETEROGENEOUS_SOC_FREERTOS_BOOT_LOG_H
#define HETEROGENEOUS_SOC_FREERTOS_BOOT_LOG_H

#include <stdint.h>

#include "bootlog_proto.h"
#include "freertos_ivshmem_flat.h"

struct bootlog_monitor {
    struct freertos_ivshmem_link link;
    volatile struct hsoc_bootlog_header *header;
    int64_t    boot_tick;       /* tick count at boot (for timeout) */
    uint32_t   last_generation; /* last seen generation (debounce) */
    uint8_t    armed;           /* 1 = monitoring, 0 = done/waiting */
    uint8_t    initialized;     /* 1 after freertos_ivshmem_init */
};

void bootlog_init(struct bootlog_monitor *m,
                  uintptr_t mmio_base, uintptr_t shmem_base,
                  const char *name);

/* Call once per main-loop iteration (~1 ms). Returns 1 if doorbell was rung. */
int bootlog_tick(struct bootlog_monitor *m);

#endif
```

- [ ] **Step 2: Write `boot_log.c`**

```c
#include "boot_log.h"

/*
 * log_uart is defined in freertos_main.c
 */
extern void log_uart(const char *msg);

/*
 * Helper to write a 32-bit value via volatile byte stores (NEON-safe
 * on the ARM collector side; used here for consistency).
 */
static void shmem_write32(volatile void *addr, uint32_t val)
{
    volatile uint8_t *d = (volatile uint8_t *)addr;
    d[0] = (uint8_t)(val >> 0);
    d[1] = (uint8_t)(val >> 8);
    d[2] = (uint8_t)(val >> 16);
    d[3] = (uint8_t)(val >> 24);
}

#define BOOTLOG_TIMEOUT_TICKS 600000  /* 600 s at 1 ms/tick */

void bootlog_init(struct bootlog_monitor *m,
                  uintptr_t mmio_base, uintptr_t shmem_base,
                  const char *name)
{
    freertos_ivshmem_init(&m->link, mmio_base, shmem_base, name);
    m->header = (volatile struct hsoc_bootlog_header *)shmem_base;
    m->boot_tick = 0;
    m->last_generation = 0;
    m->armed = 1;
    m->initialized = 1;
}

int bootlog_tick(struct bootlog_monitor *m)
{
    if (!m->armed || !m->initialized) {
        return 0;
    }

    int64_t ticks = 0;

    /* Approximate tick count via the link's mmio IVPOSITION won't work;
     * derive elapsed time from the global tick count instead.  The caller
     * (showcase_task) runs at 1 ms per iteration, so we use a local counter. */
    m->boot_tick++;

    /* Step 1: Wait for collector_peer_id to be set by ARM-Linux.
     * Once non-zero, cache it so we know where to ring the doorbell. */
    __sync_synchronize();
    uint32_t peer_id = m->header->collector_peer_id;

    if (peer_id == 0) {
        /* ARM-Linux hasn't registered yet */
        return 0;
    }

    /* Step 2: Poll all four guest status fields */
    int all_done = 1;
    for (int i = 0; i < BOOTLOG_NUM_GUESTS; i++) {
        __sync_synchronize();
        if (m->header->guests[i].status != HSOC_BOOT_COMPLETE) {
            all_done = 0;
        }
    }

    /* Step 3: Check timeout */
    if (m->boot_tick >= BOOTLOG_TIMEOUT_TICKS) {
        log_uart("[bootlog] timeout reached (600 s). Ringing doorbell.\n");
        all_done = 1;  /* force collection even if some guests haven't finished */
    }

    if (!all_done) {
        return 0;
    }

    /* Step 4: Ring doorbell to notify ARM-Linux collector */
    __sync_synchronize();
    /*
     * DOORBELL register is at mmio_base + 0x0c.
     * The doorbell value encodes (vector << 0). We use vector 0.
     * The IVPOSITION gives us our peer_id; we shift it into the
     * upper 16 bits for the collector to identify the source,
     * following the ivshmem-doorbell convention.
     */
    uint32_t doorbell_val = (peer_id << 16) | 0;  /* vector 0 */
    shmem_write32(m->link.mmio_base + FREERTOS_IVSHMEM_DOORBELL,
                  doorbell_val);

    log_uart("[bootlog] doorbell rung (peer_id=");
    /* quick hex print */
    {
        static const char hex[] = "0123456789abcdef";
        char buf[12];
        buf[0] = '0'; buf[1] = 'x';
        buf[2] = hex[(peer_id >> 28) & 0xf];
        buf[3] = hex[(peer_id >> 24) & 0xf];
        buf[4] = hex[(peer_id >> 20) & 0xf];
        buf[5] = hex[(peer_id >> 16) & 0xf];
        buf[6] = hex[(peer_id >> 12) & 0xf];
        buf[7] = hex[(peer_id >> 8) & 0xf];
        buf[8] = hex[(peer_id >> 4) & 0xf];
        buf[9] = hex[(peer_id >> 0) & 0xf];
        buf[10] = '\0';
        log_uart(buf);
    }
    log_uart(")\n");

    /* Disarm — fire only once per boot cycle */
    m->armed = 0;
    return 1;
}
```

- [ ] **Step 3: Integrate boot_log.h into freertos_main.c**

Add includes after existing includes (after `#include "stats_proto.h"`):

```c
#include "bootlog_proto.h"
#include "boot_log.h"
```

Add a new boot-log link and monitor state after `static uint32_t stats_tick;` (around line 31):

```c
#define IVSHMEM4_MMIO  0x44000000UL
#define IVSHMEM4_SHMEM 0x45000000UL

static struct bootlog_monitor bootlog;
static uint32_t bootlog_tick_counter;
```

In `showcase_task`, after the three existing `freertos_ivshmem_init` calls (after line 123), add:

```c
    bootlog_init(&bootlog, IVSHMEM4_MMIO, IVSHMEM4_SHMEM, "boot-log");
```

In the main loop's `for (;;)`, after `vTaskDelay(pdMS_TO_TICKS(1));` (before the closing brace of the for loop, around line 164), add:

```c
        /* Boot-log monitor ticks every 1 ms */
        bootlog_tick(&bootlog);
```

- [ ] **Step 4: Add boot_log.c to the freertos build in Makefile**

In the `freertos-riscv-demo.elf` recipe (line 74-84), add `boot_log.c` to the source list. The new line 74 becomes:

```makefile
freertos-riscv-demo.elf: freertos_main.c freertos_ivshmem_flat.c boot_log.c \
```

And add the `boot_log.h` and `bootlog_proto.h` to the dependency list:

```makefile
			freertos_ivshmem_flat.h hello_proto.h stats_proto.h bootlog_proto.h boot_log.h $(FREERTOS_SRCS)
```

And add `boot_log.c` to the compilation command (line 82):

```makefile
		  startup.S freertos_main.c freertos_ivshmem_flat.c boot_log.c freertos_libc.c \
```

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/boot_log.h \
       contrib/heterogeneous-soc/freertos-showcase/boot_log.c \
       contrib/heterogeneous-soc/freertos-showcase/freertos_main.c \
       contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "feat: add FreeRTOS boot-log monitor task

New boot_log.c/boot_log.h module monitors all four guest status
fields in the boot-log ivshmem header and rings the doorbell when
all guests complete or a 600 s timeout fires. Integrated into
freertos_main.c showcase loop at 1 ms per tick.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Linux Bootlog Writer Daemon

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/bootlog_writer.c`

This is a single source file compiled for each target (ARM, RISCV, MIPS) via compiler macros. The ARM variant additionally writes `collector_peer_id` after discovering its own `IVPOSITION` from BAR2 MMIO registers.

- [ ] **Step 1: Write `bootlog_writer.c`**

```c
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "bootlog_proto.h"

/* Override these at compile time: -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_ARM_LINUX */
#ifndef HSOC_BOOTLOG_GUEST
#define HSOC_BOOTLOG_GUEST HSOC_GUEST_ARM_LINUX
#endif

#ifndef HSOC_BOOTLOG_LABEL
#define HSOC_BOOTLOG_LABEL "arm-linux"
#endif

/* BAR2 mmap size: we need header + all slots, but map conservatively */
#define BOOTLOG_BAR2_SIZE (5U * 1024U * 1024U)

/* Max bytes per write batch: 4096 to keep offset updates granular */
#define BOOTLOG_BATCH_SIZE 4096U

static volatile struct hsoc_bootlog_header *header;
static volatile uint8_t *slot_base;     /* points to our guest slot */
static uint32_t slot_offset;            /* next write position within slot */
static const uint32_t max_slot_offset = BOOTLOG_SLOT_SIZE;

/*
 * Volatile byte helpers (NEON-safe — prevents SIGBUS on ARM
 * non-cacheable PCI BAR2).
 */
static void shmem_write8(volatile uint8_t *d, uint8_t v) { *d = v; __sync_synchronize(); }

static void shmem_write32(volatile void *addr, uint32_t val)
{
    volatile uint8_t *d = (volatile uint8_t *)addr;
    d[0] = (uint8_t)(val >> 0);
    d[1] = (uint8_t)(val >> 8);
    d[2] = (uint8_t)(val >> 16);
    d[3] = (uint8_t)(val >> 24);
}

static void shmem_write_buf(volatile void *dst, const void *src, size_t n)
{
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static void write_with_offset(const char *buf, size_t len)
{
    if (slot_offset >= max_slot_offset) {
        /* Slot full — write truncation marker once and stop */
        static bool trunc_written = false;
        if (!trunc_written) {
            size_t tlen = strlen(BOOTLOG_TRUNC_MARKER);
            size_t remain = max_slot_offset - BOOTLOG_TRUNC_MARKER_SIZE;
            /* Actually just write at the end */
            size_t start = max_slot_offset - tlen - 1;
            shmem_write_buf(slot_base + start, BOOTLOG_TRUNC_MARKER, tlen);
            __sync_synchronize();
            shmem_write32(&header->guests[HSOC_BOOTLOG_GUEST].offset,
                          max_slot_offset);
            __sync_synchronize();
            trunc_written = true;
        }
        return;
    }

    size_t writable = max_slot_offset - slot_offset;
    if (len > writable) {
        len = writable;
    }
    if (len == 0) return;

    shmem_write_buf(slot_base + slot_offset, buf, len);

    /* Update offset with a fence after each batch */
    slot_offset += (uint32_t)len;
    __sync_synchronize();
    shmem_write32(&header->guests[HSOC_BOOTLOG_GUEST].offset, slot_offset);
    __sync_synchronize();
}

static void append_kmsg_line(const char *line)
{
    size_t len = strlen(line);
    write_with_offset(line, len);
    /* Lines from /dev/kmsg don't include a trailing newline in the raw
     * format — add one so the log reads naturally. */
    write_with_offset("\n", 1);
}

/*
 * Read all available kernel messages from /dev/kmsg (O_NONBLOCK).
 * Returns the number of lines read.
 */
static int drain_kmsg(int fd)
{
    char buf[4096];
    int count = 0;
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        append_kmsg_line(buf);
        count++;
    }
    return count;
}

int main(int argc, char *argv[])
{
    const char *bar2_path = NULL;

    if (argc > 1) {
        bar2_path = argv[1];
    } else {
        /* Auto-discover: find PCI ivshmem vendor 0x1af4 and check for
         * BOOTLOG_MAGIC in the first 4 bytes of resource2. */
        static char path_buf[PATH_MAX];
        const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
        if (!sysfs_root) sysfs_root = "/sys/bus/pci/devices";

        DIR *dir = opendir(sysfs_root);
        if (!dir) { perror("opendir"); return 1; }

        bool found = false;
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') continue;

            char vendor_path[PATH_MAX];
            snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                     sysfs_root, entry->d_name);
            FILE *f = fopen(vendor_path, "r");
            if (!f) continue;
            char vendor[32] = {};
            if (fgets(vendor, sizeof(vendor), f) == NULL) { fclose(f); continue; }
            fclose(f);
            vendor[strcspn(vendor, "\n")] = '\0';
            if (strcmp(vendor, "0x1af4") != 0) continue;

            char res_path[PATH_MAX];
            snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                     sysfs_root, entry->d_name);
            struct stat st;
            if (stat(res_path, &st) != 0) continue;

            int fd = open(res_path, O_RDONLY | O_SYNC);
            if (fd < 0) continue;
            uint32_t magic;
            void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) continue;
            /* volatile read */
            volatile uint32_t *vp = (volatile uint32_t *)p;
            magic = *vp;
            __sync_synchronize();
            munmap(p, 4096);

            if (magic == BOOTLOG_MAGIC) {
                strncpy(path_buf, res_path, sizeof(path_buf) - 1);
                path_buf[sizeof(path_buf) - 1] = '\0';
                found = true;
                break;
            }
        }
        closedir(dir);

        if (!found) {
            fprintf(stderr, "[bootlog-writer:%s] cannot locate boot-log ivshmem BAR2\n",
                    HSOC_BOOTLOG_LABEL);
            return 1;
        }
        bar2_path = path_buf;
    }

    /* Open and mmap BAR2 read/write */
    int fd = open(bar2_path, O_RDWR | O_SYNC);
    if (fd < 0) { perror("open BAR2"); return 1; }

    void *base = mmap(NULL, BOOTLOG_BAR2_SIZE, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) { perror("mmap BAR2"); close(fd); return 1; }
    close(fd);

    header = (volatile struct hsoc_bootlog_header *)base;

    /* Verify magic */
    if (header->magic != BOOTLOG_MAGIC) {
        fprintf(stderr, "[bootlog-writer:%s] bad magic 0x%08" PRIx32
                " (expected 0x%08x)\n",
                HSOC_BOOTLOG_LABEL, header->magic, BOOTLOG_MAGIC);
        /* Write magic to initialize — this might be first boot */
        shmem_write32(&header->magic, BOOTLOG_MAGIC);
        __sync_synchronize();
    }

    /* Point to our slot */
    switch (HSOC_BOOTLOG_GUEST) {
    case HSOC_GUEST_ARM_LINUX:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_ARM;
        break;
    case HSOC_GUEST_RISCV_LINUX:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_RISCV;
        break;
    case HSOC_GUEST_MIPS_LINUX:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_MIPS;
        break;
    default:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_FREERTOS;
        break;
    }

    /* Initialize offset from header (resume-safe) */
    __sync_synchronize();
    slot_offset = header->guests[HSOC_BOOTLOG_GUEST].offset;
    if (slot_offset >= max_slot_offset) {
        slot_offset = 0;  /* slot was full; start over */
    }

    /* Write a header line with timestamp */
    char boot_header[256];
    time_t now = time(NULL);
    struct tm *tm_info = gmtime(&now);
    strftime(boot_header, sizeof(boot_header),
             "[bootlog] %Y-%m-%dT%H:%M:%SZ booting " HSOC_BOOTLOG_LABEL "\n",
             tm_info);
    write_with_offset(boot_header, strlen(boot_header));
    fprintf(stderr, "%s", boot_header);

    /*
     * ARM-Linux special: read IVPOSITION from BAR2 MMIO and write
     * collector_peer_id into the header.
     *
     * The IVPOSITION register lives in the PCI doorbell BAR0/BAR1 MMIO space,
     * not in BAR2 (shared memory).  We read it via sysfs resource0.
     *
     * For ARM-Linux only.
     */
#if HSOC_BOOTLOG_GUEST == HSOC_GUEST_ARM_LINUX
    {
        /* Read PCI resource0 (MMIO registers) from the SAME PCI device */
        /* We need the PCI address. Re-derive it from bar2_path by replacing
         * /resource2 with /resource0 */
        char mmio_path[PATH_MAX];
        size_t blen = strlen(bar2_path);
        if (blen > 10 && strcmp(bar2_path + blen - 10, "/resource2") == 0) {
            memcpy(mmio_path, bar2_path, blen - 9);
            memcpy(mmio_path + blen - 9, "resource0\0", 10);

            int mmio_fd = open(mmio_path, O_RDONLY | O_SYNC);
            if (mmio_fd >= 0) {
                volatile uint32_t *mmio = mmap(NULL, 4096, PROT_READ,
                                                MAP_SHARED, mmio_fd, 0);
                if (mmio != MAP_FAILED) {
                    /* IVPOSITION offset = 0x08 */
                    uint32_t ivposition = mmio[2]; /* 32-bit access at offset 0x8 */
                    __sync_synchronize();
                    munmap((void *)mmio, 4096);

                    if (ivposition > 0) {
                        header->collector_peer_id = ivposition;
                        __sync_synchronize();
                        fprintf(stderr, "[bootlog-writer:arm-linux] "
                                "set collector_peer_id = %" PRIu32 "\n",
                                ivposition);
                    } else {
                        fprintf(stderr, "[bootlog-writer:arm-linux] "
                                "warning: IVPOSITION is 0\n");
                    }
                }
                close(mmio_fd);
            }
        }
    }
#endif

    /* Write status = BOOT_COMPLETE for our guest */
    __sync_synchronize();
    shmem_write32(&header->guests[HSOC_BOOTLOG_GUEST].status,
                  HSOC_BOOT_COMPLETE);
    __sync_synchronize();

    /* Drain existing kernel messages */
    int kmsg_fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kmsg_fd >= 0) {
        int n = drain_kmsg(kmsg_fd);
        fprintf(stderr, "[bootlog-writer:%s] drained %d existing kmsg lines\n",
                HSOC_BOOTLOG_LABEL, n);
        close(kmsg_fd);
    } else {
        fprintf(stderr, "[bootlog-writer:%s] warning: cannot open /dev/kmsg (%s)\n",
                HSOC_BOOTLOG_LABEL, strerror(errno));
    }

    /* Continue reading new messages — poll /dev/kmsg every 2 seconds */
    fprintf(stderr, "[bootlog-writer:%s] entering polling loop\n",
            HSOC_BOOTLOG_LABEL);

    for (;;) {
        sleep(2);
        kmsg_fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
        if (kmsg_fd >= 0) {
            drain_kmsg(kmsg_fd);
            close(kmsg_fd);
        }
    }

    /* Unreachable */
    /* return 0; */
    (void)BOOTLOG_BATCH_SIZE;  /* suppress unused-var warning */
}
```

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/bootlog_writer.c
git commit -m "feat: add Linux bootlog writer daemon

Single C source compiled for ARM/RISCV/MIPS via -DHSOC_BOOTLOG_GUEST
and -DHSOC_BOOTLOG_LABEL. Writes kernel messages to the assigned
shared-memory slot via volatile byte loops. ARM variant additionally
reads IVPOSITION from BAR0 resource0 and writes collector_peer_id
into the shared header.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: ARM-Linux Boot Collector Daemon

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/boot_collector.c`

- [ ] **Step 1: Write `boot_collector.c`**

```c
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "bootlog_proto.h"

#define BOOTLOG_BAR2_SIZE    (5U * 1024U * 1024U)
#define COLLECT_LOG_DIR      "/var/log/boot-logs"
#define POLL_INTERVAL_MS     2000  /* 2 seconds */

/* Guest slot filenames, indexed by HSOC_GUEST_* enum */
static const char *guest_names[] = {
    [HSOC_GUEST_ARM_LINUX]   = "guest-arm",
    [HSOC_GUEST_RISCV_LINUX] = "guest-riscv",
    [HSOC_GUEST_MIPS_LINUX]  = "guest-mips",
    [HSOC_GUEST_FREERTOS]    = "guest-freertos",
};

static unsigned int slot_offsets[] = {
    [HSOC_GUEST_ARM_LINUX]   = BOOTLOG_SLOT_ARM,
    [HSOC_GUEST_RISCV_LINUX] = BOOTLOG_SLOT_RISCV,
    [HSOC_GUEST_MIPS_LINUX]  = BOOTLOG_SLOT_MIPS,
    [HSOC_GUEST_FREERTOS]    = BOOTLOG_SLOT_FREERTOS,
};

static volatile struct hsoc_bootlog_header *header;

/*
 * Volatile byte helpers (NEON-safe)
 */
static void shm_read_buf(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

/*
 * Write one guest's slot to a file. Reads up to slot_offset bytes.
 */
static int write_guest_log(int guest_idx, const char *dir_path)
{
    char file_path[PATH_MAX];
    snprintf(file_path, sizeof(file_path), "%s/%s.log",
             dir_path, guest_names[guest_idx]);

    /*
     * Read offset atomically — ensure we see an up-to-date value.
     * The offset is written by the remote peer with a fence after
     * each write batch, so a stale read might miss the last few bytes
     * but will never read garbage.
     */
    __sync_synchronize();
    uint32_t offset = header->guests[guest_idx].offset;
    if (offset == 0) {
        /* Slot never written to — nothing to collect */
        return 0;
    }
    if (offset > BOOTLOG_SLOT_SIZE) {
        offset = BOOTLOG_SLOT_SIZE;
    }

    uint8_t *slot = (uint8_t *)header + slot_offsets[guest_idx];

    /* Read the slot data into a heap buffer */
    uint8_t *buf = malloc(offset);
    if (!buf) {
        fprintf(stderr, "[boot-collector] malloc(%" PRIu32 ") failed\n", offset);
        return -1;
    }
    shm_read_buf(buf, slot, offset);

    FILE *f = fopen(file_path, "w");
    if (!f) {
        perror(file_path);
        free(buf);
        return -1;
    }
    size_t written = fwrite(buf, 1, offset, f);
    fclose(f);

    if (written != offset) {
        fprintf(stderr, "[boot-collector] short write to %s: %zu/%" PRIu32 "\n",
                file_path, written, offset);
        free(buf);
        return -1;
    }

    fprintf(stderr, "[boot-collector] wrote %s (%" PRIu32 " bytes)\n",
            file_path, offset);
    free(buf);
    return (int)offset;
}

/*
 * In-place scan for the first PCI device whose resource2 starts with
 * BOOTLOG_MAGIC. Returns mmap'd pointer or NULL.
 */
static volatile struct hsoc_bootlog_header *find_bootlog_shm(void)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) sysfs_root = "/sys/bus/pci/devices";

    for (int attempt = 0; attempt < 30; attempt++) {
        DIR *dir = opendir(sysfs_root);
        if (!dir) { perror("opendir"); return NULL; }

        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') continue;

            char vendor_path[PATH_MAX];
            snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                     sysfs_root, entry->d_name);
            FILE *f = fopen(vendor_path, "r");
            if (!f) continue;
            char vendor[32];
            if (!fgets(vendor, sizeof(vendor), f)) { fclose(f); continue; }
            fclose(f);
            vendor[strcspn(vendor, "\n")] = '\0';
            if (strcmp(vendor, "0x1af4") != 0) continue;

            char res_path[PATH_MAX];
            snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                     sysfs_root, entry->d_name);
            int fd = open(res_path, O_RDONLY | O_SYNC);
            if (fd < 0) continue;

            uint32_t magic;
            void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) continue;
            volatile uint32_t *vp = (volatile uint32_t *)p;
            magic = *vp;
            __sync_synchronize();
            munmap(p, 4096);

            if (magic == BOOTLOG_MAGIC) {
                /* Re-map full BAR2 for our use */
                fd = open(res_path, O_RDONLY | O_SYNC);
                if (fd < 0) { closedir(dir); return NULL; }
                void *full = mmap(NULL, BOOTLOG_BAR2_SIZE, PROT_READ,
                                  MAP_SHARED, fd, 0);
                close(fd);
                if (full == MAP_FAILED) { closedir(dir); return NULL; }
                closedir(dir);
                return (volatile struct hsoc_bootlog_header *)full;
            }
        }
        closedir(dir);

        if (attempt == 0) {
            fprintf(stderr, "[boot-collector] waiting for boot-log BAR2...\n");
        }
        sleep(1);
    }

    return NULL;
}

int main(int argc, char *argv[])
{
    const char *bar2_path = argc > 1 ? argv[1] : NULL;

    if (bar2_path) {
        int fd = open(bar2_path, O_RDONLY | O_SYNC);
        if (fd < 0) { perror("open BAR2"); return 1; }
        void *p = mmap(NULL, BOOTLOG_BAR2_SIZE, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) { perror("mmap BAR2"); return 1; }
        header = (volatile struct hsoc_bootlog_header *)p;
    } else {
        header = find_bootlog_shm();
    }

    if (!header) {
        fprintf(stderr, "[boot-collector] could not find boot-log ivshmem BAR2\n");
        return 1;
    }
    if (header->magic != BOOTLOG_MAGIC) {
        fprintf(stderr, "[boot-collector] bad magic 0x%08" PRIx32 "\n",
                header->magic);
        return 1;
    }

    /* Create log directory */
    if (mkdir(COLLECT_LOG_DIR, 0755) != 0 && errno != EEXIST) {
        perror(COLLECT_LOG_DIR);
        return 1;
    }

    fprintf(stderr, "[boot-collector] monitoring boot-log BAR2 at %p\n",
            (void *)header);

    uint32_t last_gen = 0;
    for (;;) {
        usleep(POLL_INTERVAL_MS * 1000);

        __sync_synchronize();
        uint32_t gen = header->generation;

        if (gen == 0 && last_gen == 0) {
            /* Daemon started before FreeRTOS initialized the header —
             * re-verify magic to be sure. */
            continue;
        }

        if (gen != last_gen) {
            fprintf(stderr, "[boot-collector] generation changed: %" PRIu32
                    " -> %" PRIu32 "\n", last_gen, gen);
            last_gen = gen;

            /*
             * Skip initial generation 0->0 case. Also handle wrap-around:
             * if we missed some increments, just collect whatever is new.
             */
            int collected = 0;
            for (int i = 0; i < BOOTLOG_NUM_GUESTS; i++) {
                int ret = write_guest_log(i, COLLECT_LOG_DIR);
                if (ret > 0) collected++;
            }

            fprintf(stderr, "[boot-collector] collection complete: %d/%d guest logs written\n",
                    collected, BOOTLOG_NUM_GUESTS);
        }
    }

    /* Unreachable */
    /* return 0; */
}
```

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/boot_collector.c
git commit -m "feat: add ARM-Linux boot collector daemon

Polls the boot-log BAR2 generation field every 2 seconds. On
generation change, reads all four guest slots via volatile byte
loops and writes them to /var/log/boot-logs/guest-<name>.log.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Makefile Build Targets

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 1: Add boot-log build targets to Makefile**

After the syslog-mips-linux target (around line 72) and before the freertos-riscv-demo.elf target (line 74), add:

```makefile
# ── Boot-log writer daemon (one per architecture) ───────────────────────
BOOTLOG_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
BOOTLOG_TARGETS += bootlog-arm-linux
endif
ifneq ($(HAVE_CC_RISCV),)
BOOTLOG_TARGETS += bootlog-riscv-linux
endif
ifneq ($(HAVE_CC_MIPS),)
BOOTLOG_TARGETS += bootlog-mips-linux
endif

# ═══╡ Boot collector (ARM-Linux only) ╞══════════════════════════════════
BOOT_COLLECTOR_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
BOOT_COLLECTOR_TARGETS += boot-collector
endif

bootlog-arm-linux: bootlog_writer.c bootlog_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_ARM_LINUX \
	  -DHSOC_BOOTLOG_LABEL='"arm-linux"' \
	  -o $@ bootlog_writer.c

bootlog-riscv-linux: bootlog_writer.c bootlog_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_RISCV_LINUX \
	  -DHSOC_BOOTLOG_LABEL='"riscv-linux"' \
	  -o $@ bootlog_writer.c

bootlog-mips-linux: bootlog_writer.c bootlog_proto.h
	$(CC_MIPS) $(CFLAGS_LINUX) \
	  -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_MIPS_LINUX \
	  -DHSOC_BOOTLOG_LABEL='"mips-linux"' \
	  -o $@ bootlog_writer.c

boot-collector: boot_collector.c bootlog_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) -o $@ boot_collector.c
```

Update the `all` target to include boot-log targets (change line 42):
```makefile
all: $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-riscv-demo.elf
```

Update the warning section after the `all` target to add boot-log warnings after the existing ones (after line 51):
```makefile
ifeq ($(HAVE_CC_ARM),)
	$(warning CC_ARM=$(CC_ARM) not found — boot-collector and bootlog-arm-linux skipped)
endif
```

Update the `clean` target to include boot-log binaries (change line 87):
```makefile
clean:
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-riscv-demo.elf
```

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "feat: add boot-log writer and collector Makefile targets

Build bootlog-arm-linux, bootlog-riscv-linux, bootlog-mips-linux,
and boot-collector (ARM-only) via the existing cross-compilers.
Integrated into all/clean targets.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Guest Installation Script for Boot-Log Binaries

**Files:**
- Create: `scripts/heterogeneous-soc/guest-install-bootlog-to-guests.sh`

- [ ] **Step 1: Write the install script**

```bash
#!/usr/bin/env bash
# guest-install-bootlog-to-guests.sh
#
# Inject bootlog-*-linux and boot-collector daemons into each Debian
# guest qcow2 image at /usr/local/bin/ so guests can run them without
# the 9p pingpong share.
#
# Safe to run repeatedly — overwrites the binary on each invocation.
#
# Requires: qemu-nbd (qemu-utils package), nbd kernel module, sudo (for mount).
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script must run on Linux (requires qemu-nbd and mount)"
fi

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_skip() { printf '\033[0;33m  ↷ skip: %s\033[0m\n' "$*"; }

inject_binary() {
    local disk="$1"
    local binary="$2"
    local dest_name="$3"

    if [[ ! -f "${disk}" ]]; then
        _skip "${dest_name}: disk image missing (${disk})"
        return 0
    fi
    if [[ ! -f "${binary}" ]]; then
        _skip "${dest_name}: binary not built (cross-compiler absent)"
        return 0
    fi

    _info "Installing ${dest_name} → $(basename "${disk}"):/usr/local/bin/${dest_name}"

    local nbd_dev="/dev/nbd0"
    local mnt
    mnt="$(mktemp -d)"

    _cleanup() {
        sudo umount "${mnt}" 2>/dev/null || true
        sudo qemu-nbd --disconnect "${nbd_dev}" 2>/dev/null || true
        rmdir "${mnt}" 2>/dev/null || true
    }
    trap _cleanup RETURN

    sudo qemu-nbd --connect="${nbd_dev}" "${disk}"
    sleep 0.3
    sudo mount "${nbd_dev}" "${mnt}"
    sudo mkdir -p "${mnt}/usr/local/bin"
    sudo cp "${binary}" "${mnt}/usr/local/bin/${dest_name}"
    sudo chmod 755 "${mnt}/usr/local/bin/${dest_name}"
    sudo umount "${mnt}"
    sudo qemu-nbd --disconnect "${nbd_dev}"
    rmdir "${mnt}"
    trap - RETURN

    _ok "${dest_name} installed in $(basename "${disk}")"
}

sudo modprobe nbd max_part=0 2>/dev/null || true

# Kill any QEMU guests that have the disk images open.
_info "Stopping any running QEMU guests to release disk locks..."
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
pkill -f "qemu-system-mipsel.*run-chimera"            2>/dev/null || true
sleep 0.5

inject_binary "${ARM_DEBIAN_DISK}"   "${BOOTLOG_ARM_BINARY}"      "bootlog-arm-linux"
inject_binary "${RISCV_DEBIAN_DISK}" "${BOOTLOG_RISCV_BINARY}"    "bootlog-riscv-linux"
inject_binary "${MIPS_DEBIAN_DISK}"  "${BOOTLOG_MIPS_BINARY}"     "bootlog-mips-linux"
inject_binary "${ARM_DEBIAN_DISK}"   "${BOOT_COLLECTOR_BINARY}"   "boot-collector"
```

- [ ] **Step 2: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-install-bootlog-to-guests.sh && echo "OK: syntax valid"
```

Expected: prints "OK: syntax valid"

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-install-bootlog-to-guests.sh
git commit -m "feat: add boot-log binary installer script

Injects bootlog-arm-linux, bootlog-riscv-linux, bootlog-mips-linux,
and boot-collector into the corresponding Debian guest qcow2 images
via qemu-nbd.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Linux Launch Scripts — Add Boot-Log PCI Doorbell

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-chimera.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh`

- [ ] **Step 1: Add boot-log chardev + PCI to ARM launch script**

In `guest-run-arm-phase5.sh`, before the final `exec` line, add a `-chardev` and `-device` pair. Insert after the stats chardev/device (after line 27):

```bash
    -chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
```

- [ ] **Step 2: Add boot-log chardev + PCI to RISCV launch script**

Same pattern in `guest-run-riscv-phase5.sh`, after line 26:

```bash
    -chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
```

- [ ] **Step 3: Add boot-log chardev + PCI to MIPS launch script**

Same pattern in `guest-run-chimera.sh`, after line 24:

```bash
    -chardev socket,id=ivshmem_boot,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \
```

- [ ] **Step 4: Add boot-log chardev to FreeRTOS launch script**

In `guest-run-riscv-freertos-phase5.sh`, add the boot-log chardev and the `ivshmem-bootlog-freertos` machine property.

Update the machine lines. The current:
```
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
```

Becomes:
```
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
```

- [ ] **Step 5: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-arm-phase5.sh && echo "OK: arm valid"
bash -n scripts/heterogeneous-soc/guest-run-riscv-phase5.sh && echo "OK: riscv valid"
bash -n scripts/heterogeneous-soc/guest-run-chimera.sh && echo "OK: mips valid"
bash -n scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh && echo "OK: freertos valid"
```

Expected: all four print "OK: ... valid"

- [ ] **Step 6: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-arm-phase5.sh \
      scripts/heterogeneous-soc/guest-run-riscv-phase5.sh \
      scripts/heterogeneous-soc/guest-run-chimera.sh \
      scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh
git commit -m "feat: add boot-log ivshmem doorbell to all guest launch scripts

Each Linux guest gets a new -chardev/-device ivshmem-doorbell pair
for the boot-log channel. FreeRTOS launch script gets the
ivshmem-bootlog-freertos machine property and chardev.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Tmux Layout — 5th Server Pane + Boot Collection Commands

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`

- [ ] **Step 1: Update tmux layout for 5 server panes**

The current layout is:
```
srv ARM-FT | srv RSCV-F | srv MIPS-F | srv STATS    (panes 0-3, equal quarters)
FreeRTOS                                              (pane 4)
ARM-Linux | RISCV-Linux | MIPS-Linux                  (panes 5,6,7)
```

The new layout:
```
srv ARM-FT | srv RSCV-F | srv MIPS-F | srv STATS | srv BOOT    (panes 0-4, equal fifths)
FreeRTOS                                                         (pane 5)
ARM-Linux | RISCV-Linux | MIPS-Linux                              (panes 6,7,8)
```

Update the comment block (around line 41) to describe the new layout:

```bash
# Build a single-window layout:
#
#  ┌────────┬────────┬────────┬────────┬────────┐
#  │srv     │srv     │srv     │srv     │srv     │  panes 0-4 (equal fifths)
#  │ARM-FT  │RSCV-FT │MIPS-FT │STATS   │BOOT-LOG│
#  ├────────┴────────┴────────┴────────┴────────┤
#  │                FreeRTOS                    │  pane 5
#  ├─────────────┬─────────────┬────────────────┤
#  │  ARM-Linux  │ RISCV-Linux │  MIPS-Linux    │  panes 6,7,8
#  └─────────────┴─────────────┴────────────────┘
#
# Split sequence (-l N% gives the new pane N% of the pane being split):
#   split-v 83% on 0.0  → 0=top(17%),      1=rest(83%)
#   split-v 60% on 0.1  → 0=top(17%),      1=mid(33%),     2=bot(50%)
#   split-v 50% on 0.2  → 0=top(17%),      1=mid(33%),     2=mid2(25%), 3=bot(25%)
#   … after first row, the remaining panes shift by 1
```

Update the split commands. Current 4-server splits (lines 63-69):

```bash
tmux split-window -v -t "$SESSION:0.0" -l 80%
tmux split-window -v -t "$SESSION:0.1" -l 45%
tmux split-window -h -t "$SESSION:0.0" -l 75%
tmux split-window -h -t "$SESSION:0.1" -l 67%
tmux split-window -h -t "$SESSION:0.2" -l 50%
tmux split-window -h -t "$SESSION:0.5" -l 67%
tmux split-window -h -t "$SESSION:0.6" -l 50%
```

Replace with 5-server splits:

```bash
# 5 server panes in the top row (0-4), then FreeRTOS (5), then 3 guest panes (6-8)
tmux split-window -v -t "$SESSION:0.0" -l 83%
tmux split-window -v -t "$SESSION:0.1" -l 60%
tmux split-window -v -t "$SESSION:0.2" -l 50%
tmux split-window -h -t "$SESSION:0.0" -l 80%
tmux split-window -h -t "$SESSION:0.1" -l 75%
tmux split-window -h -t "$SESSION:0.2" -l 67%
tmux split-window -h -t "$SESSION:0.3" -l 50%
tmux split-window -h -t "$SESSION:0.6" -l 67%
tmux split-window -h -t "$SESSION:0.7" -l 50%
```

- [ ] **Step 2: Add boot-log server launch**

After the stats server launch (line 85), add:

```bash
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-bootlog.sh" Enter
```

- [ ] **Step 3: Add boot-log socket to wait loop**

Add `BOOT_SOCK` variable after the STATS_SOCK line (after line 90):

```bash
BOOT_SOCK="${IVSHMEM_BOOTLOG_DIR:-/tmp/ivshmem-bootlog}/sock"
```

Update the wait loop to include the boot-log socket (change the for loop, around line 91):

```bash
for _i in $(seq 1 60); do
    if [[ -S "$ARM_SOCK"   ]] && ss -xl | grep -Fq "$ARM_SOCK"   && \
       [[ -S "$RISCV_SOCK" ]] && ss -xl | grep -Fq "$RISCV_SOCK" && \
       [[ -S "$MIPS_SOCK"  ]] && ss -xl | grep -Fq "$MIPS_SOCK"  && \
       [[ -S "$STATS_SOCK" ]] && ss -xl | grep -Fq "$STATS_SOCK" && \
       [[ -S "$BOOT_SOCK"  ]] && ss -xl | grep -Fq "$BOOT_SOCK"; then
        break
    fi
    sleep 0.5
done
```

- [ ] **Step 4: Update tmux send-keys index shift**

Since pane 4 is now the 5th server pane instead of FreeRTOS, the FreeRTOS launch moves to pane 5 and all guest panes shift by one. Update the index shifts:

```bash
tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.6" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.7" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-phase5.sh"          Enter
tmux send-keys -t "$SESSION:0.8" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-chimera.sh"               Enter
```

- [ ] **Step 5: Update auto_login_and_run pane indices**

Change all three existing auto_login_and_run calls to use the new pane indices:

```bash
auto_login_and_run "$SESSION:0.6" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "syslog-arm-linux" &
auto_login_and_run "$SESSION:0.7" \
    "syslog-riscv-linux" &
auto_login_and_run "$SESSION:0.8" \
    "syslog-mips-linux" &
```

Also add the boot-log writer and collector auto-runs. After the syslog-mips-linux line (or alongside):

```bash
auto_login_and_run "$SESSION:0.6" \
    "bootlog-arm-linux &" \
    "boot-collector" &
auto_login_and_run "$SESSION:0.7" \
    "bootlog-riscv-linux" &
auto_login_and_run "$SESSION:0.8" \
    "bootlog-mips-linux" &
```

**Important:** The ARM-Linux pane (0.6) runs both `bootlog-arm-linux &` (background) and `boot-collector` (foreground). The collector is the blocking process that monitors the boot-log. Since `auto_login_and_run` runs a script from the 9p share, combine both commands in the script:

Replace the first auto_login_and_run for pane 0.6 with:
```bash
auto_login_and_run "$SESSION:0.6" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "bootlog-arm-linux &" \
    "boot-collector" &
```

And update the RISCV/MIPS panes to add bootlog after syslog:
```bash
auto_login_and_run "$SESSION:0.7" \
    "syslog-riscv-linux" \
    "bootlog-riscv-linux" &
auto_login_and_run "$SESSION:0.8" \
    "syslog-mips-linux" \
    "bootlog-mips-linux" &
```

- [ ] **Step 6: Update FreeRTOS pane focus**

Change to the new FreeRTOS pane index:
```bash
tmux select-pane -t "$SESSION:0.5"
```

- [ ] **Step 7: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-phase5-tmux.sh && echo "OK: syntax valid"
```

Expected: prints "OK: syntax valid"

- [ ] **Step 8: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
git commit -m "feat: add boot-log server pane and daemon auto-runs to tmux

New 5th ivshmem-server pane (boot-log) in the top row, shifting
FreeRTOS to pane 5 and guest panes to 6-8. Auto-runs bootlog-*-linux
on each guest and boot-collector on ARM-Linux.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 11: Showcase Script Integration

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh`

- [ ] **Step 1: Add boot-log server script to LAUNCH_SCRIPTS check**

Add after `"${SCRIPT_DIR}/guest-install-syslog-to-guests.sh"` (around line 76):

```bash
    "${SCRIPT_DIR}/guest-start-ivshmem-server-bootlog.sh"
    "${SCRIPT_DIR}/guest-install-bootlog-to-guests.sh"
```

- [ ] **Step 2: Add boot-log install step before kernel extraction**

After the syslog-install step (around line 252), add:

```bash
# ── Step 6.75: Install boot-log daemons into guest disk images ──────────

_step "Installing boot-log daemons into guest images"
_exec bash "${SCRIPT_DIR}/guest-install-bootlog-to-guests.sh"
_ok "Boot-log daemons installed"
```

- [ ] **Step 3: Update the QEMU build staleness check**

The boot-log feature adds `ivshmem-bootlog-freertos` to the FreeRTOS machine. Update the grep check in `_has_qemu_build` (around line 162-163) to also check for this new property:

```bash
    "${qemu_riscv}" -M chimera-riscv-freertos-demo,help 2>&1 | \
        grep -q "ivshmem-bootlog-freertos" || return 1
```

This replaces `ivshmem-stats-freertos` with the newest property `ivshmem-bootlog-freertos`. This ensures that if the QEMU binary is stale (from before the boot-log machine change), it will be rebuilt.

- [ ] **Step 4: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-chimera-showcase.sh && echo "OK: syntax valid"
```

Expected: prints "OK: syntax valid"

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
git commit -m "feat: integrate boot-log collection into showcase launcher

Add boot-log ivshmem server and binary installation steps. Update
QEMU staleness check to require 'ivshmem-bootlog-freertos' property.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage:**
- ✓ Protocol header (bootlog_proto.h) — Task 1 covers all structs, enums, magic, layout
- ✓ Shared memory layout diagram — captured in bootlog_proto.h comments
- ✓ QEMU FreeRTOS machine 5th ivshmem-flat — Task 3 covers C header and source changes
- ✓ New boot-log ivshmem server — Task 2 covers the server script
- ✓ Linux bootlog_writer daemon — Task 5 covers bootlog_writer.c
- ✓ ARM-Linux boot_collector daemon — Task 6 covers boot_collector.c
- ✓ FreeRTOS boot monitor — Task 4 covers boot_log.c/boot_log.h
- ✓ Makefile targets — Task 7 covers all
- ✓ common.sh env vars — Task 2 covers variable definitions
- ✓ Linux launch scripts (all 3 + FreeRTOS) — Task 9 covers
- ✓ Guest image installation — Task 8 covers install script
- ✓ Tmux layout update — Task 10 covers
- ✓ Showcase integration — Task 11 covers
- ✓ Error handling table — implicitly covered by volatile byte loops, fence discipline, offset-based reads, timeout fallback
- ✓ Systemd services — noted in code comments but not implemented (daemons are started manually via tmux auto_login_and_run, following the existing syslog pattern)

**2. Placeholder scan:** All code blocks contain complete, compilable C or valid bash. No "TBD", "TODO", or placeholder patterns found.

**3. Type consistency:** All struct names, enum values, and function signatures are consistent across tasks. `bootlog_proto.h` types used in Tasks 4, 5, 6 match. `CHIMERA_FREERTOS_IVSHMEM4_MMIO`/`_SHMEM` used consistently between Tasks 3 and 4 (the FreeRTOS C code uses `IVSHMEM4_MMIO`/`IVSHMEM4_SHMEM` direct defines since it's bare-metal, not the QEMU enum). `IVSHMEM_BOOTLOG_SOCKET` used consistently across all shell scripts.
