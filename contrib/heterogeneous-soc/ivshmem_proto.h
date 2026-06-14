/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_IVSHMEM_PROTO_H
#define HETEROGENEOUS_SOC_IVSHMEM_PROTO_H

#include <stdint.h>

#define PING_MAGIC 0x50494E47U
#define PONG_MAGIC 0x504F4E47U

struct shm_msg {
    uint32_t magic;
    uint32_t seq;
    int64_t ts_sec;
    int64_t ts_nsec;
};

struct shm_channel {
    volatile uint32_t flag;
    uint32_t pad;
    struct shm_msg msg;
};

struct shm_layout {
    struct shm_channel arm_to_riscv;
    uint8_t pad0[0x1000 - sizeof(struct shm_channel)];
    struct shm_channel riscv_to_arm;
};

#endif /* HETEROGENEOUS_SOC_IVSHMEM_PROTO_H */
