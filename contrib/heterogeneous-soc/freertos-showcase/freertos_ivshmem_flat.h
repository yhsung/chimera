/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_IVSHMEM_FLAT_H
#define HETEROGENEOUS_SOC_FREERTOS_IVSHMEM_FLAT_H

#include <stdint.h>

#include "hello_proto.h"

#define FREERTOS_IVSHMEM_INTMASK 0x0
#define FREERTOS_IVSHMEM_INTSTATUS 0x4
#define FREERTOS_IVSHMEM_IVPOSITION 0x8
#define FREERTOS_IVSHMEM_DOORBELL 0xc

/* Log severity levels for log_uart / log_hex32_uart */
enum hsoc_log_level {
    HSOC_LOG_VERBOSE = 0,
    HSOC_LOG_INFO    = 1,
    HSOC_LOG_WARN    = 2,
    HSOC_LOG_ERROR   = 3,
};

struct freertos_ivshmem_link {
    volatile uint32_t *mmio_base;
    struct hsoc_layout *layout;
    const char *name;
    /* This device's IVPOSITION (peer ID) on this link, latched at init time.
     * Connection order to each per-channel ivshmem-server is a race between
     * this QEMU process and the Linux guest's QEMU process, so FreeRTOS is
     * not guaranteed to be peer 0 on every link. */
    uint32_t own_id;
};

void freertos_ivshmem_init(struct freertos_ivshmem_link *link,
                           uintptr_t mmio_base,
                           uintptr_t shmem_base,
                           const char *name);
void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
                               uint32_t seq,
                               int64_t ts_sec,
                               int64_t ts_nsec);
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks);

#endif
