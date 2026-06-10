#ifndef HETEROGENEOUS_SOC_FREERTOS_CAN_PROTO_H
#define HETEROGENEOUS_SOC_FREERTOS_CAN_PROTO_H

#include <stdint.h>

/* Channel-identity magic written once at init so the ARM-Linux daemon can
 * discover the correct ivshmem BAR2 (same role as HSOC_STATS_MAGIC). */
#define CAN_IVSHMEM_MAGIC 0xCAFECAFEU

/* One decoded CAN frame as published over IVSHMEM5. Fixed 16-byte wire size. */
struct can_ivshmem_frame {
    uint32_t id;        /* CAN ID (11-bit standard) */
    uint8_t  dlc;       /* 0-8 */
    uint8_t  pad[3];
    uint8_t  data[8];
};

/* IVSHMEM5 shared-memory layout: magic for discovery, generation bumped per
 * frame (single-slot, last-writer-wins), then the frame payload. Mirrors the
 * magic+generation pattern in stats_proto.h. */
struct can_ivshmem_layout {
    uint32_t magic;             /* CAN_IVSHMEM_MAGIC, written once at init */
    volatile uint32_t generation;  /* incremented after each frame is written */
    struct can_ivshmem_frame frame;
};

/* ---- Pure decode helpers (raw xlnx-zynqmp-can register value -> fields) ---- */

/* Standard 11-bit ID lives in RXFIFO_ID bits 21..31 (IDH field). */
static inline uint32_t can_decode_id(uint32_t rxfifo_id_reg)
{
    return (rxfifo_id_reg >> 21) & 0x7FFu;
}

/* DLC lives in RXFIFO_DLC bits 28..31; clamp to the 0-8 payload range. */
static inline uint32_t can_decode_dlc(uint32_t rxfifo_dlc_reg)
{
    uint32_t dlc = (rxfifo_dlc_reg >> 28) & 0xFu;
    return dlc > 8u ? 8u : dlc;
}

/* DATA1 holds DB0..DB3 (bits 24,16,8,0); DATA2 holds DB4..DB7 likewise. */
static inline void can_decode_data(uint32_t data1_reg, uint32_t data2_reg,
                                   uint8_t out[8])
{
    out[0] = (uint8_t)(data1_reg >> 24);
    out[1] = (uint8_t)(data1_reg >> 16);
    out[2] = (uint8_t)(data1_reg >> 8);
    out[3] = (uint8_t)(data1_reg);
    out[4] = (uint8_t)(data2_reg >> 24);
    out[5] = (uint8_t)(data2_reg >> 16);
    out[6] = (uint8_t)(data2_reg >> 8);
    out[7] = (uint8_t)(data2_reg);
}

#endif
