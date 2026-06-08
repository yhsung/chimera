/*
 * Chimera Cortex-R52 FreeRTOS demo machine
 *
 * Copyright (c) 2026
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "qemu/units.h"
#include "qapi/error.h"
#include "chardev/char.h"
#include "hw/arm/boot.h"
#include "hw/arm/bsa.h"
#include "hw/arm/chimera_r52_freertos_demo.h"
#include "hw/arm/machines-qom.h"
#include "hw/char/pl011.h"
#include "hw/core/qdev-properties.h"
#include "hw/core/sysbus.h"
#include "hw/intc/arm_gic.h"
#include "hw/misc/ivshmem-flat.h"
#include "system/address-spaces.h"
#include "system/system.h"
#include "target/arm/cpu.h"
#include "target/arm/cpu-qom.h"

#define CHIMERA_R52_CNTFRQ_HZ 1000000000ULL

static const MemMapEntry chimera_r52_memmap[] = {
    [CHIMERA_R52_FREERTOS_RAM] =            { 0x80000000, 0x08000000 },
    [CHIMERA_R52_FREERTOS_GICD] =           { 0x08000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_GICC] =           { 0x08010000, 0x00002000 },
    [CHIMERA_R52_FREERTOS_UART] =           { 0x10000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM0_MMIO] =  { 0x30000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM0_SHMEM] = {
        0x31000000, CHIMERA_R52_FREERTOS_IVSHMEM_SIZE
    },
    [CHIMERA_R52_FREERTOS_IVSHMEM1_MMIO] =  { 0x35000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM1_SHMEM] = {
        0x36000000, CHIMERA_R52_FREERTOS_IVSHMEM_SIZE
    },
    [CHIMERA_R52_FREERTOS_IVSHMEM2_MMIO] =  { 0x3A000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM2_SHMEM] = {
        0x3B000000, CHIMERA_R52_FREERTOS_IVSHMEM_SIZE
    },
    [CHIMERA_R52_FREERTOS_IVSHMEM3_MMIO] =  { 0x3F000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM3_SHMEM] = {
        0x40000000, CHIMERA_R52_FREERTOS_IVSHMEM_SIZE
    },
    [CHIMERA_R52_FREERTOS_IVSHMEM4_MMIO] =  { 0x44000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM] = {
        0x45000000, 0x00800000 /* 8 MiB */
    },
};

#define CHIMERA_R52_CHARDEV_PROP(field)                                       \
    static char *chimera_r52_get_##field(Object *obj, Error **errp)           \
    {                                                                         \
        ChimeraR52FreeRTOSMachineState *s =                                   \
            CHIMERA_R52_FREERTOS_MACHINE(obj);                                \
                                                                              \
        return g_strdup(s->field);                                            \
    }                                                                         \
    static void chimera_r52_set_##field(Object *obj, const char *value,       \
                                        Error **errp)                         \
    {                                                                         \
        ChimeraR52FreeRTOSMachineState *s =                                   \
            CHIMERA_R52_FREERTOS_MACHINE(obj);                                \
                                                                              \
        g_free(s->field);                                                     \
        s->field = g_strdup(value);                                           \
    }

CHIMERA_R52_CHARDEV_PROP(ivshmem_arm_freertos)
CHIMERA_R52_CHARDEV_PROP(ivshmem_riscv_freertos)
CHIMERA_R52_CHARDEV_PROP(ivshmem_mips_freertos)
CHIMERA_R52_CHARDEV_PROP(ivshmem_stats_freertos)
CHIMERA_R52_CHARDEV_PROP(ivshmem_bootlog_freertos)

static bool chimera_r52_require_chardev(const char *id, const char *prop_name,
                                        Chardev **chr)
{
    *chr = id ? qemu_chr_find(id) : NULL;
    if (*chr) {
        return true;
    }

    error_report("A valid chardev id must be provided using the '%s' "
                 "machine option", prop_name);
    return false;
}

static void chimera_r52_connect_ivshmem(DeviceState *gic, Chardev *chr,
                                        hwaddr mmio_base, hwaddr shmem_base,
                                        uint32_t shmem_size, int spi_index)
{
    DeviceState *dev = qdev_new(TYPE_IVSHMEM_FLAT);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    qdev_prop_set_chr(dev, "chardev", chr);
    qdev_prop_set_uint32(dev, "shmem-size", shmem_size);
    sysbus_realize_and_unref(sbd, &error_fatal);
    sysbus_mmio_map(sbd, 0, mmio_base);
    sysbus_mmio_map(sbd, 1, shmem_base);
    sysbus_connect_irq(sbd, 0, qdev_get_gpio_in(gic, spi_index));
}

static void chimera_r52_machine_init(MachineState *machine)
{
    ChimeraR52FreeRTOSMachineState *s = CHIMERA_R52_FREERTOS_MACHINE(machine);
    MemoryRegion *system_memory = get_system_memory();
    DeviceState *cpudev;
    DeviceState *gicdev;
    SysBusDevice *gicsbd;
    int ppibase;
    Chardev *arm_chr = NULL, *riscv_chr = NULL, *mips_chr = NULL;
    Chardev *stats_chr = NULL, *bootlog_chr = NULL;
    bool have_links = true;
    static struct arm_boot_info bootinfo;

    have_links &= chimera_r52_require_chardev(
        s->ivshmem_arm_freertos, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_ARM,
        &arm_chr);
    have_links &= chimera_r52_require_chardev(
        s->ivshmem_riscv_freertos, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_RISCV,
        &riscv_chr);
    have_links &= chimera_r52_require_chardev(
        s->ivshmem_mips_freertos, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_MIPS,
        &mips_chr);
    if (s->ivshmem_stats_freertos) {
        stats_chr = qemu_chr_find(s->ivshmem_stats_freertos);
        if (!stats_chr) {
            warn_report("chardev '%s' not found, IVSHMEM3 stats channel "
                        "skipped", s->ivshmem_stats_freertos);
        }
    }
    if (s->ivshmem_bootlog_freertos) {
        bootlog_chr = qemu_chr_find(s->ivshmem_bootlog_freertos);
        if (!bootlog_chr) {
            warn_report("chardev '%s' not found, IVSHMEM4 boot-log skipped",
                        s->ivshmem_bootlog_freertos);
        }
    }
    if (!have_links) {
        exit(EXIT_FAILURE);
    }

    memory_region_add_subregion(system_memory,
                                chimera_r52_memmap[
                                    CHIMERA_R52_FREERTOS_RAM].base,
                                machine->ram);

    s->cpu = object_new(machine->cpu_type);
    if (object_property_find(s->cpu, "has_el2")) {
        object_property_set_bool(s->cpu, "has_el2", false, &error_fatal);
    }
    object_property_set_int(s->cpu, "cntfrq", CHIMERA_R52_CNTFRQ_HZ,
                            &error_fatal);
    if (object_property_find(s->cpu, "reset-cbar")) {
        object_property_set_int(s->cpu, "reset-cbar",
                                chimera_r52_memmap[
                                    CHIMERA_R52_FREERTOS_GICD].base,
                                &error_abort);
    }
    /* Enable the PMSA MPU with background region so bare-metal code can
     * execute from RAM before the MPU is programmed.  The reset SCTLR
     * has M=0,BR=0 which leaves all address ranges without any access
     * permissions on Cortex-R52's PMSAv8.  Set M=1,BR=1 to enable the
     * MPU with the background region, which grants RWX to all addresses
     * until the firmware programs explicit regions. */
    ARM_CPU(s->cpu)->reset_sctlr |= SCTLR_M | SCTLR_BR;
    qdev_realize(DEVICE(s->cpu), NULL, &error_fatal);
    cpudev = DEVICE(s->cpu);

    gicdev = qdev_new(TYPE_ARM_GIC);
    s->gic = gicdev;
    qdev_prop_set_uint32(gicdev, "num-cpu", CHIMERA_R52_FREERTOS_GIC_NUM_CPU);
    qdev_prop_set_uint32(gicdev, "num-irq", CHIMERA_R52_FREERTOS_GIC_NUM_IRQ);
    qdev_prop_set_uint32(gicdev, "revision", 2);
    qdev_prop_set_uint32(gicdev, "num-priority-bits",
                         CHIMERA_R52_FREERTOS_GIC_NUM_PRIO_BITS);
    gicsbd = SYS_BUS_DEVICE(gicdev);
    sysbus_realize_and_unref(gicsbd, &error_fatal);
    sysbus_mmio_map(gicsbd, 0,
                    chimera_r52_memmap[CHIMERA_R52_FREERTOS_GICD].base);
    sysbus_mmio_map(gicsbd, 1,
                    chimera_r52_memmap[CHIMERA_R52_FREERTOS_GICC].base);

    sysbus_connect_irq(gicsbd, 0, qdev_get_gpio_in(cpudev, ARM_CPU_IRQ));
    sysbus_connect_irq(gicsbd, CHIMERA_R52_FREERTOS_GIC_NUM_CPU,
                       qdev_get_gpio_in(cpudev, ARM_CPU_FIQ));

    ppibase = CHIMERA_R52_FREERTOS_GIC_NUM_IRQ - 32;
    qdev_connect_gpio_out(cpudev, GTIMER_PHYS,
                          qdev_get_gpio_in(gicdev,
                                           ppibase + ARCH_TIMER_NS_EL1_IRQ));

    pl011_create(chimera_r52_memmap[CHIMERA_R52_FREERTOS_UART].base,
                 qdev_get_gpio_in(gicdev, CHIMERA_R52_FREERTOS_UART_SPI),
                 serial_hd(0));

    if (!module_object_class_by_name(TYPE_IVSHMEM_FLAT)) {
        error_report("ivshmem-flat support is unavailable in this QEMU build");
        exit(EXIT_FAILURE);
    }

    chimera_r52_connect_ivshmem(
        gicdev, arm_chr,
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM0_MMIO].base,
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM0_SHMEM].base,
        CHIMERA_R52_FREERTOS_IVSHMEM_SIZE, CHIMERA_R52_FREERTOS_IVSHMEM0_SPI);
    chimera_r52_connect_ivshmem(
        gicdev, riscv_chr,
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM1_MMIO].base,
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM1_SHMEM].base,
        CHIMERA_R52_FREERTOS_IVSHMEM_SIZE, CHIMERA_R52_FREERTOS_IVSHMEM1_SPI);
    chimera_r52_connect_ivshmem(
        gicdev, mips_chr,
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM2_MMIO].base,
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM2_SHMEM].base,
        CHIMERA_R52_FREERTOS_IVSHMEM_SIZE, CHIMERA_R52_FREERTOS_IVSHMEM2_SPI);

    if (stats_chr) {
        chimera_r52_connect_ivshmem(
            gicdev, stats_chr,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM3_MMIO].base,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM3_SHMEM].base,
            CHIMERA_R52_FREERTOS_IVSHMEM_SIZE,
            CHIMERA_R52_FREERTOS_IVSHMEM3_SPI);
    }
    if (bootlog_chr) {
        chimera_r52_connect_ivshmem(
            gicdev, bootlog_chr,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM4_MMIO].base,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM].base,
            (uint32_t)chimera_r52_memmap[
                CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM].size,
            CHIMERA_R52_FREERTOS_IVSHMEM4_SPI);
    }

    bootinfo.ram_size = machine->ram_size;
    bootinfo.board_id = -1;
    bootinfo.loader_start = chimera_r52_memmap[CHIMERA_R52_FREERTOS_RAM].base;
    arm_load_kernel(ARM_CPU(s->cpu), machine, &bootinfo);
}

static void chimera_r52_machine_class_init(ObjectClass *oc, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);
    static const char * const valid_cpu_types[] = {
        ARM_CPU_TYPE_NAME("cortex-r52"),
        NULL
    };

    mc->desc = "Chimera Cortex-R52 FreeRTOS heterogeneous-soc demo board";
    mc->init = chimera_r52_machine_init;
    mc->min_cpus = 1;
    mc->max_cpus = 1;
    mc->default_cpus = 1;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("cortex-r52");
    mc->valid_cpu_types = valid_cpu_types;
    mc->default_ram_id = "arm.chimera.r52.freertos.ram";
    mc->default_ram_size = 128 * MiB;

    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_ARM,
                                  chimera_r52_get_ivshmem_arm_freertos,
                                  chimera_r52_set_ivshmem_arm_freertos);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_ARM,
        "Chardev id for the ARM/Linux <-> FreeRTOS ivshmem link");

    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_RISCV,
                                  chimera_r52_get_ivshmem_riscv_freertos,
                                  chimera_r52_set_ivshmem_riscv_freertos);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_RISCV,
        "Chardev id for the RISC-V/Linux <-> FreeRTOS ivshmem link");

    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_MIPS,
                                  chimera_r52_get_ivshmem_mips_freertos,
                                  chimera_r52_set_ivshmem_mips_freertos);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_MIPS,
        "Chardev id for the MIPS/Linux <-> FreeRTOS ivshmem link");

    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_STATS,
                                  chimera_r52_get_ivshmem_stats_freertos,
                                  chimera_r52_set_ivshmem_stats_freertos);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_STATS,
        "Chardev id for the stats FreeRTOS -> ARM-Linux ivshmem link");

    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_BOOTLOG,
                                  chimera_r52_get_ivshmem_bootlog_freertos,
                                  chimera_r52_set_ivshmem_bootlog_freertos);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_BOOTLOG,
        "Chardev id for the boot-log ivshmem link");
}

static const TypeInfo chimera_r52_machine_type_info = {
    .name = TYPE_CHIMERA_R52_FREERTOS_MACHINE,
    .parent = TYPE_MACHINE,
    .instance_size = sizeof(ChimeraR52FreeRTOSMachineState),
    .class_init = chimera_r52_machine_class_init,
    .interfaces = arm_machine_interfaces,
};

static void chimera_r52_machine_register_types(void)
{
    type_register_static(&chimera_r52_machine_type_info);
}

type_init(chimera_r52_machine_register_types)
