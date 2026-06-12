# IVSHMEM1/IVSHMEM2 Doorbell IRQ Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the IVSHMEM0 (ARM-Linux ↔ FreeRTOS) doorbell + GIC interrupt path to IVSHMEM1 (RISCV-Linux ↔ FreeRTOS, GIC SPI2/INTID34) and IVSHMEM2 (MIPS-Linux ↔ FreeRTOS, GIC SPI3/INTID35), making all three HELLO/ACK channels interrupt-driven with a 200ms/10ms poll fallback, matching IVSHMEM0's end state exactly.

**Architecture:** `freertos_ivshmem_isr()` gains a `doorbell_ring_value` parameter (replacing its hardcoded `(1U<<16)|0U`) and switches its log messages to `link->name`-based prefixes so the same function correctly serves `arm_link`, `riscv_link`, and `mips_link`. A new `gic_enable_ivshmem_spi(intid)` helper in `freertos_main.c` extracts the existing inline SPI33-enable block so it can be called for SPI34/SPI35 too. `vApplicationIRQHandler()` gains two new dispatch branches for INTID 34/35. The main poll loop drops `riscv_link`/`mips_link` servicing (now interrupt-driven), which makes `maybe_service_link()` and `freertos_ivshmem_poll_hello()` dead code — both are removed. On the Linux side, `linux_syslog.c`'s `doorbell_init()` drops its `HSOC_SENDER_ID == HSOC_SENDER_ARM_LINUX` gate so riscv-linux and mips-linux also bind `uio_pci_generic` and use `hybrid_wait_ack()`.

**Tech Stack:** FreeRTOS Cortex-R52 port (ARM_CR5), GICv2 MMIO, Linux UIO (`uio_pci_generic`), QEMU ivshmem-flat + ivshmem-doorbell.

---

## File Structure

| File | Status | Responsibility |
|------|--------|----------------|
| `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h` | Modify | Add `doorbell_ring_value` param to `freertos_ivshmem_isr()`; remove dead `freertos_ivshmem_poll_hello()` declaration |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c` | Modify | Generalize ISR doc comment + logs to `link->name`, parameterize doorbell-ring write, remove dead `freertos_ivshmem_poll_hello()` |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Modify | Add `R52_IVSHMEM1_INTID`/`R52_IVSHMEM2_INTID`, add `gic_enable_ivshmem_spi()` helper, dispatch SPI34/SPI35, drop poll-loop calls + dead `maybe_service_link()` |
| `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c` | Modify | Remove ARM-Linux-only gate in `doorbell_init()` |
| `docs/superpowers/specs/2026-06-10-doorbell-irq-design.md` | Modify | Generalize "Three concurrent mechanisms" + channel map to IVSHMEM0/1/2 |
| `README.md` | Modify | Update "Signaling" description for IVSHMEM0/1/2 interrupt-driven channels |

---

### Task 1: FreeRTOS — parameterize `doorbell_ring_value` and generalize ISR logging

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` (one call site, kept in sync with the new signature)

- [ ] **Step 1: Add `doorbell_ring_value` to the declaration in `freertos_ivshmem_flat.h`**

Replace:

```c
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks);
```

with:

```c
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks,
                          uint32_t doorbell_ring_value);
```

- [ ] **Step 2: Generalize the doc comment and signature in `freertos_ivshmem_flat.c`**

Replace:

```c
/*
 * Called from vApplicationIRQHandler on GIC SPI 1 (INTID 33).
 * Reads the HELLO from IVSHMEM0 shared memory, sends ACK, rings doorbell.
 * Follows the same volatile-byte-access rules as the poll path.
 *
 * This QEMU ivshmem-flat model (hw/misc/ivshmem-flat.c) raises the GIC IRQ
 * unconditionally whenever the peer signals our eventfd — INTSTATUS/INTMASK
 * are reserved/no-op in this device revision, so the shared flag below is
 * the only real gate, same as freertos_ivshmem_poll_hello().
 */
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks)
{
```

with:

```c
/*
 * Called from vApplicationIRQHandler on GIC SPI 1/2/3 (INTID 33/34/35) for
 * the arm-linux/riscv-linux/mips-linux links respectively.
 * Reads the HELLO from the link's shared memory, sends ACK, rings doorbell.
 * Follows the same volatile-byte-access rules as the poll path.
 *
 * This QEMU ivshmem-flat model (hw/misc/ivshmem-flat.c) raises the GIC IRQ
 * unconditionally whenever the peer signals our eventfd — INTSTATUS/INTMASK
 * are reserved/no-op in this device revision, so the shared flag below is
 * the only real gate.
 */
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks,
                          uint32_t doorbell_ring_value)
{
```

- [ ] **Step 3: Replace the hardcoded doorbell-ring write with `doorbell_ring_value`**

Replace:

```c
            /* Ring doorbell (write (peer_id << 16) | vector to DOORBELL reg
             * @ offset 0xc) to notify ARM-Linux that the ACK is ready.
             * FreeRTOS joins the ivshmem-server first on this channel and is
             * peer 0 (confirmed via IVPOSITION); ARM-Linux is peer 1. Same
             * (peer_id << 16) | vector convention as boot_log.c's doorbell
             * ring, with peer_id=1 (ARM-Linux) and vector=0. */
            link->mmio_base[FREERTOS_IVSHMEM_DOORBELL / sizeof(uint32_t)] = (1U << 16) | 0U;
```

with:

```c
            /* Ring doorbell (write doorbell_ring_value = (peer_id << 16) |
             * vector to DOORBELL reg @ offset 0xc) to notify the Linux guest
             * that the ACK is ready. FreeRTOS joins each per-channel
             * ivshmem-server first and is peer 0 (confirmed via IVPOSITION);
             * the Linux guest is peer 1, vector 0 — same convention as
             * boot_log.c's doorbell ring. The caller supplies
             * doorbell_ring_value per link. */
            link->mmio_base[FREERTOS_IVSHMEM_DOORBELL / sizeof(uint32_t)] = doorbell_ring_value;
```

- [ ] **Step 4: Use `link->name` in the success log**

Replace:

```c
            log_uart(HSOC_LOG_INFO, "[irq] ivshmem0: HELLO handled via IRQ\n");
```

with:

```c
            log_uart(HSOC_LOG_INFO, "[irq] ");
            log_uart(HSOC_LOG_INFO, link->name);
            log_uart(HSOC_LOG_INFO, ": HELLO handled via IRQ\n");
```

- [ ] **Step 5: Use `link->name` in the validation-failure log**

Replace:

```c
            log_uart(HSOC_LOG_ERROR, "[irq] validation failed: magic=");
            log_hex32(HSOC_LOG_ERROR, msg.magic);
            log_uart(HSOC_LOG_ERROR, " ver=");
            log_hex32(HSOC_LOG_ERROR, msg.version);
            log_uart(HSOC_LOG_ERROR, " type=");
            log_hex32(HSOC_LOG_ERROR, msg.msg_type);
            log_uart(HSOC_LOG_ERROR, "\n");
```

with:

```c
            log_uart(HSOC_LOG_ERROR, "[irq] ");
            log_uart(HSOC_LOG_ERROR, link->name);
            log_uart(HSOC_LOG_ERROR, ": validation failed: magic=");
            log_hex32(HSOC_LOG_ERROR, msg.magic);
            log_uart(HSOC_LOG_ERROR, " ver=");
            log_hex32(HSOC_LOG_ERROR, msg.version);
            log_uart(HSOC_LOG_ERROR, " type=");
            log_hex32(HSOC_LOG_ERROR, msg.msg_type);
            log_uart(HSOC_LOG_ERROR, "\n");
```

- [ ] **Step 6: Update `freertos_main.c`'s IVSHMEM0 call site to match the new signature**

In `vApplicationIRQHandler()`, replace:

```c
        freertos_ivshmem_isr(&arm_link, &arm_count, &arm_cpu_pct, &arm_mem_pct,
                              &arm_last_hello_ticks);
```

with:

```c
        freertos_ivshmem_isr(&arm_link, &arm_count, &arm_cpu_pct, &arm_mem_pct,
                              &arm_last_hello_ticks, (1U << 16) | 0U);
```

This keeps the IVSHMEM0 path (and the build) working with the new 6-arg
signature before Task 2 adds the IVSHMEM1/2 dispatch branches.

- [ ] **Step 7: Build `freertos-r52-demo.elf` to verify compilation**

The Lima VM only mounts `~`; deploy the worktree there first, then build
inside Lima (cross-compilation happens inside the Lima VM):

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -lc 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && make freertos-r52-demo.elf'
```

Expected: compiles without errors, produces `freertos-r52-demo.elf`.

- [ ] **Step 8: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c \
        contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h \
        contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "feat(freertos): parameterize doorbell_ring_value and generalize ISR logging"
```

---

### Task 2: FreeRTOS — enable GIC SPI34/SPI35, dispatch ISR for riscv/mips links, remove dead poll path

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h`

- [ ] **Step 1: Add `R52_IVSHMEM1_INTID`/`R52_IVSHMEM2_INTID` defines**

Replace:

```c
#define R52_CAN_INTID 38U   /* CAN controller on GIC SPI 6 */
#define R52_IVSHMEM0_INTID 33U /* IVSHMEM0 on GIC SPI 1 → INTID 33 */
```

with:

```c
#define R52_CAN_INTID 38U   /* CAN controller on GIC SPI 6 */
#define R52_IVSHMEM0_INTID 33U /* IVSHMEM0 on GIC SPI 1 → INTID 33 */
#define R52_IVSHMEM1_INTID 34U /* IVSHMEM1 (riscv-linux) on GIC SPI 2 → INTID 34 */
#define R52_IVSHMEM2_INTID 35U /* IVSHMEM2 (mips-linux)  on GIC SPI 3 → INTID 35 */
```

- [ ] **Step 2: Add `gic_enable_ivshmem_spi()` helper after `vClearTickInterrupt()`**

Replace:

```c
void vClearTickInterrupt(void)
{
    /* Re-arm the down-counter for the next tick. */
    r52_write_cntp_tval(r52_tick_reload);
}

/* Called by the ARM_CR5 port's FreeRTOS_IRQ_Handler with the ICCIAR value. */
void vApplicationIRQHandler(uint32_t ulICCIAR)
```

with:

```c
void vClearTickInterrupt(void)
{
    /* Re-arm the down-counter for the next tick. */
    r52_write_cntp_tval(r52_tick_reload);
}

/*
 * Enable a GIC SPI for interrupt-driven ivshmem HELLO/ACK reception: set
 * priority, target CPU0, enable in ISENABLER, and configure edge-triggered.
 * Shared by IVSHMEM0/1/2 (INTID 33/34/35).
 */
static void gic_enable_ivshmem_spi(uint32_t intid)
{
    volatile uint8_t  *iprio   = (volatile uint8_t  *)(GICD_BASE + GICD_IPRIORITYR);
    volatile uint8_t  *itarget = (volatile uint8_t  *)(GICD_BASE + GICD_ITARGETSR);
    volatile uint32_t *isen    = (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);
    volatile uint32_t *icfgr   = (volatile uint32_t *)(GICD_BASE + GICD_ICFGR);

    iprio[intid]   = 0xA0;
    itarget[intid] = 0x01;
    /* |= (not =) — GICD_ISENABLERn words are shared across IVSHMEM0/1/2's
     * INTIDs (33/34/35) and R52_CAN_INTID (38), already enabled by
     * can_init() above; preserve those bits. */
    isen[intid / 32] |= (1U << (intid % 32));
    /* Configure intid as edge-triggered (GICD_ICFGRn, the Int_config[1] bit
     * at bit ((intid%16)*2)+1). ivshmem-flat signals via qemu_irq_pulse(): a
     * momentary raise+lower with no sustained level. QEMU's GIC only latches
     * a pending bit on this pulse for edge-triggered IRQs
     * (gic_set_irq_generic); left at the default level-sensitive config, the
     * pulse's immediate de-assert clears the CPU interrupt line before the
     * vCPU observes it and the SPI is never delivered. |= preserves other
     * IVSHMEM SPIs' and R52_CAN_INTID's (38) config bits sharing the same
     * ICFGR word. */
    icfgr[intid / 16] |= (1U << (((intid % 16) * 2) + 1));
}

/* Called by the ARM_CR5 port's FreeRTOS_IRQ_Handler with the ICCIAR value. */
void vApplicationIRQHandler(uint32_t ulICCIAR)
```

- [ ] **Step 3: Replace the inline SPI33-enable block in `showcase_task()` with three helper calls**

Replace:

```c
    /* Enable IVSHMEM0 GIC SPI for interrupt-driven HELLO reception.
     * Same gic_enable_spi() pattern as can_driver.c. The GICD_CTLR group-0
     * forwarding is already enabled by vConfigureTickInterrupt(). */
    {
        volatile uint8_t  *iprio   = (volatile uint8_t  *)(GICD_BASE + GICD_IPRIORITYR);
        volatile uint8_t  *itarget = (volatile uint8_t  *)(GICD_BASE + GICD_ITARGETSR);
        volatile uint32_t *isen   = (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);
        volatile uint32_t *icfgr  = (volatile uint32_t *)(GICD_BASE + GICD_ICFGR);
        uint32_t intid = R52_IVSHMEM0_INTID;

        iprio[intid]   = 0xA0;
        itarget[intid] = 0x01;
        /* |= (not =) — GICD_ISENABLER1 is shared with CAN_INTID (38),
         * already enabled by can_init() above; preserve that bit. */
        isen[intid / 32] |= (1U << (intid % 32));
        /* Configure INTID 33 as edge-triggered (GICD_ICFGR2 bit 3 — the
         * Int_config[1] bit for IRQ 33, at bit ((33%16)*2)+1). ivshmem-flat
         * signals via qemu_irq_pulse(): a momentary raise+lower with no
         * sustained level. QEMU's GIC only latches a pending bit on this
         * pulse for edge-triggered IRQs (gic_set_irq_generic); left at the
         * default level-sensitive config, the pulse's immediate de-assert
         * clears the CPU interrupt line before the vCPU observes it and the
         * SPI is never delivered. |= preserves CAN_INTID's (38) config bit,
         * also in ICFGR2. */
        icfgr[intid / 16] |= (1U << (((intid % 16) * 2) + 1));
    }
```

with:

```c
    /* Enable IVSHMEM0/1/2 GIC SPIs for interrupt-driven HELLO reception.
     * The GICD_CTLR group-0 forwarding is already enabled by
     * vConfigureTickInterrupt(). */
    gic_enable_ivshmem_spi(R52_IVSHMEM0_INTID);
    gic_enable_ivshmem_spi(R52_IVSHMEM1_INTID);
    gic_enable_ivshmem_spi(R52_IVSHMEM2_INTID);
```

- [ ] **Step 4: Add SPI34/SPI35 dispatch branches and remove the stale trailing comment**

Replace:

```c
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t intid = ulICCIAR & 0x3FFU;

    if (intid == R52_TICK_INTID) {
        FreeRTOS_Tick_Handler();
    } else if (intid == R52_CAN_INTID) {
        can_rx_isr();
    } else if (intid == R52_IVSHMEM0_INTID) {
        log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem0: SPI33 dispatched\n");
        freertos_ivshmem_isr(&arm_link, &arm_count, &arm_cpu_pct, &arm_mem_pct,
                              &arm_last_hello_ticks, (1U << 16) | 0U);
    } else {
        log_uart(HSOC_LOG_WARN, "[irq] unexpected intid=");
        log_hex32_uart(HSOC_LOG_WARN, intid);
        log_uart(HSOC_LOG_WARN, "\n");
    }
    /* Other ivshmem channels (RISCV/MIPS/stats) remain flag-polled; their
     * IRQs (if any fire) are ignored. */
}
```

with:

```c
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t intid = ulICCIAR & 0x3FFU;

    if (intid == R52_TICK_INTID) {
        FreeRTOS_Tick_Handler();
    } else if (intid == R52_CAN_INTID) {
        can_rx_isr();
    } else if (intid == R52_IVSHMEM0_INTID) {
        log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem0: SPI33 dispatched\n");
        freertos_ivshmem_isr(&arm_link, &arm_count, &arm_cpu_pct, &arm_mem_pct,
                              &arm_last_hello_ticks, (1U << 16) | 0U);
    } else if (intid == R52_IVSHMEM1_INTID) {
        log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem1: SPI34 dispatched\n");
        freertos_ivshmem_isr(&riscv_link, &riscv_count, &riscv_cpu_pct, &riscv_mem_pct,
                              &riscv_last_hello_ticks, (1U << 16) | 0U);
    } else if (intid == R52_IVSHMEM2_INTID) {
        log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem2: SPI35 dispatched\n");
        freertos_ivshmem_isr(&mips_link, &mips_count, &mips_cpu_pct, &mips_mem_pct,
                              &mips_last_hello_ticks, (1U << 16) | 0U);
    } else {
        log_uart(HSOC_LOG_WARN, "[irq] unexpected intid=");
        log_hex32_uart(HSOC_LOG_WARN, intid);
        log_uart(HSOC_LOG_WARN, "\n");
    }
}
```

- [ ] **Step 5: Remove `riscv_link`/`mips_link` poll-loop calls in `showcase_task()`**

Replace:

```c
    for (;;) {
        /* arm_link is serviced by freertos_ivshmem_isr() (interrupt-driven);
         * polling it here would race the ISR for the linux_to_freertos.flag. */
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n",
                           &riscv_count, &riscv_cpu_pct, &riscv_mem_pct, &riscv_last_hello_ticks);
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n",
                           &mips_count, &mips_cpu_pct, &mips_mem_pct, &mips_last_hello_ticks);

        if (++stats_tick >= 5000) {
```

with:

```c
    for (;;) {
        /* arm_link, riscv_link, and mips_link are all serviced by
         * freertos_ivshmem_isr() (interrupt-driven); polling them here would
         * race the ISR for linux_to_freertos.flag. */

        if (++stats_tick >= 5000) {
```

- [ ] **Step 6: Remove the now-dead `maybe_service_link()`**

Replace:

```c

static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count,
                               uint32_t *cpu_pct,
                               uint32_t *mem_pct,
                               TickType_t *last_hello_ticks)
{
    struct hsoc_hello_msg hello;
    int64_t ts_sec;
    int64_t ts_nsec;

    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }

    tick_to_timestamp(&ts_sec, &ts_nsec);
    log_uart(HSOC_LOG_VERBOSE, log_message);
    freertos_ivshmem_send_ack(link, hello.seq, ts_sec, ts_nsec);
    (*count)++;
    *cpu_pct = hello.cpu_pct_x100;
    *mem_pct = hello.mem_used_pct_x100;
    *last_hello_ticks = xTaskGetTickCount();
}

void log_hex32_uart(uint32_t level, uint32_t v)
```

with:

```c

void log_hex32_uart(uint32_t level, uint32_t v)
```

`tick_to_timestamp()` remains used by `write_stats_snapshot()` — do not remove it.

- [ ] **Step 7: Fix the stats-bookkeeping comment's reference to the removed `maybe_service_link()`**

In `freertos_ivshmem_flat.c`, replace:

```c
            /* Update the caller's stats/heartbeat bookkeeping, mirroring
             * maybe_service_link()'s poll-path behavior. The ISR now always
             * wins the flag-clear race, so the poll path never observes a
             * HELLO on this link and these counters would otherwise stay
             * frozen at zero. */
```

with:

```c
            /* Update the caller's stats/heartbeat bookkeeping, mirroring the
             * old poll path's behavior. The ISR now always wins the
             * flag-clear race, so the poll path never observes a HELLO on
             * this link and these counters would otherwise stay frozen at
             * zero. */
```

- [ ] **Step 8: Remove the now-dead `freertos_ivshmem_poll_hello()` from `freertos_ivshmem_flat.c`**

Replace:

```c

int freertos_ivshmem_poll_hello(struct freertos_ivshmem_link *link,
                                struct hsoc_hello_msg *msg)
{
    if (link->layout->linux_to_freertos.flag != 1) {
        return 0;
    }

    log_uart(HSOC_LOG_VERBOSE, "[diag] flag=1 on ");
    log_uart(HSOC_LOG_VERBOSE, link->name);
    log_uart(HSOC_LOG_VERBOSE, "\n");

    __sync_synchronize();
    shmem_read(msg, &link->layout->linux_to_freertos.msg, sizeof(*msg));
    link->layout->linux_to_freertos.flag = 0;
    __sync_synchronize();

    if (msg->magic != HSOC_HELLO_MAGIC ||
        msg->version != HSOC_PROTO_VERSION ||
        msg->msg_type != HSOC_MSG_HELLO) {
        log_uart(HSOC_LOG_ERROR, "[diag] validation failed: magic=");
        log_hex32(HSOC_LOG_ERROR, msg->magic);
        log_uart(HSOC_LOG_ERROR, " ver=");
        log_hex32(HSOC_LOG_ERROR, msg->version);
        log_uart(HSOC_LOG_ERROR, " type=");
        log_hex32(HSOC_LOG_ERROR, msg->msg_type);
        log_uart(HSOC_LOG_ERROR, "\n");
        return 0;
    }

    return 1;
}

void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
```

with:

```c

void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
```

- [ ] **Step 9: Remove the `freertos_ivshmem_poll_hello()` declaration from `freertos_ivshmem_flat.h`**

Replace:

```c
                           const char *name);
int freertos_ivshmem_poll_hello(struct freertos_ivshmem_link *link,
                                struct hsoc_hello_msg *msg);
void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
```

with:

```c
                           const char *name);
void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
```

- [ ] **Step 10: Rebuild `freertos-r52-demo.elf` to verify**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -lc 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && make freertos-r52-demo.elf'
```

Expected: compiles without errors. No "defined but not used" warnings for
`maybe_service_link`/`freertos_ivshmem_poll_hello` (they're gone), and no
"implicit declaration" errors for the new dispatch branches.

- [ ] **Step 11: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c \
        contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c \
        contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h
git commit -m "feat(freertos): activate doorbell IRQ for ivshmem1/2, remove dead poll path"
```

---

### Task 3: Linux — enable doorbell/IRQ path for riscv-linux and mips-linux syslog daemons

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c`

- [ ] **Step 1: Remove the ARM-Linux-only gate and rewrite the doc comment**

Replace:

```c
/*
 * Initialize the doorbell path:
 *   1. mmap BAR0/resource0 for doorbell writes (send direction, no UIO needed)
 *   2. Bind the device to uio_pci_generic and open /dev/uio0 for interrupt
 *      receive (optional — if it fails, fall back to poll)
 * Returns 0 on success, -1 on failure (caller degrades gracefully).
 *
 * Doorbell/IRQ support is ARM-Linux-only: FreeRTOS's ISR only rings the
 * ARM<->FreeRTOS channel's doorbell. RISCV/MIPS builds skip this entirely
 * (busy-wait poll, unchanged) — without this guard, find_ivshmem_doorbell()
 * would still locate *their own* syslog ivshmem device (also vendor 0x1af4,
 * no STATS/BOOTLOG/CAN magic), bind UIO, and hybrid_wait_ack() would then
 * burn 200ms per HELLO/ACK cycle waiting for a doorbell IRQ that never
 * arrives before falling back to the flag check.
 */
static int doorbell_init(void)
{
    char res0_path[PATH_MAX];
    const char *bdf = getenv("IVSHMEM_BDF");
    int fd;

    if (HSOC_SENDER_ID != HSOC_SENDER_ARM_LINUX) {
        return -1;
    }

    if (!bdf) {
```

with:

```c
/*
 * Initialize the doorbell path:
 *   1. mmap BAR0/resource0 for doorbell writes (send direction, no UIO needed)
 *   2. Bind the device to uio_pci_generic and open /dev/uio0 for interrupt
 *      receive (optional — if it fails, fall back to poll)
 * Returns 0 on success, -1 on failure (caller degrades gracefully).
 *
 * Doorbell/IRQ support applies to all three senders (arm-linux,
 * riscv-linux, mips-linux): FreeRTOS's ISR rings each link's own
 * per-channel doorbell (see freertos_ivshmem_isr()'s doorbell_ring_value
 * parameter), so find_ivshmem_doorbell() locating *this guest's own* syslog
 * channel (excluding its BOOTLOG-magic channel) is exactly the right device
 * to bind UIO to.
 */
static int doorbell_init(void)
{
    char res0_path[PATH_MAX];
    const char *bdf = getenv("IVSHMEM_BDF");
    int fd;

    if (!bdf) {
```

- [ ] **Step 2: Build all three syslog daemons to verify**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -lc 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && make syslog-arm-linux syslog-riscv-linux syslog-mips-linux'
```

Expected: all three compile without errors. No `-Wunused-parameter` regression
for `HSOC_SENDER_ID` (it's still used elsewhere in the file for the ACK
sender-id field and log label).

- [ ] **Step 3: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c
git commit -m "feat(linux): enable doorbell/IRQ ACK path for riscv-linux and mips-linux"
```

---

### Task 4: Docs — generalize doorbell IRQ design and channel map to IVSHMEM0/1/2

**Files:**
- Modify: `docs/superpowers/specs/2026-06-10-doorbell-irq-design.md`
- Modify: `README.md`

- [ ] **Step 1: Generalize "Three concurrent mechanisms" in the design doc**

In `docs/superpowers/specs/2026-06-10-doorbell-irq-design.md`, replace:

```
**Three concurrent mechanisms, highest wins:**
1. **Interrupt (primary):** ARM-Linux writes HELLO flag, rings doorbell → FreeRTOS GIC IRQ fires → ISR reads HELLO, sends ACK, rings DOORBELL → ARM-Linux UIO `read()` returns → daemon reads ACK
2. **Poll fallback (ARM-Linux):** `ppoll()` on `/dev/uio0` with 200 ms timeout. If doorbell IRQ arrives: immediate return. If not: timeout fires, daemon reads the ACK flag directly from shared memory
3. **Poll fallback (FreeRTOS):** Main task poll loop runs every ~10 ms (relaxed from today's 1 ms) as a watchdog. If ISR already handled the channel, poll skips it
```

with:

```
**Three concurrent mechanisms, highest wins:**
1. **Interrupt (primary):** The Linux guest (ARM/RISCV/MIPS) writes HELLO flag, rings doorbell → FreeRTOS GIC IRQ fires → ISR reads HELLO, sends ACK, rings DOORBELL → Linux UIO `read()` returns → daemon reads ACK
2. **Poll fallback (Linux):** `ppoll()` on `/dev/uio0` with 200 ms timeout. If doorbell IRQ arrives: immediate return. If not: timeout fires, daemon reads the ACK flag directly from shared memory
3. **Poll fallback (FreeRTOS):** Main task poll loop runs every ~10 ms (relaxed from today's 1 ms) as a watchdog. If ISR already handled the channel, poll skips it
```

- [ ] **Step 2: Update the "ivshmem Channel Map (updated)" table in the design doc**

Replace:

```
## ivshmem Channel Map (updated)

| Channel | MMIO | SHMEM | SPI | INTID | Mechanism |
|---------|------|-------|-----|-------|-----------|
| **IVSHMEM0** | 0x30000000 | 0x31000000 | 1 | 33 | **Interrupt + 200ms poll** |
| IVSHMEM1 | 0x35000000 | 0x36000000 | 2 | 34 | Poll only (RISCV) |
| IVSHMEM2 | 0x3A000000 | 0x3B000000 | 3 | 35 | Poll only (MIPS) |
| IVSHMEM3 | 0x3F000000 | 0x40000000 | 4 | 36 | Stats FreeRTOS→ARM (poll) |
| IVSHMEM4 | 0x44000000 | 0x45000000 | 5 | 37 | Boot log (poll) |
| IVSHMEM5 | 0x49000000 | 0x4A000000 | 7 | 39 | CAN frames FreeRTOS→ARM (poll) |
```

with:

```
## ivshmem Channel Map (updated)

| Channel | MMIO | SHMEM | SPI | INTID | Mechanism |
|---------|------|-------|-----|-------|-----------|
| IVSHMEM0 | 0x30000000 | 0x31000000 | 1 | 33 | Interrupt + 200ms poll |
| IVSHMEM1 | 0x35000000 | 0x36000000 | 2 | 34 | Interrupt + 200ms poll |
| IVSHMEM2 | 0x3A000000 | 0x3B000000 | 3 | 35 | Interrupt + 200ms poll |
| IVSHMEM3 | 0x3F000000 | 0x40000000 | 4 | 36 | Stats FreeRTOS→ARM (poll) |
| IVSHMEM4 | 0x44000000 | 0x45000000 | 5 | 37 | Boot log (poll) |
| IVSHMEM5 | 0x49000000 | 0x4A000000 | 7 | 39 | CAN frames FreeRTOS→ARM (poll) |
```

- [ ] **Step 3: Update README.md's "Signaling" sentence**

In `README.md`, replace:

```
**Signaling:** The HELLO/ACK and stats channels use pure shared-memory polling — Linux and FreeRTOS poll `flag`/`generation` fields in shared memory; no doorbell is involved. The 4 vectors on these channels are vestigial.
```

with:

```
**Signaling:** The HELLO/ACK channels (IVSHMEM0/1/2) are interrupt-driven: each Linux guest's `ivshmem-doorbell` rings FreeRTOS's `ivshmem-flat` DOORBELL register on HELLO, and FreeRTOS's ISR rings the guest's doorbell after sending ACK; each side falls back to a 200ms/10ms poll of `flag` fields if the IRQ doesn't fire. The stats channel (IVSHMEM3) still uses pure shared-memory polling — FreeRTOS and ARM-Linux poll `flag`/`generation` fields; no doorbell is involved there.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-10-doorbell-irq-design.md README.md
git commit -m "docs: generalize doorbell IRQ design and channel map to IVSHMEM0/1/2"
```

---

### Task 5: Integration test (Lima)

No source changes expected in this task unless testing surfaces a bug — in
that case, fix it, re-run the failing step, and commit the fix at Step 8.

- [ ] **Step 1: Deploy the worktree to the Lima VM**

Run from the worktree root (so `CHIMERA_ROOT` resolves to this worktree and
gets rsynced to `~/chimera-src` in Lima):

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
```

Expected: "Source tree deployed to ~/chimera-src" (or VM creation output if
the Lima VM didn't exist yet).

- [ ] **Step 2: Build everything and launch the showcase**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

This builds `freertos-r52-demo.elf` and all three `syslog-*-linux` binaries,
injects them into the guest disk images (including UIO binding for each
guest's ivshmem-doorbell), and opens the `freertos-showcase` tmux session
(panes 0.0–0.4 = ivshmem servers, 0.5 = FreeRTOS, 0.6 = ARM-Linux, 0.7 =
RISCV-Linux, 0.8 = MIPS-Linux). Guest boot takes several minutes — wait for
all three Linux guests to reach a login prompt before continuing.

- [ ] **Step 3: Verify FreeRTOS UART shows SPI34/SPI35 dispatch and IRQ-handled lines**

```bash
limactl shell qemu-dev -- tmux capture-pane -p -S -1000 -t freertos-showcase:0.5 | grep -iE "ivshmem1|ivshmem2|riscv-linux|mips-linux"
```

Expected: lines like `[irq] ivshmem1: SPI34 dispatched`, `[irq]
riscv-linux: HELLO handled via IRQ`, `[irq] ivshmem2: SPI35 dispatched`,
`[irq] mips-linux: HELLO handled via IRQ`.

- [ ] **Step 4: Check the IVPOSITION diagnostic**

```bash
limactl shell qemu-dev -- tmux capture-pane -p -S -1000 -t freertos-showcase:0.5 | grep -iE "ivposition|riscv=|mips="
```

Expected: `riscv=0` and `mips=0` (validates the `(1U<<16)|0U` doorbell-ring
constants used for `riscv_link`/`mips_link` — see the spec's "Peer ID
assumption"). If either is non-zero, fix the corresponding
`vApplicationIRQHandler()` call site's `doorbell_ring_value` argument (a
one-line change), rebuild, and re-test from Step 2.

- [ ] **Step 5: Confirm ACK sequence numbers increment on all three guests**

```bash
for port in 2222 2223 2224; do
  echo "=== port $port ==="
  limactl shell qemu-dev -- ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'tail -3 /var/log/chimera-log/chimera-cross-domain.log'
done
```

Wait a few seconds, then re-run the same command and confirm the ACK `#N`
sequence numbers in each guest's log have increased.

- [ ] **Step 6: Check riscv-linux/mips-linux syslog daemon doorbell init**

```bash
limactl shell qemu-dev -- tmux capture-pane -p -S -500 -t freertos-showcase:0.7 | grep -i doorbell
limactl shell qemu-dev -- tmux capture-pane -p -S -500 -t freertos-showcase:0.8 | grep -i doorbell
```

Expected: `doorbell: init OK (uio_fd=N, bdf=...)`. If `uio_fd=-1` on either
guest, `uio_pci_generic` bind failed — confirm Step 5 still shows ACKs
arriving (busy-wait fallback, no regression per the spec's "Risks" section).

- [ ] **Step 7: Regression — CAN bus, stats snapshots, boot-log collection**

```bash
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'tail -5 /var/log/chimera-log/can-bus.log'
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'ls -la /var/log/chimera-log/boot-log/'
limactl shell qemu-dev -- tmux capture-pane -p -S -200 -t freertos-showcase:0.5 | grep -i "stats snapshot"
```

Expected: CAN log has recent frames, boot-log directory has entries for all
four guests, and `[freertos] stats snapshot written` lines continue to
appear.

- [ ] **Step 8: Commit any fixes found during testing**

Only if Steps 3–7 required a code change:

```bash
git add -A
git commit -m "fix: address integration test findings for ivshmem1/2 doorbell IRQ"
```

---
