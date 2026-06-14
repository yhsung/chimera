/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/* Host unit test for can_proto.h decode helpers. Build: cc -O2 -Wall -o test_can_decode test_can_decode.c */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "can_proto.h"

int main(void)
{
    /* Raw register values QEMU's xlnx-zynqmp-can latches for `cansend vcan0 123#DEADBEEF`:
     * update_rx_fifo() (hw/net/can/xlnx-zynqmp-can.c) pushes the raw
     * SocketCAN frame->can_id into RXFIFO_ID unshifted (not the TRM's
     * IDH bits 21-31), DLC 4 in bits 28-31, and packs payload byte i into
     * DATA1/DATA2 bits [8*i+7:8*i] (little-endian), so data[0]=DE ends up
     * in bits 0-7 and data[3]=EF in bits 24-31. */
    uint32_t id_reg  = 0x123u;            /* raw 11-bit standard ID */
    uint32_t dlc_reg = 4u << 28;          /* 0x40000000 */
    uint32_t d1      = 0xEFBEADDEu;       /* bytes 0..3 = DE AD BE EF (LE) */
    uint32_t d2      = 0x00000000u;

    assert(can_decode_id(id_reg) == 0x123u);
    assert(can_decode_dlc(dlc_reg) == 4u);

    uint8_t data[8];
    can_decode_data(d1, d2, data);
    assert(data[0] == 0xDE);
    assert(data[1] == 0xAD);
    assert(data[2] == 0xBE);
    assert(data[3] == 0xEF);

    /* DLC is clamped to 8. */
    assert(can_decode_dlc(0xFu << 28) == 8u);

    /* Frame/layout binary sizes are fixed by the wire contract. */
    assert(sizeof(struct can_ivshmem_frame) == 16);

    printf("test_can_decode: OK\n");
    return 0;
}
