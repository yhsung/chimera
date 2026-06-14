/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "uart_driver.h"

#define UART0_BASE 0x10000000UL
#define PL011_DR    0x00U  /* data register */
#define PL011_FR    0x18U  /* flag register */
#define PL011_IMSC  0x38U  /* interrupt mask set/clear register */

#define PL011_FR_RXFE 0x10U  /* receive FIFO empty */
#define PL011_FR_TXFF 0x20U  /* transmit FIFO full */
#define PL011_INT_RX  0x10U  /* RX interrupt (UARTRIS/UARTIMSC bit 4) */

#define GICD_BASE       0x08000000UL
#define GICD_ISENABLER  0x100U  /* +(intid/32)*4 */
#define GICD_IPRIORITYR 0x400U  /* +intid */
#define GICD_ITARGETSR  0x800U  /* byte per intid */

#define UART_RX_QUEUE_LEN 64

QueueHandle_t uart_rx_queue;

void uart_putc(char ch)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);

    while ((*fr & PL011_FR_TXFF) != 0) {
    }

    *dr = (uint32_t)(uint8_t)ch;
}

static void gic_enable_uart_rx_spi(void)
{
    volatile uint8_t  *iprio   = (volatile uint8_t  *)(GICD_BASE + GICD_IPRIORITYR);
    volatile uint8_t  *itarget = (volatile uint8_t  *)(GICD_BASE + GICD_ITARGETSR);
    volatile uint32_t *isen    = (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);

    /* Same mid priority/target-CPU0 convention as the other SPIs enabled in
     * freertos_main.c and can_driver.c. PL011's combined IRQ is a sustained
     * level (pl011_update() calls qemu_set_irq(level)), and GIC SPIs default
     * to level-sensitive, so unlike the edge-configured ivshmem doorbell
     * SPIs, GICD_ICFGR is left untouched here. */
    iprio[R52_UART_INTID]   = 0xA0;
    itarget[R52_UART_INTID] = 0x01;
    isen[R52_UART_INTID / 32] |= (1U << (R52_UART_INTID % 32));
}

void uart_init_rx(void)
{
    volatile uint32_t *imsc = (volatile uint32_t *)(UART0_BASE + PL011_IMSC);

    uart_rx_queue = xQueueCreate(UART_RX_QUEUE_LEN, sizeof(uint8_t));

    /* Enable only the RX interrupt source, so TX-complete events (INT_TX)
     * don't spuriously assert the combined IRQ line. */
    *imsc |= PL011_INT_RX;

    gic_enable_uart_rx_spi();
}

void uart_rx_isr(void)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);
    BaseType_t higher_priority_task_woken = pdFALSE;

    while ((*fr & PL011_FR_RXFE) == 0) {
        uint8_t byte = (uint8_t)(*dr & 0xFFU);
        xQueueSendFromISR(uart_rx_queue, &byte, &higher_priority_task_woken);
    }

    portYIELD_FROM_ISR(higher_priority_task_woken);
}
