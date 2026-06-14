/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_BOOT_LOG_H
#define HETEROGENEOUS_SOC_FREERTOS_BOOT_LOG_H

#include <stdint.h>

#include "bootlog_proto.h"
#include "freertos_ivshmem_flat.h"

struct bootlog_monitor {
    struct freertos_ivshmem_link link;
    volatile struct hsoc_bootlog_header *header;
    int64_t    boot_tick;
    uint8_t    armed;
    uint8_t    initialized;
    uint32_t   slot_offset;
};

void bootlog_init(struct bootlog_monitor *m,
                  uintptr_t mmio_base, uintptr_t shmem_base,
                  const char *name);

/* Call once per main-loop iteration (~1 ms). Returns 1 if doorbell was rung. */
int bootlog_tick(struct bootlog_monitor *m);

/* Returns 1 once all Linux guests have reported HSOC_BOOT_COMPLETE. */
int bootlog_all_booted(struct bootlog_monitor *m);

/* Append a message to the FreeRTOS boot-log slot.  Safe to call before
 * bootlog_init() — the message is dropped silently. */
void bootlog_write(struct bootlog_monitor *m, const char *msg);

#endif
