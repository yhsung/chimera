/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_SHELL_H
#define HETEROGENEOUS_SOC_FREERTOS_SHELL_H

#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"

#define CHIMERA_SHELL_NUM_GUESTS 3

struct chimera_shell_guest {
    const char *name;
    const struct freertos_ivshmem_link *link;
    const uint32_t *hello_count;
    const uint32_t *cpu_pct_x100;
    const uint32_t *mem_pct_x100;
    const TickType_t *last_hello_ticks;
};

struct chimera_shell_ctx {
    struct chimera_shell_guest guests[CHIMERA_SHELL_NUM_GUESTS];
    TaskHandle_t showcase_task_handle;
};

/*
 * Create the shell task (priority tskIDLE_PRIORITY+1, 1024-word stack).
 * Calls uart_init_rx() internally to enable UART RX interrupts.
 * `ctx` must remain valid for the lifetime of the shell task — pass a
 * pointer to a static/file-scope struct.
 */
void shell_init(const struct chimera_shell_ctx *ctx);

#endif
