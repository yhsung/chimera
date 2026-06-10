/*
 * Chimera Cortex-R52 FreeRTOS demo machine
 *
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_ARM_CHIMERA_R52_FREERTOS_DEMO_H
#define HW_ARM_CHIMERA_R52_FREERTOS_DEMO_H

#include "hw/core/boards.h"
#include "qom/object.h"

#define TYPE_CHIMERA_R52_FREERTOS_MACHINE \
    MACHINE_TYPE_NAME("chimera-r52-freertos-demo")

#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_ARM "ivshmem-arm-freertos"
#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_RISCV "ivshmem-riscv-freertos"
#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_MIPS "ivshmem-mips-freertos"
#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_STATS "ivshmem-stats-freertos"
#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_BOOTLOG "ivshmem-bootlog-freertos"
#define CHIMERA_R52_FREERTOS_PROP_CANBUS "canbus"
#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_CAN "ivshmem-can-freertos"

#define CHIMERA_R52_FREERTOS_IVSHMEM_SIZE (64U * 1024U * 1024U)

/* GIC sizing */
#define CHIMERA_R52_FREERTOS_GIC_NUM_IRQ 96
#define CHIMERA_R52_FREERTOS_GIC_NUM_CPU 1
#define CHIMERA_R52_FREERTOS_GIC_NUM_PRIO_BITS 5

typedef struct ChimeraR52FreeRTOSMachineState ChimeraR52FreeRTOSMachineState;

DECLARE_INSTANCE_CHECKER(ChimeraR52FreeRTOSMachineState,
                         CHIMERA_R52_FREERTOS_MACHINE,
                         TYPE_CHIMERA_R52_FREERTOS_MACHINE)

struct ChimeraR52FreeRTOSMachineState {
    /*< private >*/
    MachineState parent_obj;

    /*< public >*/
    Object *cpu;
    DeviceState *gic;
    char *ivshmem_arm_freertos;
    char *ivshmem_riscv_freertos;
    char *ivshmem_mips_freertos;
    char *ivshmem_stats_freertos;
    char *ivshmem_bootlog_freertos;
    char *canbus_id;
    char *ivshmem_can_freertos;
};

enum {
    CHIMERA_R52_FREERTOS_RAM,
    CHIMERA_R52_FREERTOS_GICD,
    CHIMERA_R52_FREERTOS_GICC,
    CHIMERA_R52_FREERTOS_UART,
    CHIMERA_R52_FREERTOS_IVSHMEM0_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM0_SHMEM,
    CHIMERA_R52_FREERTOS_IVSHMEM1_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM1_SHMEM,
    CHIMERA_R52_FREERTOS_IVSHMEM2_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM2_SHMEM,
    CHIMERA_R52_FREERTOS_IVSHMEM3_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM3_SHMEM,
    CHIMERA_R52_FREERTOS_IVSHMEM4_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM,
    CHIMERA_R52_FREERTOS_IVSHMEM5_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM5_SHMEM,
    CHIMERA_R52_FREERTOS_CAN_MMIO,
};

/* GIC SPI gpio-input indices (INTID = index + 32) */
enum {
    CHIMERA_R52_FREERTOS_UART_SPI = 0,
    CHIMERA_R52_FREERTOS_IVSHMEM0_SPI = 1,
    CHIMERA_R52_FREERTOS_IVSHMEM1_SPI = 2,
    CHIMERA_R52_FREERTOS_IVSHMEM2_SPI = 3,
    CHIMERA_R52_FREERTOS_IVSHMEM3_SPI = 4,
    CHIMERA_R52_FREERTOS_IVSHMEM4_SPI = 5,
    CHIMERA_R52_FREERTOS_CAN_SPI = 6,
    CHIMERA_R52_FREERTOS_IVSHMEM5_SPI = 7,
};

#endif
