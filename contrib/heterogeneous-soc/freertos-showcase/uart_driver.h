/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_UART_DRIVER_H
#define HETEROGENEOUS_SOC_FREERTOS_UART_DRIVER_H

#include <stdint.h>

#include "FreeRTOS.h"
#include "queue.h"

/* GIC SPI for UART0 (PL011), CHIMERA_R52_FREERTOS_UART_SPI = 0 -> INTID 32. */
#define R52_UART_INTID 32U

/* RX byte queue, created by uart_init_rx(). shell_task() blocks on this. */
extern QueueHandle_t uart_rx_queue;

/* Write one character to UART0 (PL011 UARTDR), busy-waiting while TXFF. */
void uart_putc(char ch);

/* Enable PL011 RX interrupt (UARTIMSC.RX) and GIC SPI32 (level-sensitive,
 * priority 0xA0, target CPU0). Creates uart_rx_queue. Call once from
 * showcase_task's init, after the tick interrupt is configured. */
void uart_init_rx(void);

/* Called from vApplicationIRQHandler when intid == R52_UART_INTID (32).
 * Drains UARTDR while !(UARTFR & RXFE), pushing each byte to
 * uart_rx_queue via xQueueSendFromISR(). */
void uart_rx_isr(void);

#endif
