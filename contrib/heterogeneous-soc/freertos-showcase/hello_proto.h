#ifndef HETEROGENEOUS_SOC_FREERTOS_HELLO_PROTO_H
#define HETEROGENEOUS_SOC_FREERTOS_HELLO_PROTO_H

#include <stdint.h>

#define HSOC_HELLO_MAGIC 0x48454c4fU
#define HSOC_PROTO_VERSION 2U
#define HSOC_TEXT_LEN 64U

enum hsoc_msg_type {
    HSOC_MSG_HELLO = 1,
    HSOC_MSG_ACK = 2,
};

enum hsoc_sender_id {
    HSOC_SENDER_ARM_LINUX = 1,
    HSOC_SENDER_RISCV_LINUX = 2,
    HSOC_SENDER_RISCV_FREERTOS = 3,
    HSOC_SENDER_MIPS_LINUX = 4,
};

struct hsoc_hello_msg {
    uint32_t magic;
    uint16_t version;
    uint16_t msg_type;
    uint32_t seq;
    uint32_t sender_id;
    int64_t ts_sec;
    int64_t ts_nsec;
    uint32_t cpu_pct_x100;       /* aggregate CPU busy %, x100 fixed-point (1234 = 12.34%) */
    uint32_t mem_used_pct_x100;  /* used-memory %, x100 fixed-point */
    char text[HSOC_TEXT_LEN];
};

struct hsoc_channel {
    volatile uint32_t flag;
    uint32_t reserved;
    struct hsoc_hello_msg msg;
};

struct hsoc_layout {
    struct hsoc_channel linux_to_freertos;
    uint8_t pad0[0x1000 - sizeof(struct hsoc_channel)];
    struct hsoc_channel freertos_to_linux;
};

#endif
