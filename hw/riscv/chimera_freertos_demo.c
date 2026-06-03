/*
 * Chimera RISC-V FreeRTOS demo machine
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
#include "hw/char/serial-mm.h"
#include "hw/core/qdev-properties.h"
#include "hw/core/sysbus.h"
#include "hw/intc/riscv_aclint.h"
#include "hw/intc/sifive_plic.h"
#include "hw/misc/ivshmem-flat.h"
#include "hw/riscv/boot.h"
#include "hw/riscv/chimera_freertos_demo.h"
#include "hw/riscv/machines-qom.h"
#include "system/address-spaces.h"
#include "system/system.h"

static const MemMapEntry chimera_freertos_memmap[] = {
    [CHIMERA_FREERTOS_MROM] =          { 0x00001000, 0x00010000 },
    [CHIMERA_FREERTOS_RAM] =           { 0x80000000, 0x08000000 },
    [CHIMERA_FREERTOS_UART] =          { 0x10000000, 0x00000100 },
    [CHIMERA_FREERTOS_CLINT] =         { 0x02000000, 0x00010000 },
    [CHIMERA_FREERTOS_PLIC] =          { 0x0c000000, 0x00400000 },
    [CHIMERA_FREERTOS_IVSHMEM0_MMIO] = { 0x30000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM0_SHMEM] = { 0x31000000,
                                          CHIMERA_FREERTOS_IVSHMEM_SIZE },
    [CHIMERA_FREERTOS_IVSHMEM1_MMIO] = { 0x35000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM1_SHMEM] = { 0x36000000,
                                          CHIMERA_FREERTOS_IVSHMEM_SIZE },
};

#define CHIMERA_FREERTOS_PLIC_HART_CONFIG "M"
#define CHIMERA_FREERTOS_PLIC_NUM_SOURCES 18
#define CHIMERA_FREERTOS_PLIC_NUM_PRIORITIES 7
#define CHIMERA_FREERTOS_PLIC_PRIORITY_BASE 0x0
#define CHIMERA_FREERTOS_PLIC_PENDING_BASE 0x1000
#define CHIMERA_FREERTOS_PLIC_ENABLE_BASE 0x2000
#define CHIMERA_FREERTOS_PLIC_ENABLE_STRIDE 0x80
#define CHIMERA_FREERTOS_PLIC_CONTEXT_BASE 0x200000
#define CHIMERA_FREERTOS_PLIC_CONTEXT_STRIDE 0x1000

static char *chimera_freertos_get_ivshmem_arm(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    return g_strdup(s->ivshmem_arm_freertos);
}

static void chimera_freertos_set_ivshmem_arm(Object *obj, const char *value,
                                             Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    g_free(s->ivshmem_arm_freertos);
    s->ivshmem_arm_freertos = g_strdup(value);
}

static char *chimera_freertos_get_ivshmem_riscv(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    return g_strdup(s->ivshmem_riscv_freertos);
}

static void chimera_freertos_set_ivshmem_riscv(Object *obj, const char *value,
                                               Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    g_free(s->ivshmem_riscv_freertos);
    s->ivshmem_riscv_freertos = g_strdup(value);
}

static bool chimera_freertos_require_chardev(const char *id,
                                             const char *prop_name,
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

static void chimera_freertos_connect_ivshmem(DeviceState *irqchip, Chardev *chr,
                                             hwaddr mmio_base,
                                             hwaddr shmem_base,
                                             int irq_num)
{
    DeviceState *dev = qdev_new(TYPE_IVSHMEM_FLAT);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    qdev_prop_set_chr(dev, "chardev", chr);
    qdev_prop_set_uint32(dev, "shmem-size", CHIMERA_FREERTOS_IVSHMEM_SIZE);
    sysbus_realize_and_unref(sbd, &error_fatal);
    sysbus_mmio_map(sbd, 0, mmio_base);
    sysbus_mmio_map(sbd, 1, shmem_base);
    sysbus_connect_irq(sbd, 0, qdev_get_gpio_in(irqchip, irq_num));
}

static void chimera_freertos_machine_init(MachineState *machine)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(machine);
    MemoryRegion *system_memory = get_system_memory();
    MemoryRegion *mask_rom = g_new(MemoryRegion, 1);
    DeviceState *plic;
    hwaddr firmware_load_addr = chimera_freertos_memmap[CHIMERA_FREERTOS_RAM].base;
    Chardev *arm_chr = NULL;
    Chardev *riscv_chr = NULL;
    bool have_links = true;

    have_links &= chimera_freertos_require_chardev(s->ivshmem_arm_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_ARM,
                                                   &arm_chr);
    have_links &= chimera_freertos_require_chardev(s->ivshmem_riscv_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_RISCV,
                                                   &riscv_chr);
    if (!have_links) {
        exit(EXIT_FAILURE);
    }

    object_initialize_child(OBJECT(machine), "cpus", &s->cpus,
                            TYPE_RISCV_HART_ARRAY);
    object_property_set_str(OBJECT(&s->cpus), "cpu-type", machine->cpu_type,
                            &error_fatal);
    object_property_set_int(OBJECT(&s->cpus), "num-harts", 1, &error_fatal);
    object_property_set_int(OBJECT(&s->cpus), "resetvec",
                            chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].base,
                            &error_fatal);
    sysbus_realize(SYS_BUS_DEVICE(&s->cpus), &error_fatal);

    memory_region_add_subregion(system_memory,
                                chimera_freertos_memmap[CHIMERA_FREERTOS_RAM].base,
                                machine->ram);

    memory_region_init_rom(mask_rom, NULL, "riscv.chimera.freertos.mrom",
                           chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].size,
                           &error_fatal);
    memory_region_add_subregion(system_memory,
                                chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].base,
                                mask_rom);

    riscv_aclint_swi_create(chimera_freertos_memmap[CHIMERA_FREERTOS_CLINT].base,
                            0, 1, false);
    riscv_aclint_mtimer_create(
        chimera_freertos_memmap[CHIMERA_FREERTOS_CLINT].base +
            RISCV_ACLINT_SWI_SIZE,
        RISCV_ACLINT_DEFAULT_MTIMER_SIZE, 0, 1,
        RISCV_ACLINT_DEFAULT_MTIMECMP, RISCV_ACLINT_DEFAULT_MTIME,
        RISCV_ACLINT_DEFAULT_TIMEBASE_FREQ, false);

    plic = sifive_plic_create(
        chimera_freertos_memmap[CHIMERA_FREERTOS_PLIC].base,
        (char *)CHIMERA_FREERTOS_PLIC_HART_CONFIG, 1, 0,
        CHIMERA_FREERTOS_PLIC_NUM_SOURCES,
        CHIMERA_FREERTOS_PLIC_NUM_PRIORITIES,
        CHIMERA_FREERTOS_PLIC_PRIORITY_BASE,
        CHIMERA_FREERTOS_PLIC_PENDING_BASE,
        CHIMERA_FREERTOS_PLIC_ENABLE_BASE,
        CHIMERA_FREERTOS_PLIC_ENABLE_STRIDE,
        CHIMERA_FREERTOS_PLIC_CONTEXT_BASE,
        CHIMERA_FREERTOS_PLIC_CONTEXT_STRIDE,
        chimera_freertos_memmap[CHIMERA_FREERTOS_PLIC].size);

    serial_mm_init(system_memory,
                   chimera_freertos_memmap[CHIMERA_FREERTOS_UART].base,
                   0,
                   qdev_get_gpio_in(plic, CHIMERA_FREERTOS_UART_IRQ),
                   399193, serial_hd(0), DEVICE_LITTLE_ENDIAN);

#ifndef CONFIG_IVSHMEM_FLAT_DEVICE
    error_report("ivshmem-flat support is unavailable in this QEMU build");
    exit(EXIT_FAILURE);
#else
    chimera_freertos_connect_ivshmem(
        plic, arm_chr,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM0_MMIO].base,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM0_SHMEM].base,
        CHIMERA_FREERTOS_IVSHMEM0_IRQ);
    chimera_freertos_connect_ivshmem(
        plic, riscv_chr,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM1_MMIO].base,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM1_SHMEM].base,
        CHIMERA_FREERTOS_IVSHMEM1_IRQ);
#endif

    if (machine->firmware) {
        riscv_load_firmware(machine->firmware, &firmware_load_addr, NULL);
    }

    riscv_setup_rom_reset_vec(machine, &s->cpus, firmware_load_addr,
                              chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].base,
                              chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].size,
                              0, 0);
}

static void chimera_freertos_machine_class_init(ObjectClass *oc,
                                                const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);

    mc->desc = "Chimera RISC-V FreeRTOS heterogeneous-soc demo board";
    mc->init = chimera_freertos_machine_init;
    mc->max_cpus = 1;
    mc->default_cpu_type = TYPE_RISCV_CPU_BASE;
    mc->default_ram_id = "riscv.chimera.freertos.ram";
    mc->default_ram_size = 128 * MiB;

    object_class_property_add_str(oc, CHIMERA_FREERTOS_PROP_IVSHMEM_ARM,
                                  chimera_freertos_get_ivshmem_arm,
                                  chimera_freertos_set_ivshmem_arm);
    object_class_property_set_description(
        oc, CHIMERA_FREERTOS_PROP_IVSHMEM_ARM,
        "Chardev id for the ARM/Linux <-> FreeRTOS ivshmem link");

    object_class_property_add_str(oc, CHIMERA_FREERTOS_PROP_IVSHMEM_RISCV,
                                  chimera_freertos_get_ivshmem_riscv,
                                  chimera_freertos_set_ivshmem_riscv);
    object_class_property_set_description(
        oc, CHIMERA_FREERTOS_PROP_IVSHMEM_RISCV,
        "Chardev id for the RISC-V/Linux <-> FreeRTOS ivshmem link");
}

static const TypeInfo chimera_freertos_machine_type_info = {
    .name = TYPE_CHIMERA_FREERTOS_MACHINE,
    .parent = TYPE_MACHINE,
    .instance_size = sizeof(ChimeraFreeRTOSMachineState),
    .class_init = chimera_freertos_machine_class_init,
    .interfaces = riscv64_machine_interfaces,
};

static void chimera_freertos_machine_register_types(void)
{
    type_register_static(&chimera_freertos_machine_type_info);
}

type_init(chimera_freertos_machine_register_types)
