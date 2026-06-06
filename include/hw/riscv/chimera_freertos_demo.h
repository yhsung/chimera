/*
 * Chimera RISC-V FreeRTOS demo machine
 *
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_RISCV_CHIMERA_FREERTOS_DEMO_H
#define HW_RISCV_CHIMERA_FREERTOS_DEMO_H

#include "hw/core/boards.h"
#include "hw/riscv/riscv_hart.h"

#define TYPE_CHIMERA_FREERTOS_MACHINE \
    MACHINE_TYPE_NAME("chimera-riscv-freertos-demo")

#define CHIMERA_FREERTOS_PROP_IVSHMEM_ARM "ivshmem-arm-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_RISCV "ivshmem-riscv-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS "ivshmem-mips-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_STATS "ivshmem-stats-freertos"
#define CHIMERA_FREERTOS_PROP_IVSHMEM_BOOTLOG "ivshmem-bootlog-freertos"

#define CHIMERA_FREERTOS_IVSHMEM_SIZE (64U * 1024U * 1024U)

typedef struct ChimeraFreeRTOSMachineState ChimeraFreeRTOSMachineState;

DECLARE_INSTANCE_CHECKER(ChimeraFreeRTOSMachineState,
                         CHIMERA_FREERTOS_MACHINE,
                         TYPE_CHIMERA_FREERTOS_MACHINE)

struct ChimeraFreeRTOSMachineState {
    /*< private >*/
    MachineState parent_obj;

    /*< public >*/
    RISCVHartArrayState cpus;
    char *ivshmem_arm_freertos;
    char *ivshmem_riscv_freertos;
    char *ivshmem_mips_freertos;
    char *ivshmem_stats_freertos;
    char *ivshmem_bootlog_freertos;
};

enum {
    CHIMERA_FREERTOS_MROM,
    CHIMERA_FREERTOS_RAM,
    CHIMERA_FREERTOS_UART,
    CHIMERA_FREERTOS_CLINT,
    CHIMERA_FREERTOS_PLIC,
    CHIMERA_FREERTOS_IVSHMEM0_MMIO,
    CHIMERA_FREERTOS_IVSHMEM0_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM1_MMIO,
    CHIMERA_FREERTOS_IVSHMEM1_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM2_MMIO,
    CHIMERA_FREERTOS_IVSHMEM2_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM3_MMIO,
    CHIMERA_FREERTOS_IVSHMEM3_SHMEM,
    CHIMERA_FREERTOS_IVSHMEM4_MMIO,
    CHIMERA_FREERTOS_IVSHMEM4_SHMEM,
};

enum {
    CHIMERA_FREERTOS_UART_IRQ = 10,
    CHIMERA_FREERTOS_IVSHMEM0_IRQ = 16,
    CHIMERA_FREERTOS_IVSHMEM1_IRQ = 17,
    CHIMERA_FREERTOS_IVSHMEM2_IRQ = 18,
    CHIMERA_FREERTOS_IVSHMEM3_IRQ = 19,
    CHIMERA_FREERTOS_IVSHMEM4_IRQ = 20,
};

#endif
