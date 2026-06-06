# FreeRTOS Stats Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 4th ivshmem stats channel so FreeRTOS periodically pushes per-channel message-count snapshots to ARM-Linux, which appends them to `/tmp/freertos-stats.log`.

**Architecture:** FreeRTOS accumulates HELLO counts for all three Linux channels and writes a `hsoc_stats_snapshot` every 5 s (5000 1-ms ticks) into a new `ivshmem-flat` device (IVSHMEM3) at MMIO `0x3F000000` / SHMEM `0x40000000`. ARM-Linux runs a new `linux-arm-stats` binary that polls the corresponding PCI `ivshmem-doorbell` BAR2 every 2 s and logs each new snapshot. A generation counter (monotonic `uint32_t`) signals new data — no handshake needed.

**Tech Stack:** C99 (bare-metal FreeRTOS + Linux userspace), QEMU sysbus/PCI ivshmem, ivshmem-server, bash scripts, tmux 3.4+.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `contrib/heterogeneous-soc/freertos-showcase/stats_proto.h` | **Create** | Shared memory struct `hsoc_stats_snapshot` |
| `contrib/heterogeneous-soc/freertos-showcase/linux_stats.c` | **Create** | ARM-Linux poll-and-log binary |
| `scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh` | **Create** | Launch stats ivshmem-server |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | **Modify** | Count per-channel HELLOs; write stats snapshot every 5 s |
| `contrib/heterogeneous-soc/freertos-showcase/Makefile` | **Modify** | Add `linux-arm-stats` target; add `stats_proto.h` dep |
| `include/hw/riscv/chimera_freertos_demo.h` | **Modify** | IVSHMEM3 memmap enum, IRQ 19, property name, machine state field |
| `hw/riscv/chimera_freertos_demo.c` | **Modify** | IVSHMEM3 memmap entries, property handlers, 4th connect call; bump PLIC sources to 20 |
| `scripts/heterogeneous-soc/common.sh` | **Modify** | `IVSHMEM_STATS_FREERTOS_DIR/SOCKET` defaults; `LINUX_ARM_STATS_BINARY` |
| `scripts/heterogeneous-soc/guest-run-arm-phase5.sh` | **Modify** | Add 2nd `ivshmem-doorbell` for stats channel |
| `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh` | **Modify** | Add `ivshmem-stats-freertos=statsft` machine property |
| `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` | **Modify** | Add 4th server pane; poll stats socket; launch `linux-arm-stats` on ARM |

---

## Task 1: Create `stats_proto.h`

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/stats_proto.h`

- [ ] **Step 1: Create the file**

```c
#ifndef HETEROGENEOUS_SOC_STATS_PROTO_H
#define HETEROGENEOUS_SOC_STATS_PROTO_H

#include <stdint.h>

#define HSOC_STATS_MAGIC 0x53544154U  /* "STAT" */

/*
 * Written exclusively by FreeRTOS into IVSHMEM3 shmem.
 * ARM-Linux polls generation to detect new snapshots.
 *
 * Write protocol (FreeRTOS):
 *   1. Write all payload fields via direct volatile store (one field at a time).
 *   2. __sync_synchronize()
 *   3. generation = generation + 1  (volatile store + fence)
 *   magic is written once at init and never changes.
 *
 * Read protocol (ARM-Linux):
 *   1. shm_read the whole struct into a local copy.
 *   2. __sync_synchronize()
 *   3. Skip if local.generation == last_seen_generation.
 *   4. Verify local.magic == HSOC_STATS_MAGIC.
 */
struct hsoc_stats_snapshot {
    uint32_t          magic;       /* HSOC_STATS_MAGIC — identifies this BAR2 */
    volatile uint32_t generation;  /* monotonically incremented by FreeRTOS */
    uint32_t          arm_count;   /* total HELLOs received from ARM-Linux */
    uint32_t          riscv_count; /* total HELLOs received from RISCV-Linux */
    uint32_t          mips_count;  /* total HELLOs received from MIPS-Linux */
    uint32_t          pad;
    int64_t           tick_sec;    /* FreeRTOS tick time of this snapshot */
    int64_t           tick_nsec;
};

#endif
```

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/stats_proto.h
git commit -m "feat: add stats_proto.h shared memory layout for FreeRTOS stats channel"
```

---

## Task 2: Extend `chimera_freertos_demo.h`

**Files:**
- Modify: `include/hw/riscv/chimera_freertos_demo.h`

- [ ] **Step 1: Add IVSHMEM3 entries to the memmap enum, IRQ, and property name**

Replace the existing `enum` and IRQ `enum` blocks with:

```c
#define CHIMERA_FREERTOS_PROP_IVSHMEM_ARM   "ivshmem-arm-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_RISCV "ivshmem-riscv-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS  "ivshmem-mips-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_STATS "ivshmem-stats-freertos"

#define CHIMERA_FREERTOS_IVSHMEM_SIZE (64U * 1024U * 1024U)

typedef struct ChimeraFreeRTOSMachineState ChimeraFreeRTOSMachineState;

DECLARE_INSTANCE_CHECKER(ChimeraFreeRTOSMachineState,
                         CHIMERA_FREERTOS_MACHINE,
                         TYPE_CHIMERA_FREERTOS_MACHINE)

struct ChimeraFreeRTOSMachineState {
    /*< private >*/
    MachineState parent_obj;

    /*< public >*/
    RISCVHartArrayState cpus;
    char *ivshmem_arm_freertos;
    char *ivshmem_riscv_freertos;
    char *ivshmem_mips_freertos;
    char *ivshmem_stats_freertos;
};

enum {
    CHIMERA_FREERTOS_MROM,
    CHIMERA_FREERTOS_RAM,
    CHIMERA_FREERTOS_UART,
    CHIMERA_FREERTOS_CLINT,
    CHIMERA_FREERTOS_PLIC,
    CHIMERA_FREERTOS_IVSHMEM0_MMIO,
    CHIMERA_FREERTOS_IVSHMEM0_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM1_MMIO,
    CHIMERA_FREERTOS_IVSHMEM1_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM2_MMIO,
    CHIMERA_FREERTOS_IVSHMEM2_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM3_MMIO,
    CHIMERA_FREERTOS_IVSHMEM3_SHMEM,
};

enum {
    CHIMERA_FREERTOS_UART_IRQ      = 10,
    CHIMERA_FREERTOS_IVSHMEM0_IRQ  = 16,
    CHIMERA_FREERTOS_IVSHMEM1_IRQ  = 17,
    CHIMERA_FREERTOS_IVSHMEM2_IRQ  = 18,
    CHIMERA_FREERTOS_IVSHMEM3_IRQ  = 19,
};
```

- [ ] **Step 2: Commit**

```bash
git add include/hw/riscv/chimera_freertos_demo.h
git commit -m "feat: add IVSHMEM3 memmap enum, IRQ 19, and stats property to chimera_freertos_demo.h"
```

---

## Task 3: Extend `chimera_freertos_demo.c`

**Files:**
- Modify: `hw/riscv/chimera_freertos_demo.c`

- [ ] **Step 1: Add IVSHMEM3 memmap entries**

In the `chimera_freertos_memmap[]` array, after the `IVSHMEM2_SHMEM` entry add:

```c
    [CHIMERA_FREERTOS_IVSHMEM3_MMIO] =  { 0x3F000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM3_SHMEM] = { 0x40000000,
                                          CHIMERA_FREERTOS_IVSHMEM_SIZE },
```

- [ ] **Step 2: Bump PLIC source count from 19 to 20**

The PLIC GPIO input array is 0-indexed; `IVSHMEM3_IRQ = 19` needs index 19 (the 20th entry). Change:

```c
#define CHIMERA_FREERTOS_PLIC_NUM_SOURCES 20
```

- [ ] **Step 3: Add property getter/setter for ivshmem-stats-freertos**

After the existing `chimera_freertos_get/set_ivshmem_mips` functions, add:

```c
static char *chimera_freertos_get_ivshmem_stats(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    return g_strdup(s->ivshmem_stats_freertos);
}

static void chimera_freertos_set_ivshmem_stats(Object *obj, const char *value,
                                               Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    g_free(s->ivshmem_stats_freertos);
    s->ivshmem_stats_freertos = g_strdup(value);
}
```

- [ ] **Step 4: Require the stats chardev and connect the 4th ivshmem-flat**

In `chimera_freertos_machine_init`, add `stats_chr` alongside the existing three:

```c
    Chardev *arm_chr   = NULL;
    Chardev *riscv_chr = NULL;
    Chardev *mips_chr  = NULL;
    Chardev *stats_chr = NULL;
    bool have_links    = true;

    have_links &= chimera_freertos_require_chardev(s->ivshmem_arm_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_ARM,
                                                   &arm_chr);
    have_links &= chimera_freertos_require_chardev(s->ivshmem_riscv_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_RISCV,
                                                   &riscv_chr);
    have_links &= chimera_freertos_require_chardev(s->ivshmem_mips_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS,
                                                   &mips_chr);
    have_links &= chimera_freertos_require_chardev(s->ivshmem_stats_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_STATS,
                                                   &stats_chr);
```

After the existing three `chimera_freertos_connect_ivshmem` calls, add:

```c
    chimera_freertos_connect_ivshmem(
        plic, stats_chr,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM3_MMIO].base,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM3_SHMEM].base,
        CHIMERA_FREERTOS_IVSHMEM3_IRQ);
```

- [ ] **Step 5: Register the stats property in `chimera_freertos_machine_class_init`**

After the existing three `object_class_property_add_str` / `set_description` pairs, add:

```c
    object_class_property_add_str(oc, CHIMERA_FREERTOS_PROP_IVSHMEM_STATS,
                                  chimera_freertos_get_ivshmem_stats,
                                  chimera_freertos_set_ivshmem_stats);
    object_class_property_set_description(
        oc, CHIMERA_FREERTOS_PROP_IVSHMEM_STATS,
        "Chardev id for the stats FreeRTOS -> ARM-Linux ivshmem link");
```

- [ ] **Step 6: Commit**

```bash
git add hw/riscv/chimera_freertos_demo.c
git commit -m "feat: add IVSHMEM3 stats channel to chimera-riscv-freertos-demo machine"
```

---

## Task 4: Rebuild QEMU Inside Lima

This task must run inside the Lima VM (`qemu-dev`). `prepare_vm_source_tree` inside the script rsyncs the macOS repo to `~/chimera-src`, so the changes from Tasks 2–3 are automatically included.

- [ ] **Step 1: Run the QEMU build inside Lima**

```bash
limactl shell qemu-dev -- bash -c "
  cd /Users/yhsung/dev-projects/chimera &&
  BUILD_DIR=\$HOME/chimera-build-linux VM_SOURCE_DIR=\$HOME/chimera-src \
    scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh
"
```

Expected output: ninja build completes with `qemu-system-riscv64` and `qemu-system-aarch64` rebuilt. Look for the `chimera_freertos_demo.c` object in the build output to confirm it was recompiled.

- [ ] **Step 2: Verify the new machine property is accepted**

```bash
limactl shell qemu-dev -- bash -c "
  \$HOME/chimera-build-linux/qemu-system-riscv64 \
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=x,ivshmem-riscv-freertos=x,ivshmem-mips-freertos=x,ivshmem-stats-freertos=x \
    -bios /dev/null 2>&1 | head -5
"
```

Expected: QEMU errors about missing chardev `x` (not "unknown property"), confirming the `ivshmem-stats-freertos` property is registered.

---

## Task 5: Update `freertos_main.c`

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`

- [ ] **Step 1: Add include and IVSHMEM3 address defines**

After the existing `#include "freertos_ivshmem_flat.h"` line, add:

```c
#include "stats_proto.h"
```

After the existing `IVSHMEM2_SHMEM` define, add:

```c
#define IVSHMEM3_MMIO  0x3F000000UL
#define IVSHMEM3_SHMEM 0x40000000UL
```

- [ ] **Step 2: Add stats globals**

After `static struct freertos_ivshmem_link mips_link;`, add:

```c
static volatile struct hsoc_stats_snapshot *stats_shmem =
    (volatile struct hsoc_stats_snapshot *)IVSHMEM3_SHMEM;
static uint32_t arm_count;
static uint32_t riscv_count;
static uint32_t mips_count;
static uint32_t stats_tick;
```

- [ ] **Step 3: Add `write_stats_snapshot` helper**

Add after `tick_to_timestamp`:

```c
static void write_stats_snapshot(void)
{
    int64_t ts_sec, ts_nsec;

    stats_shmem->arm_count   = arm_count;
    stats_shmem->riscv_count = riscv_count;
    stats_shmem->mips_count  = mips_count;
    tick_to_timestamp(&ts_sec, &ts_nsec);
    stats_shmem->tick_sec  = ts_sec;
    stats_shmem->tick_nsec = ts_nsec;
    __sync_synchronize();
    stats_shmem->generation = stats_shmem->generation + 1;
    __sync_synchronize();
    log_uart("[freertos] stats snapshot written\n");
}
```

- [ ] **Step 4: Add `count` parameter to `maybe_service_link`**

Replace the existing function with:

```c
static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count)
{
    struct hsoc_hello_msg hello;
    int64_t ts_sec;
    int64_t ts_nsec;

    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }

    tick_to_timestamp(&ts_sec, &ts_nsec);
    log_uart(log_message);
    freertos_ivshmem_send_ack(link, hello.seq, ts_sec, ts_nsec);
    (*count)++;
}
```

- [ ] **Step 5: Update `showcase_task`**

Replace the full `showcase_task` function with:

```c
static void showcase_task(void *opaque)
{
    (void)opaque;
    uint32_t diag_count = 0;

    freertos_ivshmem_init(&arm_link,  IVSHMEM0_MMIO, IVSHMEM0_SHMEM, "arm-linux");
    freertos_ivshmem_init(&riscv_link, IVSHMEM1_MMIO, IVSHMEM1_SHMEM, "riscv-linux");
    freertos_ivshmem_init(&mips_link,  IVSHMEM2_MMIO, IVSHMEM2_SHMEM, "mips-linux");

    stats_shmem->magic      = HSOC_STATS_MAGIC;
    stats_shmem->generation = 0;
    __sync_synchronize();

    log_uart("[freertos] showcase task started\n");

    for (;;) {
        maybe_service_link(&arm_link,
                           "[freertos] received hello from arm-linux\n",
                           &arm_count);
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n",
                           &riscv_count);
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n",
                           &mips_count);

        if (++stats_tick >= 5000) {
            stats_tick = 0;
            write_stats_snapshot();
        }

        if (++diag_count >= 3000) {
            diag_count = 0;
            log_uart("[diag] arm_flag=");
            diag_print_hex32(arm_link.layout->linux_to_freertos.flag);
            log_uart(" arm_magic=");
            diag_print_hex32(arm_link.layout->linux_to_freertos.msg.magic);
            log_uart(" riscv_flag=");
            diag_print_hex32(riscv_link.layout->linux_to_freertos.flag);
            log_uart(" riscv_magic=");
            diag_print_hex32(riscv_link.layout->linux_to_freertos.msg.magic);
            log_uart(" mips_flag=");
            diag_print_hex32(mips_link.layout->linux_to_freertos.flag);
            log_uart(" mips_magic=");
            diag_print_hex32(mips_link.layout->linux_to_freertos.msg.magic);
            log_uart("\n");
        }

        vTaskDelay(pdMS_TO_TICKS(1));
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "feat: add stats snapshot writer to FreeRTOS showcase task"
```

---

## Task 6: Create `linux_stats.c`

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/linux_stats.c`

- [ ] **Step 1: Create the file**

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

#include "stats_proto.h"

#define HSOC_VENDOR_ID "0x1af4"
#define STATS_MMAP_SIZE ((size_t)4096)
#define STATS_RETRY_SEC 30

static bool read_first_line(const char *path, char *buf, size_t buf_size)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        return false;
    }
    bool ok = fgets(buf, buf_size, f) != NULL;
    fclose(f);
    if (ok) {
        buf[strcspn(buf, "\n")] = '\0';
    }
    return ok;
}

static void shm_read(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    size_t i;
    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

/*
 * Scan all PCI ivshmem devices (vendor 0x1af4) and return the first one whose
 * BAR2 (resource2) begins with HSOC_STATS_MAGIC. Retries for up to
 * STATS_RETRY_SEC seconds to handle the race where linux_stats starts before
 * FreeRTOS has written the magic value.
 */
static volatile struct hsoc_stats_snapshot *find_stats_shm(void)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) {
        sysfs_root = "/sys/bus/pci/devices";
    }

    for (int attempt = 0; attempt < STATS_RETRY_SEC; attempt++) {
        DIR *dir = opendir(sysfs_root);
        if (!dir) {
            perror("opendir");
            return NULL;
        }

        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') {
                continue;
            }

            char vendor_path[PATH_MAX];
            char vendor_val[32];
            if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                         sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) {
                continue;
            }
            if (!read_first_line(vendor_path, vendor_val, sizeof(vendor_val))) {
                continue;
            }
            if (strcmp(vendor_val, HSOC_VENDOR_ID) != 0) {
                continue;
            }

            char res_path[PATH_MAX];
            if (snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                         sysfs_root, entry->d_name) >= (int)sizeof(res_path)) {
                continue;
            }

            int fd = open(res_path, O_RDONLY | O_SYNC);
            if (fd < 0) {
                continue;
            }

            void *p = mmap(NULL, STATS_MMAP_SIZE, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) {
                continue;
            }

            uint32_t magic;
            shm_read(&magic, p, sizeof(magic));
            __sync_synchronize();

            if (magic == HSOC_STATS_MAGIC) {
                closedir(dir);
                return (volatile struct hsoc_stats_snapshot *)p;
            }
            munmap(p, STATS_MMAP_SIZE);
        }
        closedir(dir);

        if (attempt == 0) {
            fprintf(stderr, "[stats] waiting for FreeRTOS stats magic...\n");
        }
        sleep(1);
    }

    return NULL;
}

static void log_snapshot(FILE *log, const struct hsoc_stats_snapshot *snap)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    struct tm *tm_info = gmtime(&ts.tv_sec);
    char timebuf[32];
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%dT%H:%M:%SZ", tm_info);

    fprintf(log,
            "[%s] gen=%" PRIu32
            " arm=%" PRIu32
            " riscv=%" PRIu32
            " mips=%" PRIu32
            " tick=%" PRId64 ".%09" PRId64 "\n",
            timebuf,
            snap->generation,
            snap->arm_count,
            snap->riscv_count,
            snap->mips_count,
            snap->tick_sec,
            snap->tick_nsec);
    fflush(log);
}

int main(int argc, char *argv[])
{
    const char *log_path = getenv("FREERTOS_STATS_LOG");
    if (!log_path) {
        log_path = "/tmp/freertos-stats.log";
    }

    volatile struct hsoc_stats_snapshot *shm;

    if (argc > 1) {
        int fd = open(argv[1], O_RDONLY | O_SYNC);
        if (fd < 0) {
            perror("open BAR2");
            return 1;
        }
        void *p = mmap(NULL, STATS_MMAP_SIZE, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) {
            perror("mmap BAR2");
            return 1;
        }
        shm = (volatile struct hsoc_stats_snapshot *)p;
    } else {
        shm = find_stats_shm();
    }

    if (!shm) {
        fprintf(stderr, "[stats] could not find stats ivshmem BAR2\n");
        return 1;
    }

    FILE *log = fopen(log_path, "a");
    if (!log) {
        perror("fopen log");
        return 1;
    }

    fprintf(stderr, "[stats] logging to %s\n", log_path);

    uint32_t last_gen = 0;
    for (;;) {
        struct hsoc_stats_snapshot snap;
        shm_read(&snap, shm, sizeof(snap));
        __sync_synchronize();

        if (snap.magic == HSOC_STATS_MAGIC && snap.generation != last_gen) {
            last_gen = snap.generation;
            log_snapshot(log, &snap);
            fprintf(stderr, "[stats] gen=%" PRIu32 " logged\n", snap.generation);
        }
        sleep(2);
    }

    fclose(log);
    return 0;
}
```

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_stats.c
git commit -m "feat: add linux_stats.c ARM-Linux stats polling binary"
```

---

## Task 7: Update `Makefile` and Build Firmware

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 1: Add `linux-arm-stats` to the CC_ARM block and update the warning**

Replace the `HAVE_CC_ARM` conditional block:

```makefile
ifneq ($(HAVE_CC_ARM),)
HELLO_TARGETS += hello-arm-linux linux-arm-stats
endif
```

Replace the `ifeq ($(HAVE_CC_ARM),)` warning:

```makefile
ifeq ($(HAVE_CC_ARM),)
	$(warning CC_ARM=$(CC_ARM) not found — hello-arm-linux and linux-arm-stats skipped)
endif
```

- [ ] **Step 2: Add the `linux-arm-stats` build rule**

After the `hello-arm-linux` rule, add:

```makefile
linux-arm-stats: linux_stats.c stats_proto.h hello_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) -o $@ linux_stats.c
```

- [ ] **Step 3: Add `stats_proto.h` to the FreeRTOS ELF dependency list**

In the `freertos-riscv-demo.elf` rule, change `hello_proto.h $(FREERTOS_SRCS)` to `hello_proto.h stats_proto.h $(FREERTOS_SRCS)`.

The full updated rule:

```makefile
freertos-riscv-demo.elf: freertos_main.c freertos_ivshmem_flat.c \
		freertos_ivshmem_flat.h freertos_libc.c startup.S linker.ld FreeRTOSConfig.h \
		hello_proto.h stats_proto.h $(FREERTOS_SRCS)
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_PORT_DIR) \
	  -I$(FREERTOS_PORT_CHIP_DIR) \
	  startup.S freertos_main.c freertos_ivshmem_flat.c freertos_libc.c \
	  $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@
```

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "feat: add linux-arm-stats Makefile target and stats_proto.h firmware dep"
```

- [ ] **Step 5: Build firmware and linux-arm-stats inside Lima**

```bash
limactl shell qemu-dev -- bash -c "
  cd /Users/yhsung/dev-projects/chimera &&
  scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
"
```

Expected: `freertos-riscv-demo.elf` and `linux-arm-stats` both built without errors. Verify:

```bash
limactl shell qemu-dev -- ls -lh \
  /Users/yhsung/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase/linux-arm-stats \
  /Users/yhsung/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf
```

Expected: both files exist and are non-zero in size.

---

## Task 8: Update `common.sh`

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh`

- [ ] **Step 1: Add stats ivshmem socket vars and binary path**

After the `IVSHMEM_MIPS_FREERTOS_SOCKET` line (line 90), add:

```bash
IVSHMEM_STATS_FREERTOS_DIR="${IVSHMEM_STATS_FREERTOS_DIR:-/tmp/ivshmem-stats-freertos}"
IVSHMEM_STATS_FREERTOS_SOCKET="${IVSHMEM_STATS_FREERTOS_SOCKET:-${IVSHMEM_STATS_FREERTOS_DIR}/sock}"
```

After the `HELLO_MIPS_BINARY` line (line 96), add:

```bash
LINUX_ARM_STATS_BINARY="${LINUX_ARM_STATS_BINARY:-${FREERTOS_SHOWCASE_DIR}/linux-arm-stats}"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/common.sh
git commit -m "feat: add IVSHMEM_STATS_FREERTOS vars and LINUX_ARM_STATS_BINARY to common.sh"
```

---

## Task 9: Create `guest-start-ivshmem-server-stats.sh`

**Files:**
- Create: `scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_STATS_FREERTOS_DIR}"

if [[ -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_STATS_FREERTOS_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_STATS_FREERTOS_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_STATS_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -M ivshmem-stats-ft \
    -S "${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -l "${IVSHMEM_SIZE}" \
    -n "${IVSHMEM_VECTORS}" \
    -v
```

- [ ] **Step 2: Make it executable and commit**

```bash
chmod +x scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh
git add scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh
git commit -m "feat: add guest-start-ivshmem-server-stats.sh for stats channel server"
```

---

## Task 10: Update `guest-run-arm-phase5.sh`

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`

- [ ] **Step 1: Add the stats ivshmem-doorbell device**

Replace the existing `exec "${qemu_bin}" ...` block with (adding two lines before `-drive`):

```bash
exec "${qemu_bin}" \
    -machine virt,gic-version=3 \
    -cpu cortex-a57 -m 512M -smp 2 \
    -bios "${ARM_UEFI_BIOS}" \
    -kernel "${ARM_KERNEL_IMAGE}" \
    -initrd "${ARM_INITRD_IMAGE}" \
    -append "${ARM_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -chardev socket,id=ivshmem_stats,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem_stats,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${ARM_DEBIAN_DISK}",format=qcow2,if=virtio \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-arm-phase5.sh
git commit -m "feat: add stats ivshmem-doorbell to ARM-Linux QEMU launch"
```

---

## Task 11: Update `guest-run-riscv-freertos-phase5.sh`

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh`

- [ ] **Step 1: Add the stats machine property and chardev**

Replace the existing `exec "${qemu_bin}" ...` block with:

```bash
exec "${qemu_bin}" \
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -bios "${FREERTOS_DEMO_ELF}" \
    -monitor unix:/tmp/freertos-monitor.sock,server,nowait \
    -nographic
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh
git commit -m "feat: add ivshmem-stats-freertos property to FreeRTOS QEMU launch"
```

---

## Task 12: Update `guest-run-phase5-tmux.sh`

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`

This task rewrites the layout and socket-polling sections to accommodate the 4th server pane and `linux-arm-stats`.

- [ ] **Step 1: Update the layout comment and split sequence**

Replace lines 29–57 — the comment block, the `tmux kill-session` line, the `tmux new-session` line, and all `tmux split-window` calls — with:

```bash
# Build a single-window layout:
#
#  ┌──────────┬──────────┬──────────┬──────────┐
#  │srv ARM-FT│srv RSCV-F│srv MIPS-F│srv STATS │  panes 0,1,2,3  (equal quarters)
#  ├──────────┴──────────┴──────────┴──────────┤
#  │                  FreeRTOS                  │  pane 4
#  ├──────────────┬──────────────┬─────────────┤
#  │  ARM-Linux   │  RISCV-Linux │  MIPS-Linux │  panes 5,6,7  (equal thirds)
#  └──────────────┴──────────────┴─────────────┘
#
# Split sequence (-l N% gives the new pane N% of the pane being split):
#   split-v 80% on 0.0  → 0=top(20%),    1=rest(80%)
#   split-v 45% on 0.1  → 0=top(20%),    1=mid(44%),    2=bot(36%)
#   split-h 75% on 0.0  → 0=tl(25%),     1=tr(75%),     2=mid, 3=bot
#   split-h 67% on 0.1  → 0=tl(25%),     1=tm1(25%),    2=tm2+tr(50%), 3=mid, 4=bot
#   split-h 50% on 0.2  → 0=tl(25%),     1=tm1(25%),    2=tm2(25%), 3=tr(25%), 4=mid, 5=bot
#   split-h 67% on 0.5  → ...,            5=bl(33%),     6=br(67%)
#   split-h 50% on 0.6  → ...,            5=bl(33%),     6=bm(33%), 7=br(33%)

tmux kill-session -t "$SESSION" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

tmux split-window -v -t "$SESSION:0.0" -l 80%
tmux split-window -v -t "$SESSION:0.1" -l 45%
tmux split-window -h -t "$SESSION:0.0" -l 75%
tmux split-window -h -t "$SESSION:0.1" -l 67%
tmux split-window -h -t "$SESSION:0.2" -l 50%
tmux split-window -h -t "$SESSION:0.5" -l 67%
tmux split-window -h -t "$SESSION:0.6" -l 50%
```

- [ ] **Step 2: Update the ivshmem-server launch lines and socket poll**

Replace the server send-keys block and poll loop with:

```bash
# Start ivshmem servers; wait for all four sockets before launching guests.
tmux send-keys -t "$SESSION:0.0" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-arm-freertos.sh"   Enter
tmux send-keys -t "$SESSION:0.1" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-riscv-freertos.sh" Enter
tmux send-keys -t "$SESSION:0.2" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-mips-freertos.sh"  Enter
tmux send-keys -t "$SESSION:0.3" "cd '$REPO' && scripts/heterogeneous-soc/guest-start-ivshmem-server-stats.sh"          Enter

ARM_SOCK="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}/sock"
RISCV_SOCK="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}/sock"
MIPS_SOCK="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}/sock"
STATS_SOCK="${IVSHMEM_STATS_FREERTOS_DIR:-/tmp/ivshmem-stats-freertos}/sock"
for _i in $(seq 1 60); do
    if [[ -S "$ARM_SOCK"   ]] && ss -xl | grep -Fq "$ARM_SOCK"   && \
       [[ -S "$RISCV_SOCK" ]] && ss -xl | grep -Fq "$RISCV_SOCK" && \
       [[ -S "$MIPS_SOCK"  ]] && ss -xl | grep -Fq "$MIPS_SOCK"  && \
       [[ -S "$STATS_SOCK" ]] && ss -xl | grep -Fq "$STATS_SOCK"; then
        break
    fi
    sleep 0.5
done
```

- [ ] **Step 3: Update the guest send-keys lines (pane numbers shifted)**

Replace the four guest send-keys lines with:

```bash
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.6" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-riscv-phase5.sh"          Enter
tmux send-keys -t "$SESSION:0.7" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-chimera.sh"               Enter
```

- [ ] **Step 4: Update `auto_login_and_run` to accept multiple commands**

Replace the `auto_login_and_run` function definition with:

```bash
# auto_login_and_run PANE CMD [CMD ...]
# Waits for a login or shell prompt in PANE, logs in if needed, mounts /mnt/pingpong,
# then runs each CMD in sequence with a 1-second gap.
auto_login_and_run() {
    local pane="$1"
    shift
    local cmds=("$@")
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)"
        if echo "$content" | grep -q "login:"; then
            tmux send-keys -t "$pane" "root" Enter
            sleep 3
            tmux send-keys -t "$pane" "mount /mnt/pingpong" Enter
            sleep 1
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "$pane" "$cmd" Enter
                sleep 1
            done
            return 0
        elif echo "$content" | grep -qE "root@[^:]*:~?#"; then
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "$pane" "$cmd" Enter
                sleep 1
            done
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for shell prompt in pane $pane" >&2
}
```

- [ ] **Step 5: Update the auto_login_and_run call sites (pane numbers shifted; ARM runs linux-arm-stats)**

Replace the three `auto_login_and_run` call lines with:

```bash
auto_login_and_run "$SESSION:0.5" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "/mnt/pingpong/freertos-showcase/hello-arm-linux" &
auto_login_and_run "$SESSION:0.6" \
    "/mnt/pingpong/freertos-showcase/hello-riscv-linux" &
auto_login_and_run "$SESSION:0.7" \
    "cp /mnt/pingpong/freertos-showcase/hello-mips-linux /tmp/hello-mips-linux && /tmp/hello-mips-linux" &
```

- [ ] **Step 6: Update the final focus and select-pane line**

Change:

```bash
tmux select-pane -t "$SESSION:0.3"
```

to:

```bash
tmux select-pane -t "$SESSION:0.4"
```

- [ ] **Step 7: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
git commit -m "feat: add stats server pane and linux-arm-stats to phase5 tmux layout"
```

---

## Task 13: Integration Test

- [ ] **Step 1: Kill any stale processes and sockets**

```bash
limactl shell qemu-dev -- bash -c "
  pkill -f qemu-system 2>/dev/null || true
  rm -f /tmp/ivshmem-arm-freertos/sock /tmp/ivshmem-riscv-freertos/sock \
        /tmp/ivshmem-mips-freertos/sock /tmp/ivshmem-stats-freertos/sock \
        /tmp/freertos-monitor.sock
  sleep 0.5
"
```

- [ ] **Step 2: Run the full demo**

```bash
limactl shell qemu-dev -- bash -c "
  cd /Users/yhsung/dev-projects/chimera &&
  SKIP_BUILD=1 scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
"
```

`SKIP_BUILD=1` skips the firmware rebuild since Task 7 already built it. Attach to the tmux session and watch FreeRTOS output (pane 4).

- [ ] **Step 3: Verify FreeRTOS prints stats snapshots**

In the FreeRTOS pane (pane 4), you should see after ~5 seconds:

```
[freertos] stats snapshot written
```

Repeating every ~5 seconds.

- [ ] **Step 4: Verify ARM-Linux stats log**

After ARM-Linux boots and both `linux-arm-stats` and `hello-arm-linux` start running, check inside the ARM-Linux pane (pane 5) for:

```
[stats] gen=1 logged
[stats] gen=2 logged
```

Then check the log file:

```
cat /tmp/freertos-stats.log
```

Expected output with non-zero `arm_count`:

```
[2026-06-06T12:34:56Z] gen=1 arm=0 riscv=0 mips=0 tick=5.000000000
[2026-06-06T12:34:58Z] gen=2 arm=3 riscv=0 mips=0 tick=10.000000000
```

(`arm_count` increases as the HELLO/ACK loop runs.)

- [ ] **Step 5: Verify existing harness still passes**

```bash
limactl shell qemu-dev -- bash -c "
  cd /Users/yhsung/dev-projects/chimera &&
  pkill -f qemu-system 2>/dev/null || true
  rm -f /tmp/ivshmem-*/sock /tmp/freertos-monitor.sock
  sleep 0.5
  CHIMERA_ROOT=/Users/yhsung/dev-projects/chimera \
  BUILD_DIR=\$HOME/chimera-build-linux \
  FREERTOS_DEMO_ELF=/Users/yhsung/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf \
  scripts/heterogeneous-soc/guest-run-freertos-harness.sh
"
```

Expected: `PASS` exit code 0. Harness does not use the stats channel, so this is a pure regression check.
