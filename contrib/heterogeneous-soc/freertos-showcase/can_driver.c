/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "can_driver.h"
#include "can_proto.h"
#include "freertos_ivshmem_flat.h"   /* for HSOC_LOG_* levels */

extern void log_uart(uint32_t level, const char *msg);

/* ---- GIC distributor MMIO (GICv2, matches freertos_main.c constants) ---- */
#define GICD_BASE          0x08000000UL
#define GICD_ISENABLER     0x100U   /* +(intid/32)*4, bit intid%32 */
#define GICD_IPRIORITYR    0x400U   /* byte per intid */
#define GICD_ITARGETSR     0x800U   /* byte per intid (CPU target bitmask) */

#define CAN_INTID          38U      /* SPI 6 = INTID 32 + 6 */

static volatile uint32_t *can_regs;          /* CAN MMIO window */
static volatile struct can_ivshmem_layout *can_ivshmem;

static inline uint32_t can_rd(uint32_t off)
{
    return can_regs[off / sizeof(uint32_t)];
}

static inline void can_wr(uint32_t off, uint32_t val)
{
    can_regs[off / sizeof(uint32_t)] = val;
}

static void shmem_write_bytes(volatile void *dst, const void *src, uint32_t n)
{
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    uint32_t i;

    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static void gic_enable_spi(uint32_t intid)
{
    volatile uint32_t *isen =
        (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);
    volatile uint8_t *iprio =
        (volatile uint8_t *)(GICD_BASE + GICD_IPRIORITYR);
    volatile uint8_t *itarget =
        (volatile uint8_t *)(GICD_BASE + GICD_ITARGETSR);

    /* Same mid priority the timer tick uses; route to CPU 0. SPIs (unlike the
     * banked timer PPI) need an explicit ITARGETSR target or they never reach
     * a CPU interface. GICD_CTLR group-0 forwarding is already enabled by the
     * tick setup in vConfigureTickInterrupt(). */
    iprio[intid] = 0xA0;
    itarget[intid] = 0x01;
    isen[intid / 32] = (1U << (intid % 32));
}

void can_init(uintptr_t can_mmio_base, uintptr_t ivshmem_can_shmem_base)
{
    can_regs = (volatile uint32_t *)can_mmio_base;
    can_ivshmem =
        (volatile struct can_ivshmem_layout *)ivshmem_can_shmem_base;

    /* Publish the channel identity once so the ARM-Linux daemon can find this
     * BAR2 by magic, then zero the generation counter.
     *
     * When the CAN ivshmem channel is not instantiated in QEMU these
     * writes raise a synchronous external abort.  The data-abort handler
     * (startup.S) skips the faulting store and returns to the next
     * instruction, so the entire function completes harmlessly whether
     * the hardware is present or not. */
    can_ivshmem->magic = CAN_IVSHMEM_MAGIC;
    can_ivshmem->generation = 0;
    __sync_synchronize();

    /* Normal mode (MSR=0 at reset), enable controller, enable RX-OK IRQ. */
    can_wr(CAN_REG_MSR, 0);
    can_wr(CAN_REG_SRR, CAN_SRR_CEN);
    can_wr(CAN_REG_IER, CAN_ISR_RXOK);

    /*
     * Clear any pending interrupts before enabling the GIC SPI.
     * Without this, a spurious pending interrupt (which can occur when
     * no CAN bus is attached to the QEMU model) may cause an interrupt
     * storm that pegs the CPU at 100 %.
     */
    can_wr(CAN_REG_ICR, can_rd(CAN_REG_ISR));
    __sync_synchronize();

    gic_enable_spi(CAN_INTID);

    log_uart(HSOC_LOG_INFO, "[freertos] CAN controller enabled (SPI 6)\n");
}

void can_rx_isr(void)
{
    uint32_t isr = can_rd(CAN_REG_ISR);
    struct can_ivshmem_frame f;
    uint32_t id_reg, dlc_reg, d1, d2;
    uint32_t i;

    if (!(isr & CAN_ISR_RXOK)) {
        return;
    }

    /* Read RXFIFO_ID FIRST: that read pops the frame and latches DLC/D1/D2. */
    id_reg  = can_rd(CAN_REG_RXFIFO_ID);
    dlc_reg = can_rd(CAN_REG_RXFIFO_DLC);
    d1      = can_rd(CAN_REG_RXFIFO_D1);
    d2      = can_rd(CAN_REG_RXFIFO_D2);

    /* Acknowledge the interrupt (CRXOK is bit 4 of ICR). */
    can_wr(CAN_REG_ICR, CAN_ISR_RXOK);

    f.id  = can_decode_id(id_reg);
    f.dlc = (uint8_t)can_decode_dlc(dlc_reg);
    f.pad[0] = f.pad[1] = f.pad[2] = 0;
    can_decode_data(d1, d2, f.data);

    /* UART: "CAN RX: id=0x123 dlc=4 data=de ad be ef\n", built into one
     * buffer and emitted via a single log_uart() call so the line isn't
     * interleaved with a separate [timestamp] [LEVEL] prefix per fragment. */
    {
        static const char hex[] = "0123456789abcdef";
        char line[64];
        uint32_t p = 0;
        const char *s;

        for (s = "CAN RX: id=0x"; *s != '\0'; s++) {
            line[p++] = *s;
        }
        line[p++] = hex[(f.id >> 8) & 0xf]; /* high nibble of 11-bit id */
        line[p++] = hex[(f.id >> 4) & 0xf];
        line[p++] = hex[f.id & 0xf];
        for (s = " dlc="; *s != '\0'; s++) {
            line[p++] = *s;
        }
        line[p++] = (char)('0' + f.dlc);
        for (s = " data="; *s != '\0'; s++) {
            line[p++] = *s;
        }
        for (i = 0; i < f.dlc; i++) {
            line[p++] = hex[(f.data[i] >> 4) & 0xf];
            line[p++] = hex[f.data[i] & 0xf];
            if (i + 1 < f.dlc) {
                line[p++] = ' ';
            }
        }
        line[p++] = '\n';
        line[p] = '\0';

        log_uart(HSOC_LOG_INFO, line);
    }

    /* Publish to IVSHMEM5: write the frame body, fence, then bump generation. */
    shmem_write_bytes(&can_ivshmem->frame, &f, sizeof(f));
    __sync_synchronize();
    can_ivshmem->generation = can_ivshmem->generation + 1;
    __sync_synchronize();
}

void can_get_status(struct can_status *out)
{
    out->sr = can_rd(CAN_REG_SR);
    out->rx_frames = can_ivshmem->generation;
}
