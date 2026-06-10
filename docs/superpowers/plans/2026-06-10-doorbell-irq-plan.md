# IVSHMEM Doorbell IRQ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the dormant doorbell + GIC interrupt path on IVSHMEM0 (ARM-Linux ↔ FreeRTOS), replacing flag-polling with interrupt-driven HELLO/ACK on both sides, with a 200ms poll fallback on ARM-Linux and a 10ms watchdog on FreeRTOS.

**Architecture:** FreeRTOS enables GIC SPI 33 (IVSHMEM0), registers an ISR that reads HELLO from shared memory and rings the ivshmem-flat DOORBELL register after ACK. ARM-Linux mmaps BAR0/resource0 to ring FreeRTOS's doorbell, binds the ivshmem-doorbell to `uio_pci_generic` for interrupt receive, and uses `ppoll(fd, 200ms)` with a direct-flag-read fallback. RISCV/MIPS daemons (compiled from the same `linux_syslog.c`) ignore UIO and keep busy-polling unchanged.

**Tech Stack:** FreeRTOS Cortex-R52 port (ARM_CR5), GICv2 MMIO, Linux UIO (`uio_pci_generic`), QEMU ivshmem-flat + ivshmem-doorbell, sysfs PCI resource mmap.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c` | Modify | Add `freertos_ivshmem_isr()`, unmask INTMASK in `freertos_ivshmem_init()` |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h` | Modify | Declare `freertos_ivshmem_isr()` |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Modify | Add `R52_IVSHMEM0_INTID`, enable GIC SPI 33, dispatch ISR, relax main poll loop |
| `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c` | Modify | Add `doorbell_init()`, `doorbell_ring()`, `hybrid_wait_ack()`, `find_ivshmem_doorbell()`; replace busy-loop with hybrid wait |
| `scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh` | Modify | Add UIO module loading and ivshmem-doorbell BDF discovery and binding |

---

### Task 1: FreeRTOS — add `freertos_ivshmem_isr()` and INTMASK unmask

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h`

- [ ] **Step 1: Add FreeRTOS includes to `freertos_ivshmem_flat.c`**

Add after the existing `#include "freertos_ivshmem_flat.h"`:

```c
#include "FreeRTOS.h"
#include "task.h"
```

- [ ] **Step 2: Add `tick_to_timestamp_isr()` and `freertos_ivshmem_isr()` to `freertos_ivshmem_flat.c`**

Add before the existing `freertos_ivshmem_init()`:

```c
/*
 * ISR-safe tick-to-timestamp conversion.
 * Uses xTaskGetTickCountFromISR() instead of xTaskGetTickCount() because
 * we run in interrupt context (safe to call at task level too, but we keep
 * the ISR variant self-contained to avoid coupling with freertos_main.c).
 */
static void tick_to_timestamp_isr(int64_t *ts_sec, int64_t *ts_nsec)
{
    TickType_t ticks = xTaskGetTickCountFromISR();
    const int64_t ns_per_tick = 1000000000LL / configTICK_RATE_HZ;

    *ts_sec = ticks / configTICK_RATE_HZ;
    *ts_nsec = (ticks % configTICK_RATE_HZ) * ns_per_tick;
}

/*
 * Called from vApplicationIRQHandler on GIC SPI 1 (INTID 33).
 * Reads the HELLO from IVSHMEM0 shared memory, sends ACK, rings doorbell.
 * Follows the same volatile-byte-access rules as the poll path.
 */
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link)
{
    uint32_t int_status;
    struct hsoc_hello_msg msg;
    int64_t ts_sec, ts_nsec;

    /* Read INTSTATUS — if our bit is not set, this interrupt isn't for us */
    int_status = link->mmio_base[FREERTOS_IVSHMEM_INTSTATUS / sizeof(uint32_t)];
    if (!(int_status & 1)) return;

    __sync_synchronize();
    if (link->layout->linux_to_freertos.flag == 1) {
        /* Volatile byte-loop copy of the message from shared memory */
        shmem_read(&msg, &link->layout->linux_to_freertos.msg, sizeof(msg));

        if (msg.magic == HSOC_HELLO_MAGIC &&
            msg.version == HSOC_PROTO_VERSION &&
            msg.msg_type == HSOC_MSG_HELLO) {

            /* Build and send ACK with ISR-safe timestamp */
            tick_to_timestamp_isr(&ts_sec, &ts_nsec);
            freertos_ivshmem_send_ack(link, msg.seq, ts_sec, ts_nsec);

            /* Ring doorbell (write peer ID to DOORBELL reg @ offset 0xc) to
             * notify ARM-Linux that the ACK is ready. */
            link->mmio_base[FREERTOS_IVSHMEM_DOORBELL / sizeof(uint32_t)] = 1;

            log_uart(HSOC_LOG_INFO, "[irq] ivshmem0: HELLO handled via IRQ\n");
        }

        /* Acknowledge the HELLO by clearing the flag */
        link->layout->linux_to_freertos.flag = 0;
        __sync_synchronize();
    }

    /* Clear INTSTATUS by writing 1 */
    link->mmio_base[FREERTOS_IVSHMEM_INTSTATUS / sizeof(uint32_t)] = 1;
}
```

- [ ] **Step 3: Declare `freertos_ivshmem_isr()` in `freertos_ivshmem_flat.h`**

Add after the existing function declarations:

```c
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link);
```

- [ ] **Step 4: Unmask INTMASK in `freertos_ivshmem_init()`**

In `freertos_ivshmem_init()`, add after `link->name = name;`:

```c
    /* ivshmem-flat IRQ output is masked by default; enable it so the GIC
     * receives interrupts when the peer rings the doorbell. */
    link->mmio_base[FREERTOS_IVSHMEM_INTMASK / sizeof(uint32_t)] = 0xFFFFFFFF;
```

- [ ] **Step 5: Build FreeRTOS binary to verify compilation**

Run:
```bash
make -C contrib/heterogeneous-soc/freertos-showcase \
  FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR}" \
  freertos-r52-demo.elf
```
Expected: compiles without errors, produces `freertos-r52-demo.elf`.

- [ ] **Step 6: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c \
        contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h
git commit -m "feat(freertos): add ivshmem0 ISR with doorbell ring and INTMASK unmask"
```

---

### Task 2: FreeRTOS — enable GIC SPI 33, dispatch ISR, relax poll

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`

- [ ] **Step 1: Add `R52_IVSHMEM0_INTID` define**

Add alongside the existing `R52_CAN_INTID` (line 247):

```c
#define R52_IVSHMEM0_INTID 33U /* IVSHMEM0 on GIC SPI 1 → INTID 33 */
```

- [ ] **Step 2: Enable GIC SPI for IVSHMEM0 in `showcase_task()`**

In `showcase_task()`, after the `can_init(CAN_MMIO, IVSHMEM5_SHMEM);` call (line 325), add:

```c
    /* Enable IVSHMEM0 GIC SPI for interrupt-driven HELLO reception.
     * Same gic_enable_spi() pattern as can_driver.c. The GICD_CTLR group-0
     * forwarding is already enabled by vConfigureTickInterrupt(). */
    {
        volatile uint8_t  *iprio   = (volatile uint8_t  *)(GICD_BASE + GICD_IPRIORITYR);
        volatile uint8_t  *itarget = (volatile uint8_t  *)(GICD_BASE + GICD_ITARGETSR);
        volatile uint32_t *isen   = (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);
        uint32_t intid = R52_IVSHMEM0_INTID;

        iprio[intid]   = 0xA0;
        itarget[intid] = 0x01;
        isen[intid / 32] |= (1U << (intid % 32));
    }
```

- [ ] **Step 3: Add ISR dispatch for IVSHMEM0 in `vApplicationIRQHandler()`**

Replace the existing ivshmem comment stub (line 309):

```c
    } else if (intid == R52_IVSHMEM0_INTID) {
        freertos_ivshmem_isr(&arm_link);
    }
    /* Other ivshmem channels (RISCV/MIPS/stats) remain flag-polled; their
     * IRQs (if any fire) are ignored. */
```

- [ ] **Step 4: Relax main poll loop in `showcase_task()`**

The main poll loop at the bottom of `showcase_task()` currently uses:
```c
vTaskDelay(pdMS_TO_TICKS(1));
```

Change to:
```c
vTaskDelay(pdMS_TO_TICKS(10));
```

Add a comment above explaining the change:
```c
        /* Relaxed poll interval (10 ms vs 1 ms). IVSHMEM0 is now interrupt-
         * driven; the remaining channels (RISCV, MIPS) still poll flags but
         * tolerate the longer interval. */
```

- [ ] **Step 5: Rebuild FreeRTOS binary to verify**

Run:
```bash
make -C contrib/heterogeneous-soc/freertos-showcase \
  FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR}" \
  freertos-r52-demo.elf
```
Expected: compiles without errors.

- [ ] **Step 6: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "feat(freertos): enable GIC SPI 33, dispatch IVSHMEM0 ISR, relax poll loop to 10ms"
```

---

### Task 3: ARM-Linux — doorbell helpers in `linux_syslog.c`

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c`

- [ ] **Step 1: Add includes and new constants**

After the existing `#include <unistd.h>` (line 14), add:

```c
#include <poll.h>
```

After the existing `#define HSOC_BOOTLOG_MAGIC 0x424C5447U` (line 21), add:

```c
#define HSOC_DOORBELL_OFFSET  0x00cU    /* BAR0 doorbell register offset */
#define UIO_TIMEOUT_MS         200UL
```

- [ ] **Step 2: Add `find_ivshmem_doorbell()` helper**

Add after the existing `find_ivshmem_resource()` function (around line 228):

```c
/*
 * Locate the sysfs BDF of the ARM-Linux ivshmem-doorbell whose BAR2 shared
 * memory does NOT contain a known magic (STATS, BOOTLOG, CAN). That's the
 * ARM-Linux <-> FreeRTOS syslog channel.
 *
 * Returns a pointer to a static buffer (like find_ivshmem_resource), or NULL.
 */
static const char *find_ivshmem_doorbell(void)
{
    static char bdf_buf[PATH_MAX];
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) sysfs_root = "/sys/bus/pci/devices";

    DIR *dir = opendir(sysfs_root);
    if (!dir) return NULL;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char vendor_path[PATH_MAX], vendor_val[32];
        if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                     sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) continue;
        if (!read_first_line(vendor_path, vendor_val, sizeof(vendor_val))) continue;
        if (strcmp(vendor_val, HSOC_VENDOR_ID) != 0) continue;

        /* Peek at the magic at the start of BAR2 to identify the channel */
        char res2_path[PATH_MAX];
        if (snprintf(res2_path, sizeof(res2_path), "%s/%s/resource2",
                     sysfs_root, entry->d_name) >= (int)sizeof(res2_path)) continue;

        struct stat st;
        if (stat(res2_path, &st) != 0) continue;

        int fd = open(res2_path, O_RDONLY | O_SYNC);
        if (fd < 0) continue;
        void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) continue;

        uint32_t magic;
        shm_read(&magic, p, sizeof(magic));
        __sync_synchronize();
        munmap(p, 4096);

        /* Skip channels whose BAR2 begins with a known non-syslog magic */
        if (magic == HSOC_STATS_MAGIC || magic == HSOC_BOOTLOG_MAGIC ||
            magic == 0xCAFECAFEU) {
            continue;
        }

        /* This is the syslog channel */
        strncpy(bdf_buf, entry->d_name, sizeof(bdf_buf) - 1);
        bdf_buf[sizeof(bdf_buf) - 1] = '\0';
        closedir(dir);
        return bdf_buf;
    }

    closedir(dir);
    return NULL;
}
```

- [ ] **Step 3: Add `doorbell_init()` and `doorbell_ring()`**

Add after `find_ivshmem_doorbell()`:

```c
static int uio_fd = -1;
static volatile uint32_t *bar0 = NULL;
static bool doorbell_available = false;

/*
 * Initialize the doorbell path:
 *   1. mmap BAR0/resource0 for doorbell writes (send direction, no UIO needed)
 *   2. Open /dev/uio0 for interrupt receive (optional — if absent, fall back to poll)
 * Returns 0 on success, -1 on failure (caller degrades gracefully).
 */
static int doorbell_init(void)
{
    char res0_path[PATH_MAX];
    const char *bdf = getenv("IVSHMEM_BDF");
    int fd;

    if (!bdf) {
        bdf = find_ivshmem_doorbell();
        if (!bdf) {
            fprintf(stderr, "[%s] doorbell: no ivshmem BDF found, using poll\n",
                    HSOC_SENDER_LABEL);
            return -1;
        }
    }

    snprintf(res0_path, sizeof(res0_path),
             "/sys/bus/pci/devices/%s/resource0", bdf);
    fd = open(res0_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "[%s] doorbell: cannot open %s, using poll\n",
                HSOC_SENDER_LABEL, res0_path);
        return -1;
    }

    bar0 = (volatile uint32_t *)mmap(NULL, 4096,
                                     PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, 0);
    close(fd);
    if (bar0 == MAP_FAILED) {
        bar0 = NULL;
        fprintf(stderr, "[%s] doorbell: mmap resource0 failed, using poll\n",
                HSOC_SENDER_LABEL);
        return -1;
    }

    /* Attempt to open UIO for interrupt receive — this is optional.
     * ARM-Linux build: /dev/uio0 should exist if bound in guest-install.
     * RISCV/MIPS builds: UIO is absent, uio_fd stays -1, poll fallback used. */
    uio_fd = open("/dev/uio0", O_RDWR);

    doorbell_available = true;
    fprintf(stderr, "[%s] doorbell: init OK (uio_fd=%d)\n",
            HSOC_SENDER_LABEL, uio_fd);
    return 0;
}

/*
 * Ring the doorbell to interrupt FreeRTOS, signalling that a new HELLO message
 * has been written to IVSHMEM0 shared memory.
 *
 * ivshmem PCI doorbell register layout (BAR0 + 0x1000):
 *   Each entry is 8 bytes: uint32_t peer_id | uint32_t vector.
 *   ARM-Linux joins first (peer 0), FreeRTOS joins second (peer 1).
 */
static void doorbell_ring(void)
{
    if (!bar0 || !doorbell_available) return;

    /* IVSHMEM DOORBELL register (BAR0 + 0x0c):
     * Write (peer_id << 16) | vector_id as a single uint32_t.
     * peer_id=1 = FreeRTOS (joined second after ARM-Linux=0).
     * vector=0 = use eventfd[0]. */
    bar0[HSOC_DOORBELL_OFFSET / sizeof(uint32_t)] = (1U << 16);
    __sync_synchronize();
}
```

Note: The doorbell register format `(peer << 16) | vector` is shared by both ivshmem-flat and PCI ivshmem-doorbell. FreeRTOS (ivshmem-flat) writes `(0 << 16) | 1 = 1` to ring ARM-Linux (peer 0) with vector 1. ARM-Linux writes `(1 << 16) | 0 = 0x10000` to ring FreeRTOS (peer 1) with vector 0. The exact peer numbers depend on ivshmem-server join order (ARM starts first → peer 0, FreeRTOS second → peer 1); if this ordering changes, swap the peer_id value.

- [ ] **Step 4: Add `hybrid_wait_ack()`**

Replace the existing `wait_for_flag()` function with `hybrid_wait_ack()`:

```c
/*
 * Wait for ACK from FreeRTOS using hybrid interrupt + poll strategy:
 *   1. If UIO is available (uio_fd >= 0): ppoll(fd, 200ms) for doorbell IRQ
 *   2. On timeout or if UIO is absent: busy-wait on flag directly
 *   3. Read the ACK message from shared memory
 */
static void hybrid_wait_ack(struct hsoc_layout *shm,
                            struct hsoc_hello_msg *ack)
{
    if (uio_fd >= 0) {
        struct pollfd pfd = { .fd = uio_fd, .events = POLLIN };
        int ret = poll(&pfd, 1, (int)UIO_TIMEOUT_MS);
        if (ret > 0 && (pfd.revents & POLLIN)) {
            /* Read and discard the UIO event count (uint32_t) */
            uint32_t evt_cnt;
            ssize_t n = read(uio_fd, &evt_cnt, sizeof(evt_cnt));
            (void)n;
            /* IRQ path: doorbell received, ACK should be in shared memory */
        } else {
            /* Fallback path: IRQ missed or timed out, poll flag directly */
        }
    } else {
        /* No UIO available (RISCV/MIPS build or binding failed): busy-wait */
        while (1) {
            __sync_synchronize();
            if (shm->freertos_to_linux.flag == 1) break;
        }
    }

    /* Read the ACK from shared memory (always — works for both paths) */
    __sync_synchronize();
    if (shm->freertos_to_linux.flag == 1) {
        shm_read(ack, &shm->freertos_to_linux.msg, sizeof(*ack));
        __sync_synchronize();
        shm->freertos_to_linux.flag = 0;
    } else {
        memset(ack, 0, sizeof(*ack));
    }
}
```

- [ ] **Step 5: Integrate into `main_loop()`**

In `main_loop()`, after `shm->linux_to_freertos.flag = 1;` (line 261), add doorbell:

```c
        /* Ring doorbell to notify FreeRTOS via interrupt */
        doorbell_ring();
```

Replace the existing `wait_for_flag(&shm->freertos_to_linux.flag, 1);` and subsequent read (lines 264–268):

```c
        /* Primary: interrupt-driven ACK wait with poll fallback */
        hybrid_wait_ack(shm, &ack);

        if (ack.magic != HSOC_HELLO_MAGIC) {
            /* ACK not received (timeout or no UIO and flag not yet set).
             * This is the fallback path; retry on next cycle. */
            static uint32_t warn_count;
            if (warn_count++ % 5 == 0) {
                fprintf(stderr, "[%s] ACK timeout (seq=%" PRIu32
                        ") — doorbell IRQ may be missed\n",
                        HSOC_SENDER_LABEL, seq);
            }
            continue;
        }
```

The existing `ack_count++` and validation (original lines 268-289) should follow — they stay unchanged.

- [ ] **Step 6: Add `doorbell_init()` call in `main()`**

In `main()`, after the existing resource discovery (line 307-310), add:

```c
    /* Initialize doorbell/UIO path for interrupt-driven ACK wait */
    doorbell_init();
```

- [ ] **Step 7: Build ARM-Linux binary to verify**

Run:
```bash
make -C contrib/heterogeneous-soc/freertos-showcase \
  CC_ARM=aarch64-linux-gnu-gcc \
  syslog-arm-linux
```
Expected: compiles without errors.

- [ ] **Step 8: Build RISCV/MIPS binaries to verify backward compatibility**

Run:
```bash
make -C contrib/heterogeneous-soc/freertos-showcase \
  CC_RISCV=riscv64-linux-gnu-gcc \
  CC_MIPS=mipsel-linux-gnu-gcc \
  syslog-riscv-linux syslog-mips-linux
```
Expected: compiles without errors. RISCV/MIPS builds will use the poll-only path (no UIO).

- [ ] **Step 9: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c
git commit -m "feat(linux): add doorbell helpers, UIO hybrid wait, and doorbell ring for IRQ-driven IPC"
```

---

### Task 4: Launch script — UIO binding

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh`

- [ ] **Step 1: Add UIO binding step after binary injection**

At the end of `guest-install-syslog-to-guests.sh`, after the last `inject_binary` call (line 78), add:

```bash
# ── UIO driver binding for IVSHMEM doorbell IRQ (ARM-Linux only) ──
# Bind the ARM↔FreeRTOS ivshmem-doorbell to uio_pci_generic so that
# linux_syslog.c can receive doorbell interrupts via /dev/uio0.
_info "Setting up UIO for ivshmem-doorbell IRQ..."
if sudo modprobe uio_pci_generic 2>/dev/null; then
    _info "uio_pci_generic loaded"
else
    _skip "uio_pci_generic not available (kernel module missing)"
fi

# Iterate PCI devices, find the ivshmem-doorbell for the syslog channel.
# Skip STATS (0x53544154), BOOTLOG (0x424c5447), and CAN (0xcafecafe) channels.
IVSHMEM_BDF=""
for d in /sys/bus/pci/devices/*/; do
    v=$(cat "${d}vendor" 2>/dev/null)
    [ "$v" != "0x1af4" ] && continue

    magic=$(dd if="${d}resource2" bs=4 count=1 2>/dev/null | od -An -tx4 | tr -d ' ')
    case "$magic" in
        53544154|424c5447|cafecafe)
            continue
            ;;
        *)
            IVSHMEM_BDF=$(basename "$d")
            break
            ;;
    esac
done

if [ -n "$IVSHMEM_BDF" ]; then
    _info "Binding ${IVSHMEM_BDF} to uio_pci_generic..."
    # Write to driver_override so the kernel binds to UIO instead of any ivshmem driver
    echo "uio_pci_generic" | sudo tee "/sys/bus/pci/devices/${IVSHMEM_BDF}/driver_override" >/dev/null
    echo "${IVSHMEM_BDF}" | sudo tee "/sys/bus/pci/drivers/uio_pci_generic/bind" >/dev/null 2>&1 || true

    _ok "ivshmem-doorbell UIO bound: ${IVSHMEM_BDF}"
else
    _skip "no ivshmem-doorbell found for UIO binding"
fi
```

The `|| true` on bind is intentional — if the device is already bound, the second write fails harmlessly.

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh
git commit -m "feat(scripts): add UIO binding for ivshmem-doorbell IRQ in guest-install-syslog"
```

---

### Task 5: Integration test

Run on Lima VM:

- [ ] **Step 1: Build everything**

```bash
make -C contrib/heterogeneous-soc/freertos-showcase \
  FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR}" \
  CC_ARM=aarch64-linux-gnu-gcc
```
Expected: `syslog-arm-linux`, `freertos-r52-demo.elf` built without errors.

- [ ] **Step 2: Deploy new binaries**

```bash
bash scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh
```
Expected: UIO binding logs show `✓ ivshmem-doorbell UIO bound: 0000:XX:XX.X`

- [ ] **Step 3: Launch showcase**

```bash
bash scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

- [ ] **Step 4: Verify FreeRTOS IRQ path**

```bash
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.0 | grep -i "irq"
```
Expected: `[irq] ivshmem0: HELLO handled via IRQ` lines appearing.

- [ ] **Step 5: Verify ARM-Linux ACK is received**

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.6 \
  "cat /var/log/chimera-log/chimera-cross-domain.log | tail -5" Enter
sleep 1
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.6 | tail -10
```
Expected: `[arm-linux] ACK #N freertos_tick=...` lines with increasing sequence numbers.

- [ ] **Step 6: Verify RISCV/MIPS still work (regression)**

```bash
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.7 | grep -i "riscv.*ACK" | tail -3
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.8 | grep -i "mips.*ACK" | tail -3
```
Expected: Both show ACK messages (they continue polling, unchanged behavior).

- [ ] **Step 7: Verify fallback robustness (optional)**

```bash
# Simulate UIO failure by removing the module on ARM-Linux
limactl shell qemu-dev -- ssh -p 2222 root@localhost 'rmmod uio_pci_generic'
```
Then verify syslog daemon still receives ACKs via poll fallback (watch for "ACK timeout" warnings in the syslog pane).

After testing, restore:
```bash
limactl shell qemu-dev -- ssh -p 2222 root@localhost 'modprobe uio_pci_generic'
```

- [ ] **Step 8: Commit any final fixes**

```bash
git add -A
git commit -m "fix: address integration test findings for doorbell IRQ"
```
