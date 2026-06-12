# IVSHMEM Doorbell IRQ Activation Design

**Date:** 2026-06-10
**Status:** Draft

## Goal

Activate the dormant doorbell + GIC interrupt path on the existing IVSHMEM0 (ARM-Linux ↔ FreeRTOS) channel, replacing pure flag-polling with interrupt-driven HELLO/ACK delivery on both sides, while keeping a sub-second poll fallback as a robustness safety net.

The ivshmem-flat QEMU sysbus device on the FreeRTOS side already implements doorbell registers (offset 0x0c), INTMASK/INTSTATUS registers, an eventfd handler (`ivshmem_flat_irq_handler`), and a GIC IRQ output wire. Similarly, the ivshmem-doorbell PCI device on ARM-Linux provides BAR0 doorbell registers and MSI-X eventfd delivery. Neither side currently uses any of this hardware — all communication is done by busy-polling a flag in shared memory.

## Architecture

```
       ┌───────── Poll path (fallback, unchanged) ──────────┐
       │                                                     │
       │  ┌──────────────────────────────────────────────┐  │
       │  │   Poll safety net (ARM: 200ms, FreeRTOS:     │  │
       │  │   10ms) — reads flag directly if IRQ missed  │  │
       │  └──────────────────────────────────────────────┘  │
       │                                                     │
       ▼                                                     ▼
┌──────────────────┐     Doorbell (write BAR0)     ┌──────────────────┐
│  ARM-Linux       │ ──────────────────────────────►│  FreeRTOS (R52)  │
│  ivshmem-doorbell│     eventfd → ivshmem-server   │  ivshmem-flat    │
│  PCI device      │     → peer QEMU → eventfd →    │  sysbus device   │
│  vectors=4       │     qemu_irq_pulse → GIC SPI   │                  │
│                  │                                 │  DOORBELL@0x0c   │
│  /dev/uio0       │◄────────────────────────────────── writes peer_id  │
│  (uio_pci_generic)│  FreeRTOS writes DOORBELL @0xc │  into register,  │
│   >  read() blocks│  → ivshmem_flat_interrupt_peer │  QEMU sends      │
│   >  poll(200ms)  │  → eventfd → ivshmem-server    │  eventfd to ARM  │
│                  │     → ARM QEMU → MSI-X → UIO    │  QEMU            │
└──────────────────┘                                 └──────────────────┘
```

**Three concurrent mechanisms, highest wins:**
1. **Interrupt (primary):** The Linux guest (ARM/RISCV/MIPS) writes HELLO flag, rings doorbell → FreeRTOS GIC IRQ fires → ISR reads HELLO, sends ACK, rings DOORBELL → Linux UIO `read()` returns → daemon reads ACK
2. **Poll fallback (Linux):** `ppoll()` on `/dev/uio0` with 200 ms timeout. If doorbell IRQ arrives: immediate return. If not: timeout fires, daemon reads the ACK flag directly from shared memory
3. **Poll fallback (FreeRTOS):** Main task poll loop runs every ~10 ms (relaxed from today's 1 ms) as a watchdog. If ISR already handled the channel, poll skips it

## Component Changes

### 1. FreeRTOS — Interrupt Reception

**Files changed:** `freertos_main.c`, `freertos_ivshmem_flat.c`, `freertos_ivshmem_flat.h`

#### 1a. GIC SPI enable in `freertos_main.c`

```c
/* IVSHMEM0 on SPI 1 → INTID = 32 + 1 = 33 */
#define R52_IVSHMEM0_INTID 33U
```

Add to `vConfigureTickInterrupt()` (or a new `vConfigurePlatformIRQs`):
```c
iprio[R52_IVSHMEM0_INTID] = 0xA0;
isen[R52_IVSHMEM0_INTID / 32] |= (1U << (R52_IVSHMEM0_INTID % 32));
```

#### 1b. ISR dispatch in `vApplicationIRQHandler()`

```c
} else if (intid == R52_IVSHMEM0_INTID) {
    freertos_ivshmem_isr(&arm_link);
}
```

#### 1c. New `freertos_ivshmem_isr()` in `freertos_ivshmem_flat.c`

ISR-safe function:

```c
/* ISR-safe tick conversion — matches tick_to_timestamp() in freertos_main.c
 * but uses xTaskGetTickCountFromISR() since we're in interrupt context.
 * (That function is also safe to call at task level, so a unified helper
 * would work, but keeping the ISR variant self-contained avoids coupling.) */
static void tick_to_timestamp_isr(int64_t *ts_sec, int64_t *ts_nsec)
{
    TickType_t ticks = xTaskGetTickCountFromISR();
    const int64_t ns_per_tick = 1000000000LL / configTICK_RATE_HZ;

    *ts_sec = ticks / configTICK_RATE_HZ;
    *ts_nsec = (ticks % configTICK_RATE_HZ) * ns_per_tick;
}

void freertos_ivshmem_isr(struct freertos_ivshmem_link *link)
{
    uint32_t int_status;
    struct hsoc_hello_msg msg;
    int64_t ts_sec, ts_nsec;

    int_status = link->mmio_base[FREERTOS_IVSHMEM_INTSTATUS / sizeof(uint32_t)];
    if (!(int_status & 1)) return;

    __sync_synchronize();
    if (link->layout->linux_to_freertos.flag == 1) {
        shmem_read(&msg, &link->layout->linux_to_freertos.msg, sizeof(msg));

        if (msg.magic == HSOC_HELLO_MAGIC &&
            msg.version == HSOC_PROTO_VERSION &&
            msg.msg_type == HSOC_MSG_HELLO) {

            /* Build and send ACK */
            tick_to_timestamp_isr(&ts_sec, &ts_nsec);
            freertos_ivshmem_send_ack(link, msg.seq, ts_sec, ts_nsec);

            /* Ring doorbell to notify ARM-Linux */
            link->mmio_base[FREERTOS_IVSHMEM_DOORBELL / sizeof(uint32_t)] = 1;
        }

        link->layout->linux_to_freertos.flag = 0;
        __sync_synchronize();
    }

    link->mmio_base[FREERTOS_IVSHMEM_INTSTATUS / sizeof(uint32_t)] = 1;
}
```

#### 1d. Unmask INTMASK in `freertos_ivshmem_init()`

```c
/* ivshmem-flat IRQ output is masked by default; enable it */
link->mmio_base[FREERTOS_IVSHMEM_INTMASK / sizeof(uint32_t)] = 0xFFFFFFFF;
```

#### 1e. Relax main poll loop

In `showcase_task()`, reduce poll frequency from 1 ms to ~10 ms as watchdog. The poll checks whether the ISR has already processed the channel (flag is already 0) and skips if so.

### 2. ARM-Linux — Doorbell Ring + UIO Receive

**Files changed:** `linux_syslog.c`, `guest-install-syslog-to-guests.sh`
**New file:** `guest-find-ivshmem-syslog.sh` (helper)

#### 2a. UIO driver binding (`guest-install-syslog-to-guests.sh`)

```bash
# Load UIO driver
modprobe uio_pci_generic

# Find the ARM↔FreeRTOS ivshmem-doorbell by filtering out stats/boot/CAN channels
# (they have distinct magic numbers in shared memory)
IVSHMEM_BDF=""
for d in /sys/bus/pci/devices/*/; do
    v=$(cat "${d}vendor" 2>/dev/null)
    [ "$v" != "0x1af4" ] && continue

    # Peek at resource2 to check magic
    magic=$(dd if="${d}resource2" bs=4 count=1 2>/dev/null | od -An -tx4 | tr -d ' ')
    case "$magic" in
        53544154|424c5447|424c5447*)  # STATS or BOOTLOG
            continue
            ;;
        *)
            IVSHMEM_BDF=$(basename "$d")
            break
            ;;
    esac
done

if [ -n "$IVSHMEM_BDF" ]; then
    echo "uio_pci_generic" > "/sys/bus/pci/devices/$IVSHMEM_BDF/driver_override"
    echo "$IVSHMEM_BDF" > "/sys/bus/pci/drivers/uio_pci_generic/bind"
fi
```

#### 2b. New helpers in `linux_syslog.c`

**Doorbell ring (ARM-Linux → FreeRTOS) — uses sysfs resource0 mmap:**

The send direction does not need UIO. We mmap BAR0 (`resource0`) directly via sysfs for writing doorbell registers. UIO is only needed for the receive direction (waiting on interrupt events).

```c
static int uio_fd = -1;              /* /dev/uio0 for interrupt receive */
static volatile uint32_t *bar0 = NULL;  /* mmap of PCI resource0 for doorbell send */
static uint32_t freertos_peer_id;    /* discovered at init */
static bool doorbell_available;

static int doorbell_init(void)
{
    char res0_path[PATH_MAX];
    const char *ivshmem_bdf = getenv("IVSHMEM_BDF");
    int fd;

    if (!ivshmem_bdf) {
        /* Auto-detect: find the non-stats, non-boot ivshmem-doorbell */
        /* (same logic as guest-install-syslog-to-guests.sh) */
        ivshmem_bdf = find_ivshmem_doorbell();
        if (!ivshmem_bdf) return -1;
    }

    snprintf(res0_path, sizeof(res0_path),
             "/sys/bus/pci/devices/%s/resource0", ivshmem_bdf);
    fd = open(res0_path, O_RDWR | O_SYNC);
    if (fd < 0) return -1;

    bar0 = (volatile uint32_t *)mmap(NULL, 4096,
                                     PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, 0);
    close(fd);
    if (bar0 == MAP_FAILED) { bar0 = NULL; return -1; }

    /* Discover FreeRTOS peer ID.
     * ivshmem PCI: doorbell at BAR0+0x1000, each entry = { peer, vector }.
     * The ivshmem-server assigns peer IDs sequentially.
     * ARM-Linux (first joiner) = ID 0, FreeRTOS (second) = ID 1. */
    freertos_peer_id = 1;

    /* Open UIO device for interrupt receive (may also fail — fallback to poll) */
    uio_fd = open("/dev/uio0", O_RDWR);
    doorbell_available = true;
    return 0;
}

static void doorbell_ring(void)
{
    if (!bar0) return;

    /* IVSHMEM_DOORBELL register format:
     * BAR0 offset 0x1000 + entry_size * peer_id
     * Each entry: uint32_t peer_id | uint32_t vector */
    volatile uint32_t *doorbell = bar0 + (0x1000 / sizeof(uint32_t));
    doorbell[freertos_peer_id * 2]     = freertos_peer_id;  /* target */
    doorbell[freertos_peer_id * 2 + 1] = 0;                  /* vector 0 */
}
```

**Hybrid wait (replaces `wait_for_flag`):**

```c
#define UIO_TIMEOUT_MS 200

static void hybrid_wait_ack(struct hsoc_layout *shm,
                            struct hsoc_hello_msg *ack)
{
    struct pollfd pfd = { .fd = uio_fd, .events = POLLIN };

    if (uio_fd >= 0) {
        int ret = poll(&pfd, 1, UIO_TIMEOUT_MS);
        if (ret > 0 && (pfd.revents & POLLIN)) {
            uint32_t uio_evt;
            read(uio_fd, &uio_evt, sizeof(uio_evt));
            /* IRQ path: doorbell received, ACK should be ready */
        } else {
            /* Timeout path: IRQ missed, fall back to poll */
        }
    }

    /* Always read the ACK from shared memory (works both paths) */
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

#### 2c. Main loop integration

```c
/* In main_loop(), replace wait_for_flag(&shm->freertos_to_linux.flag, 1): */

/* Primary: interrupt-driven with poll fallback */
hybrid_wait_ack(shm, &ack);

if (ack.magic != HSOC_HELLO_MAGIC) {
    /* Timeout without ACK — log warning, retry next cycle */
    fprintf(stderr, "[%s] ACK timeout (seq=%" PRIu32 ")\n",
            HSOC_SENDER_LABEL, seq);
    continue;
}
```

### 3. QEMU Machine Definition

**No changes.** IVSHMEM0 on the `chimera-r52-freertos-demo` machine is already fully wired:

| mmap entry | MMIO addr | SHMEM addr | SPI | INTID |
|------------|-----------|------------|-----|-------|
| IVSHMEM0_MMIO / IVSHMEM0_SHMEM | 0x30000000 | 0x31000000 | 1 | 33 |

The ivshmem-flat device is instantiated with its IRQ output connected to GIC gpio-in `SPI + 1`. The eventfd handler at `ivshmem_flat.c:49` and the DOORBELL write handler at `ivshmem_flat.c:256` are already compiled in.

The ARM-Linux QEMU command line already includes:
```
-device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
```
with `IVSHMEM_VECTORS=4`.

### 4. Launch Scripts

**Changes to `guest-install-syslog-to-guests.sh`:**
- Add UIO module loading and device binding (from Section 2a)
- Ship the updated `linux_syslog` binary built with doorbell support

**No changes to:**
- `guest-run-arm-phase5.sh` (ivshmem-doorbell already configured)
- `guest-run-r52-freertos-phase5.sh` (ivshmem-flat already configured)
- `guest-run-chimera-showcase.sh` (no new servers or sockets needed)
- `common.sh` (no new variables needed)

## ivshmem Channel Map (updated)

| Channel | MMIO | SHMEM | SPI | INTID | Mechanism |
|---------|------|-------|-----|-------|-----------|
| IVSHMEM0 | 0x30000000 | 0x31000000 | 1 | 33 | Interrupt + 200ms poll |
| IVSHMEM1 | 0x35000000 | 0x36000000 | 2 | 34 | Interrupt + 200ms poll |
| IVSHMEM2 | 0x3A000000 | 0x3B000000 | 3 | 35 | Interrupt + 200ms poll |
| IVSHMEM3 | 0x3F000000 | 0x40000000 | 4 | 36 | Stats FreeRTOS→ARM (poll) |
| IVSHMEM4 | 0x44000000 | 0x45000000 | 5 | 37 | Boot log (poll) |
| IVSHMEM5 | 0x49000000 | 0x4A000000 | 7 | 39 | CAN frames FreeRTOS→ARM (poll) |

## Testing

### Normal operation
1. Launch showcase: `guest-run-chimera-showcase.sh`
2. Verify ARM-Linux syslog daemon starts and sends HELLO messages
3. Check FreeRTOS UART output for `[irq] ivshmem0/ivshmem1/ivshmem2: IRQ handled` messages
4. Verify `chimera-cross-domain.log` on ARM-Linux shows ACK timestamps with seq numbers

### Latency comparison
1. Measure time from `write(doorbell)` to IRQ handler entry on FreeRTOS (visible via UART timestamp)
2. Compare with the existing poll interval — should drop from ~1 ms to <100 µs

### Fallback robustness
1. Remove `uio_pci_generic` module (or mask INTMASK on FreeRTOS)
2. Verify the system still operates — ACK is read via timeout fallback
3. Check log for `[uio] doorbell timeout — fallback poll used`

### Regression
1. Verify RISCV and MIPS channels still pass their HELLO/ACK handshakes (now interrupt-driven via doorbell + GIC IRQ, same as ARM)
2. Verify CAN bus demo still works
3. Verify stats snapshots still appear in chimera-cross-domain.log
