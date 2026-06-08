# Cortex-R52 FreeRTOS Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bare-metal FreeRTOS guest's CPU from RV64 to Arm Cortex-R52 in place, keeping its role in the heterogeneous-SoC demo (receive HELLO over `ivshmem-flat`, send ACK, push a stats snapshot every 5 s) — only the CPU, QEMU machine, bare-metal toolchain, and firmware port change.

**Architecture:** A new minimal QEMU machine `chimera-r52-freertos-demo` (`hw/arm/`) models a single `cortex-r52` core + a GICv2 (`TYPE_ARM_GIC`) + a `pl011` UART + the 5 existing `ivshmem-flat` devices, deliberately reusing the **same guest-physical addresses** for UART and the ivshmem windows as the RISC-V machine so the firmware's memory map barely changes. The firmware switches to the FreeRTOS `ARM_CR5` GCC port (GICv2-style CPU interface, confirmed by the spike), driven by the Cortex-R52 architected generic timer for the tick. All build/launch scripts, the headless harness, the Python tests, and the docs follow the `r52` naming sweep.

**Tech Stack:** QEMU (C, Meson, Kconfig), FreeRTOS-Kernel `ARM_CR5` port, `gcc-arm-none-eabi` bare-metal toolchain, Armv8-R AArch32 assembly, Bash launch/harness scripts, Python `unittest`.

---

## Environment & workflow (read before starting)

- **Canonical source is the macOS host** at `/Volumes/Samsung970EVOPlus/dev-projects/chimera`. All edits happen here. Builds and QEMU runs happen **inside the Lima VM** (`qemu-dev`). See [[canonical-source-deploy]].
- **Deploy after every edit batch** before building/testing in Lima:
  ```bash
  bash scripts/heterogeneous-soc/host-install-lima-host.sh
  ```
  This rsyncs the host tree to `~/chimera-src` in the VM. (Faster inner loop during firmware work: `limactl shell qemu-dev -- rsync -a ~/chimera-src/` is handled by the install script; just re-run it.)
- **Run anything in the VM** with `limactl shell qemu-dev -- <cmd>`.
- The FreeRTOS-Kernel (incl. the `ARM_CR5` port) is **not on the host** — it is cloned only in the VM at `$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel`. Task 0 inspects it there.
- If a subagent is used, it must operate in the same git worktree as the master and commit to the worktree branch, not `master` — verify the commit landed on the right branch after each task. See [[feedback-subagent-worktree]].
- Commit after each task (frequent commits). Push only when the user asks.

## Design constants (used throughout — defined once here)

These are fixed decisions; later tasks reference them by name.

| Name | Value | Rationale |
|---|---|---|
| Machine type | `chimera-r52-freertos-demo` | spec §3 |
| QEMU binary | `qemu-system-arm` | Cortex-R52 is Armv8-R AArch32-only (spec §1) |
| Firmware ELF | `freertos-r52-demo.elf` | spec §3 |
| FreeRTOS port dir | `portable/GCC/ARM_CR5` | spike result (GICv2 + ARM_CR5) |
| RAM base / size | `0x80000000` / 128 MiB | **unchanged from RISC-V** → `linker.ld` ORIGIN unchanged, firmware ivshmem bases unchanged |
| GIC distributor (GICD) | `0x08000000`, size `0x1000` | free region below UART |
| GIC CPU interface (GICC) | `0x08010000`, size `0x2000` | → `configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET = 0x10000` |
| UART (pl011) | `0x10000000`, size `0x1000` | **same base as RISC-V** (only register layout differs) |
| IVSHMEM0..4 MMIO/SHMEM | identical to RISC-V `chimera_freertos_memmap` | minimizes firmware churn |
| GIC `num-irq` | `64` | 32 internal + SPIs 32..63 |
| GIC `num-cpu` | `1` | single-core port |
| GIC `num-priority-bits` | `5` | GICv2 default (matches a9mpcore) |
| SPI INTIDs | UART=32, IVSHMEM0..4 = 33..37 | gpio_in index = INTID − 32 (see `arm_gic_common.c:136`) |
| Tick timer | Cortex-R52 architected generic timer (CP15 `CNTP_*`), NS-EL1 phys, **PPI INTID 30** (`ARCH_TIMER_NS_EL1_IRQ`) | spec §1 "ARM generic timer"; no extra QEMU device needed |

**GICv2 gpio wiring facts** (from `hw/intc/arm_gic_common.c:136-146` and reference `hw/cpu/a9mpcore.c:155-162`):
- SPI input *n* (INTID 32+*n*) = `qdev_get_gpio_in(gicdev, n)`.
- PPI input for cpu *i*, PPI INTID *p* = `qdev_get_gpio_in(gicdev, (num_irq - 32) + i*32 + p)`.
- GIC sysbus IRQ output line 0 = cpu0 IRQ, line `num_cpu` = cpu0 FIQ.
- GIC sysbus mmio region 0 = distributor, region 1 = CPU interface.

---

## File structure

**New files:**
- `include/hw/arm/chimera_r52_freertos_demo.h` — machine state struct, memmap enum, IRQ enum, prop-name macros.
- `hw/arm/chimera_r52_freertos_demo.c` — the machine model.

**Modified (QEMU):**
- `hw/arm/Kconfig` — add `CONFIG_CHIMERA_R52_FREERTOS_DEMO`.
- `hw/arm/meson.build` — compile the new machine.
- `hw/riscv/Kconfig` — delete `CONFIG_CHIMERA_FREERTOS_DEMO`.
- `hw/riscv/meson.build` — drop `chimera_freertos_demo.c`.

**Deleted (QEMU):**
- `hw/riscv/chimera_freertos_demo.c`, `include/hw/riscv/chimera_freertos_demo.h`.

**Modified (firmware, `contrib/heterogeneous-soc/freertos-showcase/`):**
- `Makefile`, `startup.S`, `linker.ld`, `FreeRTOSConfig.h`, `freertos_main.c`, `freertos_ivshmem_flat.c`, `hello_proto.h` (comment only).

**Modified (scripts, `scripts/heterogeneous-soc/`):**
- `common.sh`, `guest-install-lima-guest.sh`, `guest-run-chimera-showcase.sh`, `guest-run-phase5-tmux.sh`, `guest-run-freertos-harness.sh`, `guest-run-debian-harness.sh`, and `guest-run-riscv-freertos-phase5.sh` → renamed `guest-run-r52-freertos-phase5.sh`.

**Modified (tests):**
- `tests/unit/test_heterogeneous_soc_freertos_machine.py`, `tests/unit/test_heterogeneous_soc_phase5_launch.py`.

**Modified (docs):**
- `README.md`, `contrib/heterogeneous-soc/freertos-showcase/README.md`, `CLAUDE.md`.

---

## Task 0: Reconnaissance — pin the ARM_CR5 port interface (no code change)

The `ARM_CR5` port's exact handler symbol names, the application-provided callback name, and its required `FreeRTOSConfig` macros must be confirmed against the cloned source before writing `startup.S`/`FreeRTOSConfig.h`. This task records those facts into this plan so later tasks use the real symbols.

**Files:** none (read-only).

- [ ] **Step 1: Ensure the kernel is cloned in the VM**

Run:
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-fetch-freertos-kernel.sh
```
Expected: `FreeRTOS-Kernel` present at `~/heterogeneous-soc-freertos/FreeRTOS-Kernel`.

- [ ] **Step 2: Confirm the ARM_CR5 port exists and capture its files**

Run:
```bash
limactl shell qemu-dev -- ls ~/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5
```
Expected: `port.c  portASM.S  portmacro.h`.

- [ ] **Step 3: Capture the IRQ/SWI handler entry symbols and the app callback**

Run:
```bash
limactl shell qemu-dev -- grep -nE '\.global|FreeRTOS_IRQ_Handler|FreeRTOS_SWI_Handler|vApplicationIRQHandler|vApplicationFPUSafeIRQHandler|FreeRTOS_Tick_Handler' \
  ~/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5/portASM.S \
  ~/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5/port.c
```
Record into a scratch note the exact answers to:
1. The IRQ vector entry symbol (expected `FreeRTOS_IRQ_Handler`).
2. The SVC/yield vector entry symbol (expected `FreeRTOS_SWI_Handler`).
3. Whether the application must provide `vApplicationIRQHandler(uint32_t ulICCIAR)` **or** `vApplicationFPUSafeIRQHandler(uint32_t ulICCIAR)` (the port supplies one and the app the other). The plan's Task 9 assumes `vApplicationIRQHandler`; if the port already defines it and instead calls `vApplicationFPUSafeIRQHandler`, use that name in Task 9 instead.
4. The tick handler symbol the app calls from the IRQ dispatch (expected `FreeRTOS_Tick_Handler`).

- [ ] **Step 4: Capture the required FreeRTOSConfig macros**

Run:
```bash
limactl shell qemu-dev -- grep -nE 'config[A-Z_]+' \
  ~/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5/portmacro.h \
  ~/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5/port.c | sort -u
```
Confirm these names exist (Task 8 defines all of them): `configINTERRUPT_CONTROLLER_BASE_ADDRESS`, `configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET`, `configUNIQUE_INTERRUPT_PRIORITIES`, `configMAX_API_CALL_INTERRUPT_PRIORITY`, `configSETUP_TICK_INTERRUPT`, `configCLEAR_TICK_INTERRUPT`. If the port spells any differently, note the difference and use the port's spelling in Task 8.

- [ ] **Step 5: Confirm `arm-none-eabi-gcc` accepts the target flags**

Run:
```bash
limactl shell qemu-dev -- bash -c 'echo "int main(void){return 0;}" | arm-none-eabi-gcc -mcpu=cortex-r52 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm -c -x c - -o /tmp/r52probe.o && echo OK'
```
Expected: `OK` (the spike already confirmed gcc 13.2.1; this re-verifies the toolchain is installed).

No commit (read-only task).

---

## Task 1: New machine header

**Files:**
- Create: `include/hw/arm/chimera_r52_freertos_demo.h`

- [ ] **Step 1: Write the header**

Model on `include/hw/riscv/chimera_freertos_demo.h`, but ARM state (an `ARMCPU *` + the GIC device) and ARM-appropriate memmap/IRQ enums. Note the prop-name macros keep the **same machine-option strings** (`ivshmem-arm-freertos`, `ivshmem-riscv-freertos`, …) — those name the Linux-guest channels and are untouched (spec §"Naming convention").

```c
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

#define CHIMERA_R52_FREERTOS_IVSHMEM_SIZE (64U * 1024U * 1024U)

/* GIC sizing */
#define CHIMERA_R52_FREERTOS_GIC_NUM_IRQ 64
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
};

/* GIC SPI gpio-input indices (INTID = index + 32) */
enum {
    CHIMERA_R52_FREERTOS_UART_SPI = 0,
    CHIMERA_R52_FREERTOS_IVSHMEM0_SPI = 1,
    CHIMERA_R52_FREERTOS_IVSHMEM1_SPI = 2,
    CHIMERA_R52_FREERTOS_IVSHMEM2_SPI = 3,
    CHIMERA_R52_FREERTOS_IVSHMEM3_SPI = 4,
    CHIMERA_R52_FREERTOS_IVSHMEM4_SPI = 5,
};

#endif
```

- [ ] **Step 2: Commit**

```bash
git add include/hw/arm/chimera_r52_freertos_demo.h
git commit -m "hw/arm: add Cortex-R52 FreeRTOS demo machine header"
```

---

## Task 2: New machine source

**Files:**
- Create: `hw/arm/chimera_r52_freertos_demo.c`

This is the central deliverable. It mirrors the structure of `hw/riscv/chimera_freertos_demo.c` (the 6 chardev getters/setters, `require_chardev`, `connect_ivshmem`, the class_init property registrations) but swaps RISC-V CPU/CLINT/PLIC/serial-mm for ARM CPU/GICv2/pl011, and loads the firmware via `arm_load_kernel`.

- [ ] **Step 1: Write the machine source**

```c
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

static const MemMapEntry chimera_r52_memmap[] = {
    [CHIMERA_R52_FREERTOS_RAM] =            { 0x80000000, 0x08000000 },
    [CHIMERA_R52_FREERTOS_GICD] =           { 0x08000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_GICC] =           { 0x08010000, 0x00002000 },
    [CHIMERA_R52_FREERTOS_UART] =           { 0x10000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM0_MMIO] =  { 0x30000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM0_SHMEM] = { 0x31000000,
                                              CHIMERA_R52_FREERTOS_IVSHMEM_SIZE },
    [CHIMERA_R52_FREERTOS_IVSHMEM1_MMIO] =  { 0x35000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM1_SHMEM] = { 0x36000000,
                                              CHIMERA_R52_FREERTOS_IVSHMEM_SIZE },
    [CHIMERA_R52_FREERTOS_IVSHMEM2_MMIO] =  { 0x3A000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM2_SHMEM] = { 0x3B000000,
                                              CHIMERA_R52_FREERTOS_IVSHMEM_SIZE },
    [CHIMERA_R52_FREERTOS_IVSHMEM3_MMIO] =  { 0x3F000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM3_SHMEM] = { 0x40000000,
                                              CHIMERA_R52_FREERTOS_IVSHMEM_SIZE },
    [CHIMERA_R52_FREERTOS_IVSHMEM4_MMIO] =  { 0x44000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM] = { 0x45000000, 0x00800000 }, /* 8 MiB */
};

/* ── chardev property getters/setters (one pair per channel) ──────────────── */

#define CHIMERA_R52_CHARDEV_PROP(field)                                       \
    static char *chimera_r52_get_##field(Object *obj, Error **errp)           \
    {                                                                         \
        ChimeraR52FreeRTOSMachineState *s =                                   \
            CHIMERA_R52_FREERTOS_MACHINE(obj);                               \
        return g_strdup(s->field);                                            \
    }                                                                         \
    static void chimera_r52_set_##field(Object *obj, const char *value,       \
                                        Error **errp)                         \
    {                                                                         \
        ChimeraR52FreeRTOSMachineState *s =                                   \
            CHIMERA_R52_FREERTOS_MACHINE(obj);                               \
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
        s->ivshmem_arm_freertos, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_ARM, &arm_chr);
    have_links &= chimera_r52_require_chardev(
        s->ivshmem_riscv_freertos, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_RISCV,
        &riscv_chr);
    have_links &= chimera_r52_require_chardev(
        s->ivshmem_mips_freertos, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_MIPS,
        &mips_chr);
    if (s->ivshmem_stats_freertos) {
        stats_chr = qemu_chr_find(s->ivshmem_stats_freertos);
    }
    if (s->ivshmem_bootlog_freertos) {
        bootlog_chr = qemu_chr_find(s->ivshmem_bootlog_freertos);
        if (!bootlog_chr) {
            error_report("warning: chardev '%s' not found, IVSHMEM4 boot-log "
                         "skipped", s->ivshmem_bootlog_freertos);
        }
    }
    if (!have_links) {
        exit(EXIT_FAILURE);
    }

    /* RAM */
    memory_region_add_subregion(system_memory,
                                chimera_r52_memmap[CHIMERA_R52_FREERTOS_RAM].base,
                                machine->ram);

    /* CPU */
    s->cpu = object_new(machine->cpu_type);
    object_property_set_int(s->cpu, "reset-cbar",
                            chimera_r52_memmap[CHIMERA_R52_FREERTOS_GICD].base,
                            &error_abort);
    qdev_realize(DEVICE(s->cpu), NULL, &error_fatal);
    cpudev = DEVICE(s->cpu);

    /* GICv2 */
    gicdev = qdev_new(TYPE_ARM_GIC);
    s->gic = gicdev;
    qdev_prop_set_uint32(gicdev, "num-cpu", CHIMERA_R52_FREERTOS_GIC_NUM_CPU);
    qdev_prop_set_uint32(gicdev, "num-irq", CHIMERA_R52_FREERTOS_GIC_NUM_IRQ);
    qdev_prop_set_uint32(gicdev, "num-priority-bits",
                         CHIMERA_R52_FREERTOS_GIC_NUM_PRIO_BITS);
    gicsbd = SYS_BUS_DEVICE(gicdev);
    sysbus_realize_and_unref(gicsbd, &error_fatal);
    sysbus_mmio_map(gicsbd, 0, chimera_r52_memmap[CHIMERA_R52_FREERTOS_GICD].base);
    sysbus_mmio_map(gicsbd, 1, chimera_r52_memmap[CHIMERA_R52_FREERTOS_GICC].base);

    /* GIC -> CPU IRQ/FIQ */
    sysbus_connect_irq(gicsbd, 0, qdev_get_gpio_in(cpudev, ARM_CPU_IRQ));
    sysbus_connect_irq(gicsbd, CHIMERA_R52_FREERTOS_GIC_NUM_CPU,
                       qdev_get_gpio_in(cpudev, ARM_CPU_FIQ));

    /* CPU architected (NS-EL1 physical) timer -> GIC PPI 30, the FreeRTOS tick */
    ppibase = CHIMERA_R52_FREERTOS_GIC_NUM_IRQ - 32; /* single cpu, i = 0 */
    qdev_connect_gpio_out(cpudev, GTIMER_PHYS,
                          qdev_get_gpio_in(gicdev,
                                           ppibase + ARCH_TIMER_NS_EL1_IRQ));

    /* UART (pl011) */
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
            (uint32_t)chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM].size,
            CHIMERA_R52_FREERTOS_IVSHMEM4_SPI);
    }

    /* Load the bare-metal firmware ELF (passed via -kernel). */
    bootinfo.ram_size = machine->ram_size;
    bootinfo.board_id = -1;
    bootinfo.loader_start =
        chimera_r52_memmap[CHIMERA_R52_FREERTOS_RAM].base;
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
```

> Verification notes for the executor (resolve at build time, Task 4): confirm the header name for `arm_machine_interfaces` (`hw/arm/machines-qom.h`), `pl011_create` (`hw/char/pl011.h`), `GTIMER_PHYS` (`target/arm/cpu.h`), `ARCH_TIMER_NS_EL1_IRQ` (`hw/arm/bsa.h`), and `ARM_CPU_IRQ`/`ARM_CPU_FIQ` (`target/arm/cpu.h`). If `reset-cbar` is rejected for `cortex-r52`, drop that `object_property_set_int` call — the FreeRTOS port uses absolute GIC addresses, not CBAR.

- [ ] **Step 2: Commit**

```bash
git add hw/arm/chimera_r52_freertos_demo.c
git commit -m "hw/arm: add Cortex-R52 FreeRTOS demo machine"
```

---

## Task 3: Kconfig + Meson wiring (add ARM, remove RISC-V)

**Files:**
- Modify: `hw/arm/Kconfig`
- Modify: `hw/arm/meson.build:8` (after the `mps3r.c` line)
- Modify: `hw/riscv/Kconfig` (delete the `CHIMERA_FREERTOS_DEMO` block, lines 12-20)
- Modify: `hw/riscv/meson.build:3-4` (delete the `chimera_freertos_demo.c` entry)

- [ ] **Step 1: Add the ARM Kconfig entry**

Append to `hw/arm/Kconfig`:
```kconfig
config CHIMERA_R52_FREERTOS_DEMO
    bool
    default y
    depends on TCG && ARM
    select ARM_GIC
    select PL011
    select IVSHMEM_FLAT_DEVICE
```

- [ ] **Step 2: Add the Meson source line**

In `hw/arm/meson.build`, immediately after the `CONFIG_MPS3R` line, add:
```meson
arm_common_ss.add(when: 'CONFIG_CHIMERA_R52_FREERTOS_DEMO', if_true: files('chimera_r52_freertos_demo.c'))
```

- [ ] **Step 3: Remove the RISC-V Kconfig block**

Delete lines 12-20 of `hw/riscv/Kconfig` (the entire `config CHIMERA_FREERTOS_DEMO` stanza including its `select`s).

- [ ] **Step 4: Remove the RISC-V Meson entry**

In `hw/riscv/meson.build`, delete the two lines:
```meson
riscv_ss.add(when: 'CONFIG_CHIMERA_FREERTOS_DEMO',
             if_true: files('chimera_freertos_demo.c'))
```

- [ ] **Step 5: Delete the old machine files**

```bash
git rm hw/riscv/chimera_freertos_demo.c include/hw/riscv/chimera_freertos_demo.h
```

- [ ] **Step 6: Commit**

```bash
git add hw/arm/Kconfig hw/arm/meson.build hw/riscv/Kconfig hw/riscv/meson.build
git commit -m "hw: wire R52 FreeRTOS machine into arm build, drop riscv machine"
```

---

## Task 4: Build QEMU and verify machine registration (TDD)

**Files:**
- Modify: `tests/unit/test_heterogeneous_soc_freertos_machine.py`

- [ ] **Step 1: Update the test to the new machine + ARM binary (write the failing test first)**

Rewrite `tests/unit/test_heterogeneous_soc_freertos_machine.py` to assert against the new machine and `qemu-system-arm`:
```python
#!/usr/bin/env python3
#
# SPDX-License-Identifier: GPL-2.0-or-later
#

import os
import subprocess
import unittest


class ChimeraR52FreeRTOSMachineTest(unittest.TestCase):
    def test_machine_is_registered(self):
        qemu = os.environ["QEMU_ARM_BIN"]
        result = subprocess.run(
            [qemu, "-machine", "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("chimera-r52-freertos-demo", result.stdout)

    def test_machine_requires_both_ivshmem_links(self):
        qemu = os.environ["QEMU_ARM_BIN"]
        result = subprocess.run(
            [qemu, "-M", "chimera-r52-freertos-demo", "-nographic",
             "-display", "none"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ivshmem-arm-freertos", result.stderr)
        self.assertIn("ivshmem-riscv-freertos", result.stderr)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Build QEMU in the Lima VM**

Deploy, then build:
```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src && ./configure --target-list=arm-softmmu,aarch64-softmmu,riscv64-softmmu,mipsel-softmmu --enable-debug 2>/dev/null || true; ninja -C "${BUILD_DIR:-$HOME/chimera-build-linux}" qemu-system-arm'
```
Expected: `qemu-system-arm` builds cleanly. Fix any compile errors against the verification notes in Task 2 Step 1 (header names, `reset-cbar`).

> If `configure` was already run for this build dir, the bare `ninja` line suffices. The R52 machine must be reachable from the `arm-softmmu` target's default config; `default y` on `depends on TCG && ARM` ensures it.

- [ ] **Step 3: Run the test to verify it passes**

```bash
limactl shell qemu-dev -- bash -c 'QEMU_ARM_BIN="${BUILD_DIR:-$HOME/chimera-build-linux}/qemu-system-arm" python3 ~/chimera-src/tests/unit/test_heterogeneous_soc_freertos_machine.py -v'
```
Expected: both tests PASS — the machine appears in `-machine help`, and launching it without ivshmem chardevs exits non-zero mentioning the missing options.

- [ ] **Step 4: Commit**

```bash
git add tests/unit/test_heterogeneous_soc_freertos_machine.py
git commit -m "test: assert chimera-r52-freertos-demo registers on qemu-system-arm"
```

---

## Task 5: Firmware Makefile — toolchain + port + ELF rename

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 1: Swap the bare-metal toolchain, port dir, flags, and target name**

Make these edits in `Makefile`:

1. Line 4 — cross-compiler prefix:
```make
CROSS_COMPILE ?= arm-none-eabi-
```
2. Lines 7-8 — port dir (drop the RISC-V chip-specific include dir):
```make
FREERTOS_PORT_DIR := $(FREERTOS_KERNEL_DIR)/portable/GCC/ARM_CR5
```
   Delete the `FREERTOS_PORT_CHIP_DIR := ...` line.
3. Lines 11-13 — bare-metal CFLAGS (spike-confirmed flags):
```make
CFLAGS_BARE ?= -O2 -Wall -Wextra -ffreestanding -fno-omit-frame-pointer \
	-mcpu=cortex-r52 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm \
	-ffunction-sections -fdata-sections
```
4. Line 58 — default target name:
```make
all: $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-r52-demo.elf
```
5. Lines 111-121 — the firmware rule. Rename target to `freertos-r52-demo.elf` and drop the `-I$(FREERTOS_PORT_CHIP_DIR)` include:
```make
freertos-r52-demo.elf: freertos_main.c freertos_ivshmem_flat.c boot_log.c \
		freertos_ivshmem_flat.h freertos_libc.c startup.S linker.ld FreeRTOSConfig.h \
		hello_proto.h stats_proto.h bootlog_proto.h boot_log.h $(FREERTOS_SRCS)
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_PORT_DIR) \
	  startup.S freertos_main.c freertos_ivshmem_flat.c boot_log.c freertos_libc.c \
	  $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@
```
6. Line 124 — clean target:
```make
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-r52-demo.elf
```

> `FREERTOS_SRCS` already references `$(FREERTOS_PORT_DIR)/port.c` and `$(FREERTOS_PORT_DIR)/portASM.S` (lines 53-54) — those paths now resolve to the ARM_CR5 port automatically; no change needed there.

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "freertos-showcase: retarget Makefile to arm-none-eabi/ARM_CR5/cortex-r52"
```

---

## Task 6: Firmware linker script (ARM)

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/linker.ld`

- [ ] **Step 1: Rewrite KEEP rules for the ARM_CR5 handler symbols; RAM origin unchanged**

RAM stays at `0x80000000` (matches the machine), so only the section/KEEP rules change — from RISC-V trap-handler section names to the ARM_CR5 vector/handler symbols, and add the exception vector table at the very start of `.text`.

```ld
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
}

SECTIONS
{
    .text : {
        KEEP(*(.vectors))
        *(.text.init)
        KEEP(*(.text.FreeRTOS_IRQ_Handler*))
        KEEP(*(.text.FreeRTOS_SWI_Handler*))
        *(.text*)
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    .bss : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
```

> If Task 0 Step 3 found different handler symbol names, update the two `KEEP(*(.text.<symbol>*))` lines. The `.vectors` section is defined by `startup.S` (Task 7).

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linker.ld
git commit -m "freertos-showcase: ARM linker script (vectors + ARM_CR5 handlers)"
```

---

## Task 7: Firmware startup (ARM exception vectors + per-mode stacks)

**Files:**
- Modify (full rewrite): `contrib/heterogeneous-soc/freertos-showcase/startup.S`

- [ ] **Step 1: Write the Armv8-R AArch32 startup**

Replaces the RISC-V `_start`. Sets VBAR to the vector table, sets up per-mode stacks (IRQ/SVC/System), enables the FPU (the `-mfloat-abi=hard` build needs CPACR/FPEXC set before any VFP use), clears BSS, and branches to `main`. The IRQ and SVC vectors branch to the ARM_CR5 port's handlers.

```asm
    .syntax unified
    .arm

    /* ── Exception vector table ──────────────────────────────────────────── */
    .section .vectors, "ax"
    .globl _start
_start:
    b    reset_handler            /* Reset */
    b    .                        /* Undefined */
    ldr  pc, =FreeRTOS_SWI_Handler/* Supervisor Call (FreeRTOS yield) */
    b    .                        /* Prefetch Abort */
    b    .                        /* Data Abort */
    nop                           /* Reserved (HYP trap entry on R-profile) */
    ldr  pc, =FreeRTOS_IRQ_Handler/* IRQ */
    b    .                        /* FIQ */

    /* ── Reset ───────────────────────────────────────────────────────────── */
    .section .text.init, "ax"
    .globl reset_handler
reset_handler:
    /* Point the vector base at our table. */
    ldr  r0, =_start
    mcr  p15, 0, r0, c12, c0, 0   /* VBAR */

    /* IRQ mode stack */
    cps  #0x12                    /* IRQ mode */
    ldr  sp, =_stack_irq_top

    /* Supervisor mode stack */
    cps  #0x13                    /* SVC mode */
    ldr  sp, =_stack_svc_top

    /* System mode (shares the System/User stack used by tasks before sched) */
    cps  #0x1F                    /* System mode */
    ldr  sp, =_stack_top

    /* Enable the FPU/NEON: CPACR cp10/cp11 full access, then FPEXC.EN. */
    mrc  p15, 0, r0, c1, c0, 2    /* CPACR */
    orr  r0, r0, #(0xF << 20)     /* cp10 + cp11 full access */
    mcr  p15, 0, r0, c1, c0, 2
    isb
    mov  r0, #0x40000000          /* FPEXC.EN */
    vmsr fpexc, r0

    /* Clear BSS */
    ldr  r0, =__bss_start
    ldr  r1, =__bss_end
    mov  r2, #0
1:
    cmp  r0, r1
    bge  2f
    str  r2, [r0], #4
    b    1b
2:
    bl   main
3:
    b    3b

    /* ── Mode stacks (reserve space inside .bss) ─────────────────────────── */
    .section .bss
    .align 3
    .space 1024
_stack_irq_top:
    .space 1024
_stack_svc_top:
```

> `_stack_top` (the System/User stack) is defined by the linker at the top of RAM. The IRQ and SVC stacks are small fixed reservations here. The `cps #imm` mode constants: IRQ=0x12, SVC=0x13, System=0x1F (Armv8-R AArch32). If Task 0 found the SWI/IRQ entry symbols differ, update the two `ldr pc, =...` lines.

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/startup.S
git commit -m "freertos-showcase: Armv8-R startup (vectors, mode stacks, FPU, BSS)"
```

---

## Task 8: FreeRTOSConfig.h — GICv2 + tick interrupt config

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/FreeRTOSConfig.h`

- [ ] **Step 1: Replace the RISC-V tick/CLINT config with ARM_CR5 GICv2 config**

Remove the two RISC-V lines:
```c
#define configMTIME_BASE_ADDRESS 0x0200bff8ULL
#define configMTIMECMP_BASE_ADDRESS 0x02004000ULL
```
and add the ARM_CR5 port's required macros. Insert (before the closing `#endif`):
```c
/* ── ARM_CR5 (GICv2) port configuration ─────────────────────────────────── */
/* GIC distributor base and the offset to its CPU interface, matching the
 * chimera-r52-freertos-demo machine's memory map (GICD 0x08000000,
 * GICC 0x08010000). */
#define configINTERRUPT_CONTROLLER_BASE_ADDRESS         0x08000000UL
#define configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET 0x00010000UL

/* QEMU's TYPE_ARM_GIC is built with num-priority-bits = 5 -> 32 levels. */
#define configUNIQUE_INTERRUPT_PRIORITIES               32
#define configMAX_API_CALL_INTERRUPT_PRIORITY           18

/* The tick is driven by the Cortex-R52 architected generic timer; these call
 * helpers defined in freertos_main.c. */
#ifndef __ASSEMBLER__
void vConfigureTickInterrupt(void);
void vClearTickInterrupt(void);
#endif
#define configSETUP_TICK_INTERRUPT()  vConfigureTickInterrupt()
#define configCLEAR_TICK_INTERRUPT()  vClearTickInterrupt()
```

> `configCPU_CLOCK_HZ` already exists (line 10). The `__ASSEMBLER__` guard is required because the ARM_CR5 `portASM.S` includes this header during assembly. If Task 0 Step 4 found a different macro spelling (e.g. `configEOI_BEFORE_SLEEP`), reconcile here. `configMAX_API_CALL_INTERRUPT_PRIORITY` = 18 keeps API-safe priority below the tick priority chosen in Task 9.

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/FreeRTOSConfig.h
git commit -m "freertos-showcase: FreeRTOSConfig for ARM_CR5 GICv2 + generic-timer tick"
```

---

## Task 9: freertos_main.c — pl011 UART, tick timer, IRQ dispatch

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`

The ivshmem comms stay flag-polled (no ivshmem IRQ handling needed), so the only new interrupt is the tick. Three additions: pl011 `uart_putc`, the generic-timer tick helpers, and `vApplicationIRQHandler`.

- [ ] **Step 1: Switch the UART register layout to pl011**

Replace the 16550 register defines (lines 17-20) with pl011 ones:
```c
#define UART0_BASE 0x10000000UL
#define PL011_DR   0x00    /* data register */
#define PL011_FR   0x18    /* flag register */
#define PL011_FR_TXFF 0x20 /* transmit FIFO full */
```
Rewrite `uart_putc` (lines 51-60):
```c
static void uart_putc(char ch)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);

    while ((*fr & PL011_FR_TXFF) != 0) {
    }

    *dr = (uint32_t)(uint8_t)ch;
}
```

- [ ] **Step 2: Add generic-timer tick helpers and the IRQ dispatcher**

Add near the top of the file (after the includes, before `showcase_task`). The tick PPI INTID is 30 (`ARCH_TIMER_NS_EL1_IRQ`, wired in the machine).

```c
/* ── Cortex-R52 generic-timer tick + GICv2 IRQ dispatch ──────────────────── */
#define R52_TICK_INTID            30U      /* NS-EL1 physical timer PPI */
#define GICD_BASE                 0x08000000UL
#define GICD_CTLR                 0x000U
#define GICD_ISENABLER            0x100U    /* +(intid/32)*4 */
#define GICD_IPRIORITYR           0x400U    /* +intid */

/* port.c calls FreeRTOS_Tick_Handler() on each tick. */
extern void FreeRTOS_Tick_Handler(void);

static uint32_t r52_tick_reload;

static inline uint32_t r52_read_cntfrq(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15, 0, %0, c14, c0, 0" : "=r"(v));
    return v;
}

static inline void r52_write_cntp_tval(uint32_t v)
{
    __asm__ volatile("mcr p15, 0, %0, c14, c2, 0" :: "r"(v));
}

static inline void r52_write_cntp_ctl(uint32_t v)
{
    __asm__ volatile("mcr p15, 0, %0, c14, c2, 1" :: "r"(v));
}

void vConfigureTickInterrupt(void)
{
    volatile uint8_t  *iprio = (volatile uint8_t  *)(GICD_BASE + GICD_IPRIORITYR);
    volatile uint32_t *isen  = (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);
    volatile uint32_t *ctlr  = (volatile uint32_t *)(GICD_BASE + GICD_CTLR);
    uint32_t freq = r52_read_cntfrq();

    r52_tick_reload = freq / configTICK_RATE_HZ;

    /* Give the tick a mid priority and enable it in the distributor. */
    iprio[R52_TICK_INTID] = 0xA0;
    isen[R52_TICK_INTID / 32] = (1U << (R52_TICK_INTID % 32));
    *ctlr |= 1U;  /* enable group 0 forwarding */

    /* Arm the down-counting physical timer and enable it. */
    r52_write_cntp_tval(r52_tick_reload);
    r52_write_cntp_ctl(1U); /* ENABLE, unmasked */
}

void vClearTickInterrupt(void)
{
    /* Re-arm the down-counter for the next tick. */
    r52_write_cntp_tval(r52_tick_reload);
}

/* Called by the ARM_CR5 port's FreeRTOS_IRQ_Handler with the ICCIAR value. */
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t intid = ulICCIAR & 0x3FFU;

    if (intid == R52_TICK_INTID) {
        FreeRTOS_Tick_Handler();
    }
    /* ivshmem channels are flag-polled; their IRQs (if any fire) are ignored. */
}
```

> If Task 0 Step 3 found the port calls `vApplicationFPUSafeIRQHandler` instead (i.e. the port already defines `vApplicationIRQHandler`), rename this function to `vApplicationFPUSafeIRQHandler` — the signature and body are identical.

- [ ] **Step 3: Update the stale RISC-V diagnostic string**

The startup diagnostics print `plic_sources` (lines 252-253). Change that label to reflect the GIC, e.g.:
```c
        log_uart(HSOC_LOG_VERBOSE, " gic_spis=");
        log_hex32_uart(HSOC_LOG_VERBOSE, 6);
```
(cosmetic; keeps the diag honest about the new interrupt controller.)

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "freertos-showcase: pl011 UART + generic-timer tick + GICv2 IRQ dispatch"
```

---

## Task 10: Identity strings (sender label only)

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h:18`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c:128,131`

The numeric wire value stays `3`; only the C identifier and the ACK text change (spec §2 "Identity strings only").

- [ ] **Step 1: Rename the enum constant (value unchanged)**

In `hello_proto.h`, line 18:
```c
    HSOC_SENDER_R52_FREERTOS = 3,
```

- [ ] **Step 2: Update the two references in the ACK builder**

In `freertos_ivshmem_flat.c`:
- Line 128:
```c
    ack.sender_id = HSOC_SENDER_R52_FREERTOS;
```
- Line 131:
```c
    copy_text(ack.text, "ack from r52-freertos");
```

- [ ] **Step 3: Verify no other references to the old identifier remain in firmware**

Run:
```bash
grep -rn "HSOC_SENDER_RISCV_FREERTOS\|ack from riscv-freertos" contrib/heterogeneous-soc/freertos-showcase/
```
Expected: no matches (the only live-code references were the two just edited; remaining hits are in `docs/superpowers/plans|specs`, which are historical and left as-is).

> Do **not** touch `riscv_link`/`riscv_count`/`IVSHMEM_RISCV_FREERTOS_*` — those are the RISCV-**Linux** channel (spec §"Naming convention").

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/hello_proto.h \
        contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c
git commit -m "freertos-showcase: rename sender id/ACK text to r52 (wire value still 3)"
```

---

## Task 11: Build the firmware in the VM (green)

**Files:** none (build verification).

- [ ] **Step 1: Deploy and build the firmware**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
```
Expected: `freertos-r52-demo.elf` is produced under the showcase dir with no errors. The Linux syslog/bootlog binaries still build as before.

- [ ] **Step 2: Confirm the ELF is an ARM (not RISC-V) binary**

```bash
limactl shell qemu-dev -- bash -c 'readelf -h $(find ~ -name freertos-r52-demo.elf 2>/dev/null | head -1) | grep -E "Machine|Entry"'
```
Expected: `Machine:  ARM` and `Entry point address: 0x80000000`.

> No commit (build artifacts are git-ignored — verify `freertos-r52-demo.elf` is covered by `contrib/heterogeneous-soc/freertos-showcase/.gitignore`; update the ignore entry from `freertos-riscv-demo.elf` to `freertos-r52-demo.elf` if it lists the old name, and commit that one-line change with message `freertos-showcase: gitignore the r52 demo elf`).

---

## Task 12: Rename + retarget the FreeRTOS launch script

**Files:**
- Rename: `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh` → `guest-run-r52-freertos-phase5.sh`

- [ ] **Step 1: git-rename the script**

```bash
git mv scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh \
       scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh
```

- [ ] **Step 2: Retarget the binary and machine inside it**

Edit `guest-run-r52-freertos-phase5.sh`:
- Line 6:
```bash
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"
```
- Line 11 — change only the machine type token (the `ivshmem-*-freertos=` option names are unchanged), and add `-kernel` instead of `-bios`:
```bash
    -machine chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft \
```
- Line 17:
```bash
    -kernel "${FREERTOS_DEMO_ELF}" \
```

> The R52 machine loads the ELF via `arm_load_kernel` (Task 2), which expects `-kernel`, not `-bios`.

- [ ] **Step 3: Commit**

```bash
git add -A scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh
git commit -m "scripts: rename freertos phase5 runner to r52, launch qemu-system-arm -kernel"
```

---

## Task 13: common.sh — ELF path

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh:94`

- [ ] **Step 1: Point FREERTOS_DEMO_ELF at the new ELF name**

```bash
FREERTOS_DEMO_ELF="${FREERTOS_DEMO_ELF:-${FREERTOS_SHOWCASE_DIR}/freertos-r52-demo.elf}"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/common.sh
git commit -m "scripts: default FREERTOS_DEMO_ELF to freertos-r52-demo.elf"
```

---

## Task 14: Toolchain packages (install + showcase pkg-checks)

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-install-lima-guest.sh:36-37`
- Modify: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh:117-118`

- [ ] **Step 1: Swap the apt packages in the installer**

In `guest-install-lima-guest.sh`, replace the two bare-metal RISC-V package lines (36-37):
```bash
    gcc-arm-none-eabi \
    binutils-arm-none-eabi \
```
(`qemu-system-arm` is already in the list at line 29.)

- [ ] **Step 2: Swap the `_pkg_check` lines in the showcase preflight**

In `guest-run-chimera-showcase.sh`, replace lines 117-118:
```bash
    _pkg_check gcc-arm-none-eabi
    _pkg_check binutils-arm-none-eabi
```

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-install-lima-guest.sh \
        scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
git commit -m "scripts: install/check gcc-arm-none-eabi instead of riscv64-unknown-elf"
```

---

## Task 15: pkill patterns (qemu-system-riscv64 → qemu-system-arm for the FreeRTOS guest)

The FreeRTOS guest now runs under `qemu-system-arm` and the ELF is `freertos-r52-demo`. The RISCV-**Linux** guest still uses `qemu-system-riscv64` — only the FreeRTOS lines change.

**Files (FreeRTOS-guest pkill lines only):**
- `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh:88`
- `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh:69`
- `scripts/heterogeneous-soc/guest-run-freertos-harness.sh:33,44`
- `scripts/heterogeneous-soc/guest-run-debian-harness.sh:57,71`

- [ ] **Step 1: Replace each FreeRTOS pkill pattern**

In each location above, change:
```bash
pkill -f "qemu-system-riscv64.*freertos-riscv-demo"
```
to:
```bash
pkill -f "qemu-system-arm.*freertos-r52-demo"
```
Leave every `qemu-system-riscv64.*riscv-phase5` line untouched (that is the RISCV-Linux guest).

- [ ] **Step 2: Verify no FreeRTOS pkill pattern still says riscv**

```bash
grep -rn "freertos-riscv-demo" scripts/
```
Expected: no matches.

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-chimera-showcase.sh \
        scripts/heterogeneous-soc/guest-run-phase5-tmux.sh \
        scripts/heterogeneous-soc/guest-run-freertos-harness.sh \
        scripts/heterogeneous-soc/guest-run-debian-harness.sh
git commit -m "scripts: kill FreeRTOS guest as qemu-system-arm.*freertos-r52-demo"
```

---

## Task 16: phase5-tmux — ELF path, runner name, pane label

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh:7,101` (and the FreeRTOS pane label/comment if present)

- [ ] **Step 1: Update the ELF path**

Line 7:
```bash
ELF="$REPO/contrib/heterogeneous-soc/freertos-showcase/freertos-r52-demo.elf"
```

- [ ] **Step 2: Update the runner script name**

Line 101 — point at the renamed runner:
```bash
tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh" Enter
```

- [ ] **Step 3: Update the FreeRTOS pane banner text (cosmetic)**

If the layout comment/banner labels the FreeRTOS pane, leave the word "FreeRTOS" as-is (the guest is still FreeRTOS) — no functional change required. No edit needed unless a label literally says "RISCV FreeRTOS"; if so, change to "R52 FreeRTOS".

- [ ] **Step 4: Verify the runner reference resolves**

```bash
grep -rn "guest-run-riscv-freertos-phase5" scripts/
```
Expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
git commit -m "scripts: phase5-tmux points at r52 ELF and r52 freertos runner"
```

---

## Task 17: Update the phase5-launch Python test

**Files:**
- Modify: `tests/unit/test_heterogeneous_soc_phase5_launch.py`

The test references `run-riscv-freertos-phase5.sh` / `start-ivshmem-server-arm-freertos.sh` (missing `guest-` prefixes) and the RISC-V machine/binary. Update it to the renamed runner, the `guest-` prefix, the ARM binary stub, and the new ELF/machine names.

- [ ] **Step 1: Update script paths, stub binary, and assertions**

Edit the file:
- Lines 16-24 — point at the real, renamed scripts:
```python
RUN_SCRIPT = (
    REPO_ROOT / "scripts" / "heterogeneous-soc" / "guest-run-r52-freertos-phase5.sh"
)
SERVER_SCRIPT = (
    REPO_ROOT
    / "scripts"
    / "heterogeneous-soc"
    / "guest-start-ivshmem-server-arm-freertos.sh"
)
```
- Line 36 — stub ELF name:
```python
        self.freertos_elf = self.tmp / "freertos-r52-demo.elf"
```
- Lines 38-44 — stub the ARM binary the runner now invokes:
```python
        self._write_stub(
            self.build_dir / "qemu-system-arm",
            f"""#!/bin/sh
printf 'qemu|%s\\n' "$*" >> {self.log_file}
exit 0
""",
        )
```
- Line 84 — machine-name assertion:
```python
        self.assertIn("chimera-r52-freertos-demo", log)
```
(The `ivshmem-arm-freertos=armft` / `ivshmem-riscv-freertos=riscvft` / `path=...` assertions are unchanged — those option names are untouched.)

- [ ] **Step 2: Run the test in the VM**

```bash
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src && python3 tests/unit/test_heterogeneous_soc_phase5_launch.py -v'
```
Expected: both tests PASS (the runner emits `chimera-r52-freertos-demo` and the two chardev paths; the server script uses the dedicated socket).

> If `guest-start-ivshmem-server-arm-freertos.sh` writes to a different stub binary name than `qemu-system-arm`/`ivshmem-server`, confirm the `ivshmem-server` stub (already present) still satisfies `test_arm_freertos_server_uses_dedicated_socket`. No machine/binary change applies to that server script.

- [ ] **Step 3: Commit**

```bash
git add tests/unit/test_heterogeneous_soc_phase5_launch.py
git commit -m "test: phase5 launch test targets r52 runner/machine/elf"
```

---

## Task 18: Validation — standalone boot (spec §4.1)

**Files:** none (run-and-observe). Optionally tighten the harness pass string.

- [ ] **Step 1: Boot the R52 machine alone and confirm the FreeRTOS banner + tick-driven log timestamps**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -c '
  set -e
  cd ~/chimera-src
  for d in /tmp/ivshmem-arm-freertos /tmp/ivshmem-riscv-freertos /tmp/ivshmem-mips-freertos; do mkdir -p "$d"; done
  pkill -f "qemu-system-arm.*freertos-r52-demo" 2>/dev/null || true
  rm -f /tmp/ivshmem-*-freertos/sock
  # start the three required ivshmem servers in the background
  for ch in arm riscv mips; do
    bash scripts/heterogeneous-soc/guest-start-ivshmem-server-${ch}-freertos.sh & sleep 0.3
  done
  sleep 1
  timeout 15 scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh 2>&1 | tee /tmp/r52-standalone.log | head -40 || true
  grep -q "booting demo firmware" /tmp/r52-standalone.log && echo "BANNER-OK"
  grep -q "showcase task started" /tmp/r52-standalone.log && echo "SCHEDULER-OK"
'
```
Expected: both `BANNER-OK` and `SCHEDULER-OK`. The `[N.NNN]` timestamps in the log advancing across lines proves the generic-timer tick is firing (the scheduler is running). This validates CPU + GIC + pl011 + tick together.

> If the banner prints but no scheduler line / timestamps stay at `[0.000]`: the tick IRQ is not reaching the CPU. Debug per [[systematic-debugging]] — check (a) the GIC PPI wiring INTID (Task 2: `ppibase + ARCH_TIMER_NS_EL1_IRQ`), (b) `configINTERRUPT_CONTROLLER_*` offsets vs. the GICD/GICC map (Task 8), (c) that `vApplicationIRQHandler` matches the port's expected callback name (Task 0/9), (d) FPU enabled before scheduler start (Task 7).

- [ ] **Step 2 (optional): keep the harness pass string valid**

`guest-run-freertos-harness.sh` keys on `"received hello from arm-linux"` (an end-to-end string), which still holds. No change required unless you want a boot-only smoke check; if so add an early `grep` for `"showcase task started"`. Skip otherwise.

No commit unless Step 2 was taken.

---

## Task 19: Validation — single-channel ivshmem round-trip (spec §4.2)

**Files:** none (run-and-observe).

- [ ] **Step 1: Bring up ARM-Linux + R52 FreeRTOS and confirm one HELLO/ACK**

Use the existing headless harness but with a short timeout; it brings up the FreeRTOS guest + ARM-Linux guest (among others) and passes when FreeRTOS logs the ARM hello:
```bash
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src && HARNESS_TIMEOUT=240 scripts/heterogeneous-soc/guest-run-freertos-harness.sh'
```
Expected: `[harness] PASS` and a `received hello from arm-linux` line. This isolates `ivshmem-flat` + GIC SPI wiring + the firmware poll loop on the ARM channel.

> If FreeRTOS boots (Task 18 passed) but never logs the hello: the ivshmem flag poll or SHMEM base is wrong. Verify the IVSHMEM0 SHMEM base in the machine map (Task 2) equals `IVSHMEM0_SHMEM` in `freertos_main.c` (both `0x31000000`) and that the ARM ivshmem server/socket is up. ivshmem comms are flag-polled, so GIC SPI wiring is not on the critical path for the round-trip — only the tick is.

No commit (validation only).

---

## Task 20: Validation — full showcase end-to-end (spec §4.3)

**Files:** none (run-and-observe).

- [ ] **Step 1: Run the full showcase and confirm r52 entries in the cross-domain log**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```
Then, after ~60 s, check the FreeRTOS pane and the cross-domain log:
```bash
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -30
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost \
  'tail -20 /var/log/chimera-log/chimera-cross-domain.log'
```
Expected: FreeRTOS logs `received hello` from all three Linux guests; the cross-domain log shows stats snapshots. The ACK text guests receive now reads `ack from r52-freertos` and the sender id is `3` (unchanged on the wire).

- [ ] **Step 2: Run the unit tests + both harnesses for a clean sweep**

```bash
limactl shell qemu-dev -- bash -c '
  cd ~/chimera-src
  QEMU_ARM_BIN="${BUILD_DIR:-$HOME/chimera-build-linux}/qemu-system-arm" \
    python3 tests/unit/test_heterogeneous_soc_freertos_machine.py -v &&
  python3 tests/unit/test_heterogeneous_soc_phase5_launch.py -v &&
  scripts/heterogeneous-soc/guest-run-freertos-harness.sh
'
```
Expected: tests PASS and the harness reports `PASS`. Per [[verification-before-completion]], paste the actual PASS lines into the task notes — do not claim success without them.

No commit (validation only).

---

## Task 21: Docs — README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update architecture/CPU, machine name, code table, wire-protocol label, and build sections**

In `README.md`, update each FreeRTOS reference:
- Architecture/component table: FreeRTOS guest CPU `RV64` → `Cortex-R52`; machine `chimera-riscv-freertos-demo` → `chimera-r52-freertos-demo`; binary `qemu-system-riscv64` → `qemu-system-arm` for the FreeRTOS guest only.
- Chimera-Specific Code file table: `hw/riscv/chimera_freertos_demo.c` → `hw/arm/chimera_r52_freertos_demo.c` (+ header path); ELF `freertos-riscv-demo.elf` → `freertos-r52-demo.elf`.
- Wire Protocol: sender-ID label `riscv-freertos` → `r52-freertos` (note value stays `3`).
- Building QEMU / Building the FreeRTOS Showcase Binaries: bare-metal toolchain `gcc/binutils-riscv64-unknown-elf` → `gcc/binutils-arm-none-eabi`; port path `portable/GCC/RISC-V` → `portable/GCC/ARM_CR5`; launch binary `qemu-system-arm`.

Verify no stale strings remain:
```bash
grep -nE "chimera-riscv-freertos-demo|freertos-riscv-demo|riscv64-unknown-elf|run-riscv-freertos-phase5" README.md
```
Expected: no matches after the edits (RISCV-**Linux** mentions are fine and should remain).

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README reflects Cortex-R52 FreeRTOS machine/toolchain"
```

---

## Task 22: Docs — contrib showcase README

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/README.md`

- [ ] **Step 1: Update firmware target name, startup description, and the cross-compiler line**

- Line ~5 & ~17: "bare-metal RISC-V FreeRTOS firmware (`freertos-riscv-demo.elf`)" → "bare-metal Cortex-R52 FreeRTOS firmware (`freertos-r52-demo.elf`)".
- Line ~29 (`startup.S` row): replace the RISC-V `_start`/`mtvec` description with: "ARM `_start`: exception vector table, per-mode stacks, enable FPU, clear BSS, call `main`".
- Line ~57: bare-metal cross-compiler `riscv64-unknown-elf-gcc` → `arm-none-eabi-gcc`.
- Line ~228: the `__sync_synchronize` note "on RISC-V" / "`dmb ish` on AArch64" — the FreeRTOS firmware now emits `dmb ish` (AArch32). Adjust the wording so it states the bare-metal firmware fence is now `dmb ish` on the Cortex-R52.

Verify:
```bash
grep -nE "freertos-riscv-demo|riscv64-unknown-elf" contrib/heterogeneous-soc/freertos-showcase/README.md
```
Expected: no matches.

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/README.md
git commit -m "docs: showcase README reflects Cortex-R52 firmware + arm-none-eabi"
```

---

## Task 23: Docs — CLAUDE.md naming note

**Files:**
- Modify: `CLAUDE.md` (after the "Naming: mipsel, not mips" section, line ~46)

- [ ] **Step 1: Add the r52-vs-RISCV-channel naming note**

Insert a new subsection right after the mipsel section:
```markdown
## Naming: r52 (FreeRTOS's CPU) vs. the RISCV-Linux channel

The bare-metal FreeRTOS guest runs on a Cortex-R52 (`qemu-system-arm`,
machine `chimera-r52-freertos-demo`, binary `freertos-r52-demo.elf`). The
disambiguating prefix for FreeRTOS's *own* architecture is **`r52`** (not
`arm`, which is the Cortex-A53 ARM-Linux guest). This is independent of the
**RISCV-Linux ↔ FreeRTOS channel**, whose names describe that Linux guest's
link and are deliberately left untouched: `IVSHMEM_RISCV_FREERTOS_*`,
`riscv_link`/`riscv_count`, `guest-start-ivshmem-server-riscv-freertos.sh`,
`syslog-riscv-linux`, `bootlog-riscv-linux`. Do not conflate the two: `r52`
names the CPU FreeRTOS runs on; `riscv` (in channel names) names the Linux
guest on the other end of one ivshmem link. The wire-protocol sender id for
FreeRTOS stays numeric `3` (`HSOC_SENDER_R52_FREERTOS`).
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md naming note for r52 vs RISCV-Linux channel"
```

---

## Final self-review checklist (run before declaring done)

- [ ] Full showcase passes 3 consecutive times (CLAUDE.md autonomous-debug-loop convention) via `guest-run-freertos-harness.sh`.
- [ ] No live-code references to the old names:
  ```bash
  grep -rn "chimera-riscv-freertos-demo\|freertos-riscv-demo\|HSOC_SENDER_RISCV_FREERTOS\|guest-run-riscv-freertos-phase5\|riscv64-unknown-elf" \
    hw/ include/ contrib/ scripts/ tests/ README.md CLAUDE.md
  ```
  Expected: no matches (docs/superpowers/{plans,specs} historical files are out of scope and may keep old names).
- [ ] RISCV-**Linux** channel names are intact (spec §"Untouched"):
  ```bash
  grep -rn "IVSHMEM_RISCV_FREERTOS\|riscv_link\|riscv_count\|guest-start-ivshmem-server-riscv-freertos\|syslog-riscv-linux\|bootlog-riscv-linux" scripts/ contrib/
  ```
  Expected: still present, unchanged.
- [ ] `git log --oneline` shows the per-task commits on the working branch (not `master`).
```
