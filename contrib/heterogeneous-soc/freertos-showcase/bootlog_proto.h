/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_BOOTLOG_PROTO_H
#define HETEROGENEOUS_SOC_BOOTLOG_PROTO_H

#include <stdint.h>

#define BOOTLOG_MAGIC       0x424C5447U  /* "BLTG" */
#define BOOTLOG_SLOT_SIZE   0x100000U    /* 1 MiB per guest */
#define BOOTLOG_NUM_GUESTS  4U

enum hsoc_boot_status {
    HSOC_BOOT_BOOTING       = 0,
    HSOC_BOOT_COMPLETE      = 1,
};

enum hsoc_bootlog_guest {
    HSOC_GUEST_ARM_LINUX    = 0,
    HSOC_GUEST_RISCV_LINUX  = 1,
    HSOC_GUEST_MIPS_LINUX   = 2,
    HSOC_GUEST_FREERTOS     = 3,
};

struct hsoc_bootlog_guest_state {
    volatile uint32_t status;    /* hsoc_boot_status */
    volatile uint32_t offset;    /* byte offset of next unwritten position */
    uint32_t          reserved[2];
};

struct hsoc_bootlog_header {
    uint32_t          magic;        /* BOOTLOG_MAGIC */
    volatile uint32_t generation;   /* incremented on each collection event */
    volatile uint32_t collector_peer_id;  /* set by ARM-Linux once at startup */
    uint32_t          reserved;
    struct hsoc_bootlog_guest_state guests[BOOTLOG_NUM_GUESTS];
};

_Static_assert(sizeof(struct hsoc_bootlog_header) == 80,
               "hsoc_bootlog_header size mismatch");

/*
 * Shared memory layout at BAR2:
 *   0x0000   struct hsoc_bootlog_header  (80 bytes, 4-byte aligned)
 *   0x0050   unused / reserved until 0x1000
 *   0x1000   1 MiB  ARM-Linux boot log slot
 *   0x101000 1 MiB  RISC-V-Linux boot log slot
 *   0x201000 1 MiB  MIPS-Linux boot log slot
 *   0x301000 1 MiB  FreeRTOS boot log slot
 */
#define BOOTLOG_HEADER_SIZE   0x1000U
#define BOOTLOG_SLOT_ARM      BOOTLOG_HEADER_SIZE
#define BOOTLOG_SLOT_RISCV    (BOOTLOG_HEADER_SIZE + BOOTLOG_SLOT_SIZE)
#define BOOTLOG_SLOT_MIPS     (BOOTLOG_HEADER_SIZE + 2U * BOOTLOG_SLOT_SIZE)
#define BOOTLOG_SLOT_FREERTOS (BOOTLOG_HEADER_SIZE + 3U * BOOTLOG_SLOT_SIZE)

/* Total used BAR2 footprint (4 KiB header + 4 × 1 MiB slots).
 * QEMU PCI will round up to 0x800000 (8 MiB) for BAR allocation. */
#define BOOTLOG_BAR2_SIZE  (BOOTLOG_HEADER_SIZE + BOOTLOG_NUM_GUESTS * BOOTLOG_SLOT_SIZE)

/* Truncation marker written before wrapping so the collector can detect it. */
#define BOOTLOG_TRUNC_MARKER      "--- truncated ---\n"
#define BOOTLOG_TRUNC_MARKER_SIZE 18U   /* strlen(BOOTLOG_TRUNC_MARKER) */

/* Sentinel written to collector_peer_id until ARM-Linux sets the real value.
 * Must be non-zero since shmem zero-initializes and peer ID 0 is valid. */
#define BOOTLOG_COLLECTOR_PEER_UNSET  0xFFFFFFFFU

#endif
