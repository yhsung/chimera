/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_CAN_DRIVER_H
#define HETEROGENEOUS_SOC_FREERTOS_CAN_DRIVER_H

#include <stdint.h>

/* xlnx-zynqmp-can register offsets (see hw/net/can/xlnx-zynqmp-can.c). */
#define CAN_REG_SRR        0x00U   /* SoftwareResetRegister: bit1 CEN, bit0 SRST */
#define CAN_REG_MSR        0x04U   /* ModeSelectRegister (0 = normal) */
#define CAN_REG_SR         0x18U   /* StatusRegister */
#define CAN_REG_ISR        0x1CU   /* InterruptStatusRegister */
#define CAN_REG_IER        0x20U   /* InterruptEnableRegister */
#define CAN_REG_ICR        0x24U   /* InterruptClearRegister */
#define CAN_REG_RXFIFO_ID  0x50U   /* reading this pops the whole RX frame */
#define CAN_REG_RXFIFO_DLC 0x54U
#define CAN_REG_RXFIFO_D1  0x58U
#define CAN_REG_RXFIFO_D2  0x5CU

#define CAN_SRR_CEN        (1U << 1)   /* controller enable */
#define CAN_ISR_RXOK       (1U << 4)   /* RX-OK / ERXOK / CRXOK all bit 4 */

/* Initialise the CAN controller, enable its GIC SPI, and prepare the
 * IVSHMEM5 forwarding channel. Call once, before the scheduler relies on it. */
void can_init(uintptr_t can_mmio_base, uintptr_t ivshmem_can_shmem_base);

/* Called from vApplicationIRQHandler when INTID 38 (CAN SPI 6) fires. */
void can_rx_isr(void);

struct can_status {
    uint32_t sr;        /* CAN_REG_SR (StatusRegister) */
    uint32_t rx_frames; /* can_ivshmem->generation (frames forwarded) */
};

/* Snapshot of CAN controller status, for the shell's `can status` command. */
void can_get_status(struct can_status *out);

#endif
