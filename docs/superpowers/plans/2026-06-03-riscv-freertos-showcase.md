# RISC-V FreeRTOS Heterogeneous SoC Showcase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new three-guest showcase where ARM/Linux and RISC-V/Linux each send timestamped `hello from {os}` messages to a dedicated RISC-V FreeRTOS guest over two separate ivshmem links, while preserving the current two-guest ARM/Linux ↔ RISC-V/Linux demo.

**Architecture:** Keep the existing Linux-only demo untouched and add a new Phase 5 flow. Linux guests continue using PCI `ivshmem-doorbell`; the new FreeRTOS guest runs on a dedicated RISC-V board model that wires in two `ivshmem-flat` devices with fixed MMIO and IRQ assignments. Guest payloads live under a new `contrib/heterogeneous-soc/freertos-showcase/` subtree, and the host-side launch flow uses two separate ivshmem servers, one per Linux↔FreeRTOS link.

**Tech Stack:** QEMU system emulation in C, Meson/Kconfig build integration, RISC-V bare-metal FreeRTOS (external kernel checkout), cross-compiled Linux guest binaries in C, Bash launch scripts, GLib unit tests, Python `unittest` script tests.

---

## Preconditions

Run these commands inside the Linux/Lima environment before starting the tasks:

```bash
cd ~/dev-projects/chimera
scripts/heterogeneous-soc/install-lima-guest.sh
BUILD_DIR=$HOME/chimera-build-linux \
VM_SOURCE_DIR=$HOME/chimera-src \
scripts/heterogeneous-soc/build-ivshmem-tools.sh
scripts/heterogeneous-soc/fetch-images.sh
```

## File Structure

### QEMU board and build wiring

- Create: `include/hw/riscv/chimera_freertos_demo.h`
  Responsibility: machine state, MMIO map constants, IRQ numbers, and property names for the FreeRTOS showcase board.
- Create: `hw/riscv/chimera_freertos_demo.c`
  Responsibility: instantiate the one-hart RISC-V board, serial console, CLINT, PLIC, RAM, firmware loading, and two `ivshmem-flat` endpoints.
- Modify: `hw/riscv/Kconfig`
  Responsibility: add a new `CHIMERA_FREERTOS_DEMO` symbol and select the exact device dependencies.
- Modify: `hw/riscv/meson.build`
  Responsibility: compile the new board when `CONFIG_CHIMERA_FREERTOS_DEMO` is enabled.

### Guest payloads

- Create: `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h`
  Responsibility: protocol constants, message structs, channel structs, and shared-memory layout for the new Linux↔FreeRTOS hello/ack flow.
- Create: `contrib/heterogeneous-soc/freertos-showcase/linux_hello.c`
  Responsibility: shared Linux sender implementation used by both ARM/Linux and RISC-V/Linux.
- Create: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`
  Responsibility: FreeRTOS app entry point and two-link polling responder task.
- Create: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h`
  Responsibility: MMIO register offsets, shared-memory mapping helpers, and link descriptors for the FreeRTOS side.
- Create: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c`
  Responsibility: low-level MMIO and shared-memory helpers for `ivshmem-flat`.
- Create: `contrib/heterogeneous-soc/freertos-showcase/FreeRTOSConfig.h`
  Responsibility: FreeRTOS port configuration for the demo board.
- Create: `contrib/heterogeneous-soc/freertos-showcase/startup.S`
  Responsibility: bare-metal reset entry, stack setup, and `main()` handoff.
- Create: `contrib/heterogeneous-soc/freertos-showcase/linker.ld`
  Responsibility: ROM/RAM placement for the FreeRTOS demo ELF.
- Create: `contrib/heterogeneous-soc/freertos-showcase/Makefile`
  Responsibility: cross-build both Linux sender binaries and the FreeRTOS ELF.
- Create: `contrib/heterogeneous-soc/freertos-showcase/README.rst`
  Responsibility: local build and run instructions for the new subtree.

### Scripts and environment

- Modify: `scripts/heterogeneous-soc/common.sh`
  Responsibility: add dedicated Phase 5 sockets, directories, binary paths, and FreeRTOS dependency locations.
- Modify: `scripts/heterogeneous-soc/install-lima-guest.sh`
  Responsibility: install the RISC-V bare-metal toolchain used for the FreeRTOS ELF.
- Create: `scripts/heterogeneous-soc/fetch-freertos-kernel.sh`
  Responsibility: clone or update the external FreeRTOS kernel checkout.
- Create: `scripts/heterogeneous-soc/build-freertos-showcase.sh`
  Responsibility: fetch FreeRTOS if needed and build the new guest payloads.
- Create: `scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh`
  Responsibility: start the dedicated ARM/Linux ↔ FreeRTOS ivshmem server.
- Create: `scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh`
  Responsibility: start the dedicated RISC-V/Linux ↔ FreeRTOS ivshmem server.
- Create: `scripts/heterogeneous-soc/run-arm-phase5.sh`
  Responsibility: boot the ARM/Linux guest on the ARM↔FreeRTOS link.
- Create: `scripts/heterogeneous-soc/run-riscv-phase5.sh`
  Responsibility: boot the RISC-V/Linux guest on the RISC-V↔FreeRTOS link.
- Create: `scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh`
  Responsibility: boot the FreeRTOS guest with two ivshmem chardevs and the new board.
- Create: `scripts/heterogeneous-soc/run-hello-arm.sh`
  Responsibility: run the ARM/Linux sender from `/usr/local/bin`, `/mnt/pingpong`, or the source tree.
- Create: `scripts/heterogeneous-soc/run-hello-riscv.sh`
  Responsibility: run the RISC-V/Linux sender from `/usr/local/bin`, `/mnt/pingpong`, or the source tree.

### Tests

- Create: `tests/unit/test-heterogeneous-soc-freertos-protocol.c`
  Responsibility: assert the new protocol constants and struct layout.
- Create: `tests/unit/test_heterogeneous_soc_freertos_machine.py`
  Responsibility: smoke-test that the new QEMU machine is registered and reports missing link properties clearly.
- Create: `tests/unit/test_heterogeneous_soc_phase5_launch.py`
  Responsibility: verify the new server and launch scripts emit the expected command lines and socket paths.
- Modify: `tests/unit/meson.build`
  Responsibility: add the new GLib unit test target.

### Documentation

- Modify: `docs/system/devices/heterogeneous-soc.rst`
  Responsibility: document the new Phase 5 flow alongside the existing two-guest path.
- Modify: `contrib/heterogeneous-soc/README.rst`
  Responsibility: explain the split between the original payloads and the new FreeRTOS showcase subtree.
- Modify: `docs/heterogeneous-soc-plan.md`
  Responsibility: append the implemented three-guest showcase as the next phase after the Linux-only ping/pong demo.

## Task 1: Define the New Protocol Contract

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h`
- Create: `tests/unit/test-heterogeneous-soc-freertos-protocol.c`
- Modify: `tests/unit/meson.build`

- [ ] **Step 1: Write the failing protocol-layout unit test**

```c
/* tests/unit/test-heterogeneous-soc-freertos-protocol.c */
#include <stddef.h>
#include <stdint.h>

#include <glib.h>

#include "../../contrib/heterogeneous-soc/freertos-showcase/hello_proto.h"

static void test_magic_values(void)
{
    g_assert_cmphex(HSOC_HELLO_MAGIC, ==, 0x48454c4fU);
    g_assert_cmpuint(HSOC_PROTO_VERSION, ==, 1);
}

static void test_layout_offsets(void)
{
    g_assert_cmpuint(sizeof(struct hsoc_hello_msg), ==, 96);
    g_assert_cmpuint(sizeof(struct hsoc_channel), ==, 104);
    g_assert_cmpuint(offsetof(struct hsoc_channel, msg), ==, 8);
    g_assert_cmpuint(offsetof(struct hsoc_layout, linux_to_freertos), ==, 0);
    g_assert_cmpuint(offsetof(struct hsoc_layout, freertos_to_linux), ==, 0x1000);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/heterogeneous-soc-freertos/magic-values",
                    test_magic_values);
    g_test_add_func("/heterogeneous-soc-freertos/layout-offsets",
                    test_layout_offsets);
    return g_test_run();
}
```

```meson
# tests/unit/meson.build
tests += {
  'test-heterogeneous-soc-freertos-protocol': [],
}
```

- [ ] **Step 2: Run the new unit test to prove it fails**

Run:

```bash
meson setup build-linux --reconfigure
ninja -C build-linux test-heterogeneous-soc-freertos-protocol
```

Expected: FAIL with a missing-header error for `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h`.

- [ ] **Step 3: Write the protocol header and keep the layout stable**

```c
/* contrib/heterogeneous-soc/freertos-showcase/hello_proto.h */
#ifndef HETEROGENEOUS_SOC_FREERTOS_HELLO_PROTO_H
#define HETEROGENEOUS_SOC_FREERTOS_HELLO_PROTO_H

#include <stdint.h>

#define HSOC_HELLO_MAGIC 0x48454c4fU
#define HSOC_PROTO_VERSION 1U
#define HSOC_TEXT_LEN 64U

enum hsoc_msg_type {
    HSOC_MSG_HELLO = 1,
    HSOC_MSG_ACK = 2,
};

enum hsoc_sender_id {
    HSOC_SENDER_ARM_LINUX = 1,
    HSOC_SENDER_RISCV_LINUX = 2,
    HSOC_SENDER_RISCV_FREERTOS = 3,
};

struct hsoc_hello_msg {
    uint32_t magic;
    uint16_t version;
    uint16_t msg_type;
    uint32_t seq;
    uint32_t sender_id;
    int64_t ts_sec;
    int64_t ts_nsec;
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
```

- [ ] **Step 4: Run the protocol test and verify it passes**

Run:

```bash
ninja -C build-linux test-heterogeneous-soc-freertos-protocol
meson test -C build-linux test-heterogeneous-soc-freertos-protocol --print-errorlogs
```

Expected: PASS for both `/heterogeneous-soc-freertos/magic-values` and `/heterogeneous-soc-freertos/layout-offsets`.

- [ ] **Step 5: Commit**

```bash
git add \
  contrib/heterogeneous-soc/freertos-showcase/hello_proto.h \
  tests/unit/test-heterogeneous-soc-freertos-protocol.c \
  tests/unit/meson.build
git commit -m "test: add freertos showcase protocol contract"
```

## Task 2: Register the New FreeRTOS Demo Machine

**Files:**
- Create: `include/hw/riscv/chimera_freertos_demo.h`
- Create: `hw/riscv/chimera_freertos_demo.c`
- Create: `tests/unit/test_heterogeneous_soc_freertos_machine.py`
- Modify: `hw/riscv/Kconfig`
- Modify: `hw/riscv/meson.build`

- [ ] **Step 1: Write the failing machine smoke test**

```python
#!/usr/bin/env python3
import os
import subprocess
import unittest


class ChimeraFreeRTOSMachineTest(unittest.TestCase):
    def test_machine_is_registered(self):
        qemu = os.environ["QEMU_RISCV64_BIN"]
        result = subprocess.run(
            [qemu, "-machine", "help"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("chimera-riscv-freertos-demo", result.stdout)

    def test_machine_requires_both_ivshmem_links(self):
        qemu = os.environ["QEMU_RISCV64_BIN"]
        result = subprocess.run(
            [qemu, "-M", "chimera-riscv-freertos-demo", "-nographic", "-display", "none"],
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

- [ ] **Step 2: Run the machine test to verify it fails**

Run:

```bash
QEMU_RISCV64_BIN=build-linux/qemu-system-riscv64 \
python3 -m unittest tests/unit/test_heterogeneous_soc_freertos_machine.py -v
```

Expected: FAIL because `chimera-riscv-freertos-demo` is not listed yet.

- [ ] **Step 3: Add the board header, board implementation, and build wiring**

```c
/* include/hw/riscv/chimera_freertos_demo.h */
#ifndef HW_RISCV_CHIMERA_FREERTOS_DEMO_H
#define HW_RISCV_CHIMERA_FREERTOS_DEMO_H

#include "hw/core/boards.h"
#include "hw/riscv/riscv_hart.h"

#define TYPE_CHIMERA_FREERTOS_MACHINE MACHINE_TYPE_NAME("chimera-riscv-freertos-demo")

typedef struct ChimeraFreeRTOSMachineState {
    MachineState parent_obj;
    RISCVHartArrayState cpus;
    char *ivshmem_arm_freertos;
    char *ivshmem_riscv_freertos;
} ChimeraFreeRTOSMachineState;

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
};

enum {
    CHIMERA_FREERTOS_UART_IRQ = 10,
    CHIMERA_FREERTOS_IVSHMEM0_IRQ = 16,
    CHIMERA_FREERTOS_IVSHMEM1_IRQ = 17,
};

#endif
```

```kconfig
# hw/riscv/Kconfig
config CHIMERA_FREERTOS_DEMO
    bool
    default y
    depends on RISCV64
    select IVSHMEM_FLAT_DEVICE
    select RISCV_ACLINT
    select SERIAL_MM
    select SIFIVE_PLIC
```

```meson
# hw/riscv/meson.build
riscv_ss.add(when: 'CONFIG_CHIMERA_FREERTOS_DEMO',
             if_true: files('chimera_freertos_demo.c'))
```

```c
/* hw/riscv/chimera_freertos_demo.c */
#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/module.h"
#include "chardev/char.h"
#include "hw/char/serial-mm.h"
#include "hw/core/boards.h"
#include "hw/core/loader.h"
#include "hw/core/qdev-properties.h"
#include "hw/core/sysbus.h"
#include "hw/intc/riscv_aclint.h"
#include "hw/intc/sifive_plic.h"
#include "hw/misc/ivshmem-flat.h"
#include "hw/riscv/boot.h"
#include "hw/riscv/chimera_freertos_demo.h"
#include "hw/riscv/machines-qom.h"
#include "system/address-spaces.h"

static const MemMapEntry chimera_freertos_memmap[] = {
    [CHIMERA_FREERTOS_MROM]         = { 0x00001000, 0x00010000 },
    [CHIMERA_FREERTOS_RAM]          = { 0x80000000, 0x08000000 },
    [CHIMERA_FREERTOS_UART]         = { 0x10000000, 0x00000100 },
    [CHIMERA_FREERTOS_CLINT]        = { 0x02000000, 0x00010000 },
    [CHIMERA_FREERTOS_PLIC]         = { 0x0c000000, 0x00400000 },
    [CHIMERA_FREERTOS_IVSHMEM0_MMIO]= { 0x30000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM0_SHMEM]= { 0x31000000, 0x04000000 },
    [CHIMERA_FREERTOS_IVSHMEM1_MMIO]= { 0x35000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM1_SHMEM]= { 0x36000000, 0x04000000 },
};

static Chardev *find_required_chardev(const char *id, const char *prop_name)
{
    Chardev *chr = id ? qemu_chr_find(id) : NULL;
    if (!chr) {
        error_report("A valid chardev id must be provided using the '%s' machine option", prop_name);
        exit(EXIT_FAILURE);
    }
    return chr;
}

static void connect_ivshmem_flat(hwaddr mmio_base, hwaddr shmem_base,
                                 qemu_irq irq, const char *chr_id,
                                 const char *prop_name)
{
    DeviceState *dev = qdev_new(TYPE_IVSHMEM_FLAT);
    qdev_prop_set_chr(dev, "chardev", find_required_chardev(chr_id, prop_name));
    qdev_prop_set_uint32(dev, "shmem-size", 64U * 1024U * 1024U);
    sysbus_realize_and_unref(SYS_BUS_DEVICE(dev), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(dev), 0, mmio_base);
    sysbus_mmio_map(SYS_BUS_DEVICE(dev), 1, shmem_base);
    sysbus_connect_irq(SYS_BUS_DEVICE(dev), 0, irq);
}

static void chimera_freertos_machine_init(MachineState *machine)
{
    ChimeraFreeRTOSMachineState *s = (ChimeraFreeRTOSMachineState *)machine;
    MemoryRegion *sysmem = get_system_memory();
    hwaddr firmware_load_addr = chimera_freertos_memmap[CHIMERA_FREERTOS_RAM].base;
    DeviceState *cpu = DEVICE(&s->cpus);
    qemu_irq *plic_irqs;

    object_initialize_child(OBJECT(machine), "cpus", &s->cpus, TYPE_RISCV_HART_ARRAY);
    object_property_set_str(OBJECT(&s->cpus), "cpu-type", machine->cpu_type, &error_fatal);
    object_property_set_int(OBJECT(&s->cpus), "num-harts", 1, &error_fatal);
    object_property_set_int(OBJECT(&s->cpus), "resetvec",
                            chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].base,
                            &error_fatal);
    sysbus_realize(SYS_BUS_DEVICE(cpu), &error_fatal);

    memory_region_add_subregion(sysmem, chimera_freertos_memmap[CHIMERA_FREERTOS_RAM].base,
                                machine->ram);

    riscv_aclint_swi_create(chimera_freertos_memmap[CHIMERA_FREERTOS_CLINT].base, 0, 1, false);
    riscv_aclint_mtimer_create(chimera_freertos_memmap[CHIMERA_FREERTOS_CLINT].base + RISCV_ACLINT_SWI_SIZE,
                               RISCV_ACLINT_DEFAULT_MTIMER_SIZE, 0, 1,
                               RISCV_ACLINT_DEFAULT_MTIMECMP,
                               RISCV_ACLINT_DEFAULT_MTIME,
                               RISCV_ACLINT_DEFAULT_TIMEBASE_FREQ, false);

    plic_irqs = sifive_plic_create(chimera_freertos_memmap[CHIMERA_FREERTOS_PLIC].base,
                                   "M", 1, 0, 32, 7,
                                   0x0, 0x1000, 0x2000, 0x80,
                                   0x200000, 0x1000,
                                   chimera_freertos_memmap[CHIMERA_FREERTOS_PLIC].size);

    serial_mm_init(sysmem, chimera_freertos_memmap[CHIMERA_FREERTOS_UART].base, 2,
                   plic_irqs[CHIMERA_FREERTOS_UART_IRQ],
                   115200, serial_hd(0), DEVICE_LITTLE_ENDIAN);

    connect_ivshmem_flat(chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM0_MMIO].base,
                         chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM0_SHMEM].base,
                         plic_irqs[CHIMERA_FREERTOS_IVSHMEM0_IRQ],
                         s->ivshmem_arm_freertos, "ivshmem-arm-freertos");
    connect_ivshmem_flat(chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM1_MMIO].base,
                         chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM1_SHMEM].base,
                         plic_irqs[CHIMERA_FREERTOS_IVSHMEM1_IRQ],
                         s->ivshmem_riscv_freertos, "ivshmem-riscv-freertos");

    if (machine->firmware) {
        riscv_load_firmware(machine->firmware, &firmware_load_addr, NULL);
    }
    riscv_setup_rom_reset_vec(machine, &s->cpus, firmware_load_addr,
                              chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].base,
                              chimera_freertos_memmap[CHIMERA_FREERTOS_MROM].size,
                              0, 0);
}
```

```c
/* append to hw/riscv/chimera_freertos_demo.c */
static char *get_ivshmem_arm(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = (ChimeraFreeRTOSMachineState *)obj;
    return g_strdup(s->ivshmem_arm_freertos);
}

static void set_ivshmem_arm(Object *obj, const char *value, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = (ChimeraFreeRTOSMachineState *)obj;
    g_free(s->ivshmem_arm_freertos);
    s->ivshmem_arm_freertos = g_strdup(value);
}

static char *get_ivshmem_riscv(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = (ChimeraFreeRTOSMachineState *)obj;
    return g_strdup(s->ivshmem_riscv_freertos);
}

static void set_ivshmem_riscv(Object *obj, const char *value, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = (ChimeraFreeRTOSMachineState *)obj;
    g_free(s->ivshmem_riscv_freertos);
    s->ivshmem_riscv_freertos = g_strdup(value);
}

static void chimera_freertos_machine_class_init(ObjectClass *oc, const void *data)
{
    MachineClass *mc = MACHINE_CLASS(oc);
    mc->desc = "Chimera RISC-V FreeRTOS heterogeneous-soc demo board";
    mc->init = chimera_freertos_machine_init;
    mc->max_cpus = 1;
    mc->default_cpu_type = RISCV_CPU_TYPE_NAME("rv64");
    mc->default_ram_id = "riscv.chimera.freertos.ram";
    mc->default_ram_size = 128 * MiB;

    object_class_property_add_str(oc, "ivshmem-arm-freertos",
                                  get_ivshmem_arm, set_ivshmem_arm);
    object_class_property_add_str(oc, "ivshmem-riscv-freertos",
                                  get_ivshmem_riscv, set_ivshmem_riscv);
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
```

- [ ] **Step 4: Build `qemu-system-riscv64` and rerun the smoke test**

Run:

```bash
meson setup build-linux --reconfigure
ninja -C build-linux qemu-system-riscv64
QEMU_RISCV64_BIN=build-linux/qemu-system-riscv64 \
python3 -m unittest tests/unit/test_heterogeneous_soc_freertos_machine.py -v
```

Expected: PASS for the machine listing test and a clear non-zero error for the missing-link-properties test.

- [ ] **Step 5: Commit**

```bash
git add \
  include/hw/riscv/chimera_freertos_demo.h \
  hw/riscv/chimera_freertos_demo.c \
  hw/riscv/Kconfig \
  hw/riscv/meson.build \
  tests/unit/test_heterogeneous_soc_freertos_machine.py
git commit -m "feat: add riscv freertos demo machine"
```

## Task 3: Build the Linux Hello Senders

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/linux_hello.c`
- Create: `contrib/heterogeneous-soc/freertos-showcase/Makefile`
- Create: `contrib/heterogeneous-soc/freertos-showcase/README.rst`

- [ ] **Step 1: Run the Linux sender build to verify it fails before the sources exist**

Run:

```bash
make -C contrib/heterogeneous-soc/freertos-showcase hello-arm-linux hello-riscv-linux
```

Expected: FAIL with “No such file or directory” or “No rule to make target”.

- [ ] **Step 2: Add the shared Linux sender implementation**

```c
/* contrib/heterogeneous-soc/freertos-showcase/linux_hello.c */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "hello_proto.h"

#define HSOC_BAR2_SIZE (64U * 1024U * 1024U)
#define HSOC_VENDOR_ID "0x1af4"

#ifndef HSOC_SENDER_LABEL
#define HSOC_SENDER_LABEL "linux"
#endif

#ifndef HSOC_SENDER_ID
#define HSOC_SENDER_ID HSOC_SENDER_ARM_LINUX
#endif

static void wait_for_flag(volatile uint32_t *flag, uint32_t expected)
{
    while (*flag != expected) {
        __sync_synchronize();
    }
}

static int main_loop(struct hsoc_layout *shm)
{
    uint32_t seq = 0;
    while (true) {
        struct timespec ts_send;
        struct hsoc_hello_msg ack;

        clock_gettime(CLOCK_REALTIME, &ts_send);
        memset(&shm->linux_to_freertos.msg, 0, sizeof(shm->linux_to_freertos.msg));
        shm->linux_to_freertos.msg.magic = HSOC_HELLO_MAGIC;
        shm->linux_to_freertos.msg.version = HSOC_PROTO_VERSION;
        shm->linux_to_freertos.msg.msg_type = HSOC_MSG_HELLO;
        shm->linux_to_freertos.msg.seq = seq;
        shm->linux_to_freertos.msg.sender_id = HSOC_SENDER_ID;
        shm->linux_to_freertos.msg.ts_sec = ts_send.tv_sec;
        shm->linux_to_freertos.msg.ts_nsec = ts_send.tv_nsec;
        snprintf(shm->linux_to_freertos.msg.text,
                 sizeof(shm->linux_to_freertos.msg.text),
                 "hello from %s", HSOC_SENDER_LABEL);
        __sync_synchronize();
        shm->linux_to_freertos.flag = 1;

        printf("[%s] HELLO #%" PRIu32 " %s\n",
               HSOC_SENDER_LABEL, seq, shm->linux_to_freertos.msg.text);

        wait_for_flag(&shm->freertos_to_linux.flag, 1);
        ack = shm->freertos_to_linux.msg;
        __sync_synchronize();
        shm->freertos_to_linux.flag = 0;

        printf("[%s] ACK   #%" PRIu32 " freertos_time=%lld.%09lld\n",
               HSOC_SENDER_LABEL, ack.seq,
               (long long)ack.ts_sec, (long long)ack.ts_nsec);
        seq++;
        sleep(1);
    }
}
```

- [ ] **Step 3: Add the sender build rules and documentation**

```make
# contrib/heterogeneous-soc/freertos-showcase/Makefile
CC_ARM ?= aarch64-linux-gnu-gcc
CC_RISCV ?= riscv64-linux-gnu-gcc
CROSS_COMPILE ?= riscv64-unknown-elf-
CFLAGS_LINUX ?= -O2 -Wall -Wextra -static

.PHONY: all clean

all: hello-arm-linux hello-riscv-linux

hello-arm-linux: linux_hello.c hello_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"arm-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_ARM_LINUX \
	  -o $@ linux_hello.c

hello-riscv-linux: linux_hello.c hello_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"riscv-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_RISCV_LINUX \
	  -o $@ linux_hello.c

clean:
	rm -f hello-arm-linux hello-riscv-linux freertos-riscv-demo.elf
```

```rst
Heterogeneous SoC FreeRTOS Showcase
===================================

This subtree builds the guest-side payloads for the three-guest
ARM/Linux + RISC-V/Linux -> RISC-V/FreeRTOS showcase.

* ``hello_proto.h`` defines the shared-memory protocol.
* ``linux_hello.c`` is compiled twice to produce the ARM/Linux and
  RISC-V/Linux sender binaries.
* ``freertos-riscv-demo.elf`` is the bare-metal FreeRTOS responder.
```

- [ ] **Step 4: Build both Linux senders and verify the binaries are correct**

Run:

```bash
make -C contrib/heterogeneous-soc/freertos-showcase clean all
file contrib/heterogeneous-soc/freertos-showcase/hello-arm-linux
file contrib/heterogeneous-soc/freertos-showcase/hello-riscv-linux
```

Expected:

- `hello-arm-linux`: `ELF 64-bit LSB executable, ARM aarch64, statically linked`
- `hello-riscv-linux`: `ELF 64-bit LSB executable, UCB RISC-V, statically linked`

- [ ] **Step 5: Commit**

```bash
git add \
  contrib/heterogeneous-soc/freertos-showcase/linux_hello.c \
  contrib/heterogeneous-soc/freertos-showcase/Makefile \
  contrib/heterogeneous-soc/freertos-showcase/README.rst
git commit -m "feat: add linux hello senders for freertos showcase"
```

## Task 4: Add the FreeRTOS Firmware and Build Contract

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`
- Create: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h`
- Create: `contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c`
- Create: `contrib/heterogeneous-soc/freertos-showcase/FreeRTOSConfig.h`
- Create: `contrib/heterogeneous-soc/freertos-showcase/startup.S`
- Create: `contrib/heterogeneous-soc/freertos-showcase/linker.ld`
- Create: `scripts/heterogeneous-soc/fetch-freertos-kernel.sh`
- Create: `scripts/heterogeneous-soc/build-freertos-showcase.sh`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`
- Modify: `scripts/heterogeneous-soc/common.sh`
- Modify: `scripts/heterogeneous-soc/install-lima-guest.sh`

- [ ] **Step 1: Run the FreeRTOS ELF build to verify it fails before the firmware files exist**

Run:

```bash
make -C contrib/heterogeneous-soc/freertos-showcase freertos-riscv-demo.elf
```

Expected: FAIL because the FreeRTOS-specific sources, linker script, or toolchain inputs are missing.

- [ ] **Step 2: Add the FreeRTOS dependency fetch/build scripts and environment defaults**

```bash
# scripts/heterogeneous-soc/fetch-freertos-kernel.sh
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

FREERTOS_DEPS_ROOT="${FREERTOS_DEPS_ROOT:-${HOME}/heterogeneous-soc-freertos}"
FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR:-${FREERTOS_DEPS_ROOT}/FreeRTOS-Kernel}"
FREERTOS_KERNEL_REMOTE="${FREERTOS_KERNEL_REMOTE:-https://github.com/FreeRTOS/FreeRTOS-Kernel.git}"

mkdir -p "${FREERTOS_DEPS_ROOT}"

if [[ ! -d "${FREERTOS_KERNEL_DIR}/.git" ]]; then
    git clone --depth 1 "${FREERTOS_KERNEL_REMOTE}" "${FREERTOS_KERNEL_DIR}"
else
    git -C "${FREERTOS_KERNEL_DIR}" pull --ff-only
fi
```

```bash
# scripts/heterogeneous-soc/build-freertos-showcase.sh
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_vm_source_tree
bash "${SCRIPT_DIR}/fetch-freertos-kernel.sh"
make -C "${FREERTOS_SHOWCASE_DIR}" clean all
```

```bash
# scripts/heterogeneous-soc/common.sh
IVSHMEM_ARM_FREERTOS_DIR="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}"
IVSHMEM_ARM_FREERTOS_SOCKET="${IVSHMEM_ARM_FREERTOS_SOCKET:-${IVSHMEM_ARM_FREERTOS_DIR}/sock}"
IVSHMEM_RISCV_FREERTOS_DIR="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}"
IVSHMEM_RISCV_FREERTOS_SOCKET="${IVSHMEM_RISCV_FREERTOS_SOCKET:-${IVSHMEM_RISCV_FREERTOS_DIR}/sock}"
FREERTOS_DEPS_ROOT="${FREERTOS_DEPS_ROOT:-${HOME}/heterogeneous-soc-freertos}"
FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR:-${FREERTOS_DEPS_ROOT}/FreeRTOS-Kernel}"
FREERTOS_SHOWCASE_DIR="${FREERTOS_SHOWCASE_DIR:-${PINGPONG_DIR}/freertos-showcase}"
HELLO_ARM_BINARY="${HELLO_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-arm-linux}"
HELLO_RISCV_BINARY="${HELLO_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-riscv-linux}"
FREERTOS_DEMO_ELF="${FREERTOS_DEMO_ELF:-${FREERTOS_SHOWCASE_DIR}/freertos-riscv-demo.elf}"
```

```bash
# scripts/heterogeneous-soc/install-lima-guest.sh
sudo apt-get install -y \
    gcc-riscv64-unknown-elf \
    binutils-riscv64-unknown-elf
```

- [ ] **Step 3: Add the FreeRTOS app, driver layer, startup code, and ELF target**

```c
/* contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h */
#ifndef HETEROGENEOUS_SOC_FREERTOS_IVSHMEM_FLAT_H
#define HETEROGENEOUS_SOC_FREERTOS_IVSHMEM_FLAT_H

#include <stdint.h>
#include "hello_proto.h"

struct freertos_ivshmem_link {
    volatile uint32_t *mmio_base;
    struct hsoc_layout *layout;
    const char *name;
};

void freertos_ivshmem_init(struct freertos_ivshmem_link *link,
                           uintptr_t mmio_base,
                           uintptr_t shmem_base,
                           const char *name);
int freertos_ivshmem_poll_hello(struct freertos_ivshmem_link *link,
                                struct hsoc_hello_msg *msg);
void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
                               uint32_t seq,
                               int64_t ts_sec,
                               int64_t ts_nsec);

#endif
```

```c
/* contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c */
#include "freertos_ivshmem_flat.h"
#include <string.h>

void freertos_ivshmem_init(struct freertos_ivshmem_link *link,
                           uintptr_t mmio_base,
                           uintptr_t shmem_base,
                           const char *name)
{
    link->mmio_base = (volatile uint32_t *)mmio_base;
    link->layout = (struct hsoc_layout *)shmem_base;
    link->name = name;
}

int freertos_ivshmem_poll_hello(struct freertos_ivshmem_link *link,
                                struct hsoc_hello_msg *msg)
{
    if (link->layout->linux_to_freertos.flag != 1) {
        return 0;
    }

    *msg = link->layout->linux_to_freertos.msg;
    link->layout->linux_to_freertos.flag = 0;
    return msg->magic == HSOC_HELLO_MAGIC && msg->version == HSOC_PROTO_VERSION;
}

void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
                               uint32_t seq,
                               int64_t ts_sec,
                               int64_t ts_nsec)
{
    memset(&link->layout->freertos_to_linux.msg, 0,
           sizeof(link->layout->freertos_to_linux.msg));
    link->layout->freertos_to_linux.msg.magic = HSOC_HELLO_MAGIC;
    link->layout->freertos_to_linux.msg.version = HSOC_PROTO_VERSION;
    link->layout->freertos_to_linux.msg.msg_type = HSOC_MSG_ACK;
    link->layout->freertos_to_linux.msg.seq = seq;
    link->layout->freertos_to_linux.msg.sender_id = HSOC_SENDER_RISCV_FREERTOS;
    link->layout->freertos_to_linux.msg.ts_sec = ts_sec;
    link->layout->freertos_to_linux.msg.ts_nsec = ts_nsec;
    link->layout->freertos_to_linux.flag = 1;
}
```

```c
/* contrib/heterogeneous-soc/freertos-showcase/freertos_main.c */
#include "FreeRTOS.h"
#include "task.h"
#include "freertos_ivshmem_flat.h"

#define IVSHMEM0_MMIO  0x30000000UL
#define IVSHMEM0_SHMEM 0x31000000UL
#define IVSHMEM1_MMIO  0x35000000UL
#define IVSHMEM1_SHMEM 0x36000000UL

static struct freertos_ivshmem_link arm_link;
static struct freertos_ivshmem_link riscv_link;

static void log_uart(const char *msg);
static void showcase_task(void *opaque)
{
    struct hsoc_hello_msg hello;

    freertos_ivshmem_init(&arm_link, IVSHMEM0_MMIO, IVSHMEM0_SHMEM, "arm-linux");
    freertos_ivshmem_init(&riscv_link, IVSHMEM1_MMIO, IVSHMEM1_SHMEM, "riscv-linux");
    log_uart("[freertos] showcase task started\n");

    for (;;) {
        if (freertos_ivshmem_poll_hello(&arm_link, &hello)) {
            log_uart("[freertos] received hello from arm-linux\n");
            freertos_ivshmem_send_ack(&arm_link, hello.seq, hello.ts_sec, hello.ts_nsec);
        }
        if (freertos_ivshmem_poll_hello(&riscv_link, &hello)) {
            log_uart("[freertos] received hello from riscv-linux\n");
            freertos_ivshmem_send_ack(&riscv_link, hello.seq, hello.ts_sec, hello.ts_nsec);
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

int main(void)
{
    xTaskCreate(showcase_task, "showcase", 2048, NULL, tskIDLE_PRIORITY + 1, NULL);
    vTaskStartScheduler();
    for (;;) {
    }
}
```

```c
/* contrib/heterogeneous-soc/freertos-showcase/FreeRTOSConfig.h */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configCPU_CLOCK_HZ              (10000000UL)
#define configTICK_RATE_HZ              (1000)
#define configMAX_PRIORITIES            (5)
#define configMINIMAL_STACK_SIZE        (256)
#define configTOTAL_HEAP_SIZE           (64 * 1024)
#define configUSE_PREEMPTION            1
#define configUSE_16_BIT_TICKS          0
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configCHECK_FOR_STACK_OVERFLOW  2
#define configMTIME_BASE_ADDRESS        0x0200bff8ULL
#define configMTIMECMP_BASE_ADDRESS     0x02004000ULL
#define configCLINT_BASE_ADDRESS        0x02000000ULL

#endif
```

```asm
/* contrib/heterogeneous-soc/freertos-showcase/startup.S */
    .section .text.init
    .globl _start
_start:
    la sp, _stack_top
    call main
1:
    j 1b
```

```ld
/* contrib/heterogeneous-soc/freertos-showcase/linker.ld */
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x80000000, LENGTH = 512K
    RAM (rwx) : ORIGIN = 0x80080000, LENGTH = 8M
}

SECTIONS
{
    .text : { *(.text.init) *(.text*) *(.rodata*) } > ROM
    .data : { *(.data*) } > RAM AT > ROM
    .bss  : { *(.bss*) *(COMMON) } > RAM
    . = ALIGN(16);
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
```

```make
# append to contrib/heterogeneous-soc/freertos-showcase/Makefile
FREERTOS_KERNEL_DIR ?= $(HOME)/heterogeneous-soc-freertos/FreeRTOS-Kernel
CC_BARE ?= $(CROSS_COMPILE)gcc
OBJCOPY ?= $(CROSS_COMPILE)objcopy
CFLAGS_BARE ?= -O2 -ffreestanding -fno-omit-frame-pointer -Wall -Wextra
LDFLAGS_BARE ?= -nostdlib -T linker.ld

FREERTOS_SRCS = \
  $(FREERTOS_KERNEL_DIR)/tasks.c \
  $(FREERTOS_KERNEL_DIR)/list.c \
  $(FREERTOS_KERNEL_DIR)/queue.c \
  $(FREERTOS_KERNEL_DIR)/portable/MemMang/heap_4.c \
  $(FREERTOS_KERNEL_DIR)/portable/GCC/RISC-V/port.c \
  $(FREERTOS_KERNEL_DIR)/portable/GCC/RISC-V/portASM.S

freertos-riscv-demo.elf: freertos_main.c freertos_ivshmem_flat.c startup.S linker.ld FreeRTOSConfig.h hello_proto.h
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_KERNEL_DIR)/portable/GCC/RISC-V \
	  startup.S freertos_main.c freertos_ivshmem_flat.c $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@

all: hello-arm-linux hello-riscv-linux freertos-riscv-demo.elf
```

- [ ] **Step 4: Build the FreeRTOS ELF and verify the artifact exists**

Run:

```bash
scripts/heterogeneous-soc/build-freertos-showcase.sh
file contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf
```

Expected: `ELF 64-bit LSB executable, UCB RISC-V`.

- [ ] **Step 5: Commit**

```bash
git add \
  contrib/heterogeneous-soc/freertos-showcase/freertos_main.c \
  contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.h \
  contrib/heterogeneous-soc/freertos-showcase/freertos_ivshmem_flat.c \
  contrib/heterogeneous-soc/freertos-showcase/FreeRTOSConfig.h \
  contrib/heterogeneous-soc/freertos-showcase/startup.S \
  contrib/heterogeneous-soc/freertos-showcase/linker.ld \
  contrib/heterogeneous-soc/freertos-showcase/Makefile \
  scripts/heterogeneous-soc/fetch-freertos-kernel.sh \
  scripts/heterogeneous-soc/build-freertos-showcase.sh \
  scripts/heterogeneous-soc/common.sh \
  scripts/heterogeneous-soc/install-lima-guest.sh
git commit -m "feat: add freertos responder firmware"
```

## Task 5: Add the Dual-Link Phase 5 Launch Flow

**Files:**
- Create: `scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh`
- Create: `scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh`
- Create: `scripts/heterogeneous-soc/run-arm-phase5.sh`
- Create: `scripts/heterogeneous-soc/run-riscv-phase5.sh`
- Create: `scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh`
- Create: `scripts/heterogeneous-soc/run-hello-arm.sh`
- Create: `scripts/heterogeneous-soc/run-hello-riscv.sh`
- Create: `tests/unit/test_heterogeneous_soc_phase5_launch.py`

- [ ] **Step 1: Write the failing Phase 5 launch test**

```python
#!/usr/bin/env python3
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUN_SCRIPT = REPO_ROOT / "scripts" / "heterogeneous-soc" / "run-riscv-freertos-phase5.sh"
SERVER_SCRIPT = REPO_ROOT / "scripts" / "heterogeneous-soc" / "start-ivshmem-server-arm-freertos.sh"


class Phase5LaunchTest(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmpdir.name)
        self.bin_dir = self.tmp / "bin"
        self.bin_dir.mkdir()
        self.log_file = self.tmp / "commands.log"
        self._write_stub(
            self.bin_dir / "qemu-system-riscv64",
            f"""#!/bin/sh
printf 'qemu|%s\\n' "$*" >> {self.log_file}
exit 0
""",
        )
        self._write_stub(
            self.bin_dir / "ivshmem-server",
            f"""#!/bin/sh
printf 'ivshmem-server|%s\\n' "$*" >> {self.log_file}
exit 0
""",
        )
        self._write_stub(self.bin_dir / "ss", "#!/bin/sh\nexit 1\n")

    def tearDown(self):
        self.tmpdir.cleanup()

    def _write_stub(self, path: Path, contents: str) -> None:
        path.write_text(textwrap.dedent(contents), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def test_freertos_runner_uses_custom_machine_and_two_chardevs(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "BUILD_DIR": str(self.bin_dir),
                "FREERTOS_DEMO_ELF": "/tmp/freertos-riscv-demo.elf",
                "IVSHMEM_ARM_FREERTOS_SOCKET": "/tmp/ivshmem-arm-freertos/sock",
                "IVSHMEM_RISCV_FREERTOS_SOCKET": "/tmp/ivshmem-riscv-freertos/sock",
            }
        )

        result = subprocess.run(
            ["bash", str(RUN_SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log_file.read_text(encoding="utf-8")
        self.assertIn("chimera-riscv-freertos-demo", log)
        self.assertIn("ivshmem-arm-freertos=armft", log)
        self.assertIn("ivshmem-riscv-freertos=riscvft", log)
        self.assertIn("path=/tmp/ivshmem-arm-freertos/sock", log)
        self.assertIn("path=/tmp/ivshmem-riscv-freertos/sock", log)

    def test_arm_freertos_server_uses_dedicated_socket(self):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "BUILD_DIR": str(self.bin_dir),
                "IVSHMEM_ARM_FREERTOS_DIR": "/tmp/ivshmem-arm-freertos",
                "IVSHMEM_ARM_FREERTOS_SOCKET": "/tmp/ivshmem-arm-freertos/sock",
            }
        )

        result = subprocess.run(
            ["bash", str(SERVER_SCRIPT)],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(REPO_ROOT),
            env=env,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log_file.read_text(encoding="utf-8")
        self.assertIn("-S /tmp/ivshmem-arm-freertos/sock", log)
```

- [ ] **Step 2: Run the launch test and verify it fails**

Run:

```bash
python3 -m unittest tests/unit/test_heterogeneous_soc_phase5_launch.py -v
```

Expected: FAIL because the Phase 5 scripts do not exist yet.

- [ ] **Step 3: Add the dedicated Phase 5 server and guest launch scripts**

```bash
# scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}"
rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}" -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" -v
```

```bash
# scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
mkdir -p "${IVSHMEM_RISCV_FREERTOS_DIR}"
rm -f "${IVSHMEM_RISCV_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" -v
```

```bash
# scripts/heterogeneous-soc/run-arm-phase5.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
bash "${SCRIPT_DIR}/prepare-arm-phase2-boot-assets.sh"
bash "${SCRIPT_DIR}/prepare-demo-guest-overlays.sh"
exec qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu cortex-a57 -m 512M -smp 2 \
  -bios "${ARM_UEFI_BIOS}" \
  -kernel "${ARM_KERNEL_IMAGE}" \
  -initrd "${ARM_INITRAMFS_COMBINED}" \
  -append "${ARM_KERNEL_CMDLINE}" \
  -chardev socket,id=ivshmem,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
  -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
  -drive file="${ARM_ISO}",media=cdrom \
  -netdev user,id=net0,hostfwd=tcp::"${ARM_SSH_PORT}"-:22 \
  -device virtio-net-device,netdev=net0 \
  -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
  -nographic
```

```bash
# scripts/heterogeneous-soc/run-riscv-phase5.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
RISCV_BOOT_MODE="${RISCV_BOOT_MODE:-direct}"
bash "${SCRIPT_DIR}/prepare-riscv-uboot.sh"
bash "${SCRIPT_DIR}/prepare-riscv-phase3-boot-assets.sh"
bash "${SCRIPT_DIR}/prepare-demo-guest-overlays.sh"
exec qemu-system-riscv64 \
  -machine virt,aclint=on \
  -cpu rv64,h=true,v=true \
  -m 2G -smp 4 \
  -bios "${RISCV_OPENSBI_BIOS}" \
  -kernel "${RISCV_KERNEL_IMAGE}" \
  -initrd "${RISCV_INITRAMFS_COMBINED}" \
  -append "${RISCV_KERNEL_CMDLINE}" \
  -chardev socket,id=ivshmem,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
  -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
  -drive file="${RISCV_DISK}",if=none,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -drive file="${RISCV_ISO}",media=cdrom,if=none,id=cd0,readonly=on \
  -device virtio-blk-device,drive=cd0 \
  -netdev user,id=net0,hostfwd=tcp::"${RISCV_SSH_PORT}"-:22 \
  -device virtio-net-device,netdev=net0 \
  -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
  -nographic
```

```bash
# scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
exec qemu-system-riscv64 \
  -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft \
  -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
  -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
  -bios "${FREERTOS_DEMO_ELF}" \
  -nographic
```

```bash
# scripts/heterogeneous-soc/run-hello-arm.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"
if [[ -x /usr/local/bin/hello-arm-linux ]]; then
  exec /usr/local/bin/hello-arm-linux "${BAR2_PATH}"
fi
if [[ -x /mnt/pingpong/freertos-showcase/hello-arm-linux ]]; then
  exec /mnt/pingpong/freertos-showcase/hello-arm-linux "${BAR2_PATH}"
fi
exec "${HELLO_ARM_BINARY}" "${BAR2_PATH}"
```

```bash
# scripts/heterogeneous-soc/run-hello-riscv.sh
#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
BAR2_PATH="${1:-${IVSHMEM_BAR2_PATH:-/sys/bus/pci/devices/0000:00:01.0/resource2}}"
if [[ -x /usr/local/bin/hello-riscv-linux ]]; then
  exec /usr/local/bin/hello-riscv-linux "${BAR2_PATH}"
fi
if [[ -x /mnt/pingpong/freertos-showcase/hello-riscv-linux ]]; then
  exec /mnt/pingpong/freertos-showcase/hello-riscv-linux "${BAR2_PATH}"
fi
exec "${HELLO_RISCV_BINARY}" "${BAR2_PATH}"
```

- [ ] **Step 4: Run the Phase 5 script test and verify it passes**

Run:

```bash
python3 -m unittest tests/unit/test_heterogeneous_soc_phase5_launch.py -v
```

Expected: PASS for both the custom-machine launch test and the dedicated-server-socket test.

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh \
  scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh \
  scripts/heterogeneous-soc/run-arm-phase5.sh \
  scripts/heterogeneous-soc/run-riscv-phase5.sh \
  scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh \
  scripts/heterogeneous-soc/run-hello-arm.sh \
  scripts/heterogeneous-soc/run-hello-riscv.sh \
  tests/unit/test_heterogeneous_soc_phase5_launch.py
git commit -m "feat: add phase5 freertos showcase launch flow"
```

## Task 6: Update the Docs and Run the End-to-End Verification

**Files:**
- Modify: `docs/system/devices/heterogeneous-soc.rst`
- Modify: `contrib/heterogeneous-soc/README.rst`
- Modify: `docs/heterogeneous-soc-plan.md`

- [ ] **Step 1: Update the docs to describe both supported showcase modes**

```rst
.. add to docs/system/devices/heterogeneous-soc.rst

* Phase 4 cross-cluster ping/pong:

  * ARM/Linux guest running ``contrib/heterogeneous-soc/ping``
  * RISC-V/Linux guest running ``contrib/heterogeneous-soc/pong``

* Phase 5 Linux + FreeRTOS hello/ack:

  * ARM/Linux guest running ``contrib/heterogeneous-soc/freertos-showcase/hello-arm-linux``
  * RISC-V/Linux guest running ``contrib/heterogeneous-soc/freertos-showcase/hello-riscv-linux``
  * RISC-V FreeRTOS guest running ``contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf``
```

```rst
.. add to contrib/heterogeneous-soc/README.rst

* ``freertos-showcase/hello_proto.h`` defines the Phase 5 Linux/FreeRTOS protocol.
* ``freertos-showcase/linux_hello.c`` is compiled twice for the Linux senders.
* ``freertos-showcase/freertos-riscv-demo.elf`` is the RISC-V FreeRTOS responder.
```

```md
<!-- append to docs/heterogeneous-soc-plan.md -->
### Phase 5 — ARM/Linux + RISC-V/Linux to RISC-V/FreeRTOS

**Goal:** Both Linux guests send timestamped hello messages to a dedicated
RISC-V FreeRTOS guest over two separate ivshmem links, and the FreeRTOS guest
acknowledges each request with its own timestamp.
```

- [ ] **Step 2: Run the automated checks before manual bring-up**

Run:

```bash
meson test -C build-linux \
  test-heterogeneous-soc-protocol \
  test-heterogeneous-soc-freertos-protocol \
  --print-errorlogs

QEMU_RISCV64_BIN=build-linux/qemu-system-riscv64 \
python3 -m unittest \
  tests/unit/test_find_ivshmem_bar2.py \
  tests/unit/test_heterogeneous_soc_freertos_machine.py \
  tests/unit/test_heterogeneous_soc_phase5_launch.py -v
```

Expected: PASS for all unit and script tests.

- [ ] **Step 3: Run the end-to-end manual verification**

Run in three host terminals:

```bash
scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh
scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh
scripts/heterogeneous-soc/build-freertos-showcase.sh
scripts/heterogeneous-soc/run-arm-phase5.sh
scripts/heterogeneous-soc/run-riscv-phase5.sh
scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh
```

Then inside the Linux guests:

```bash
busybox mkdir -p /mnt/pingpong
busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong
/mnt/pingpong/freertos-showcase/hello-arm-linux
/mnt/pingpong/freertos-showcase/hello-riscv-linux
```

Expected console output:

- ARM/Linux prints `HELLO` and receives an `ACK`.
- RISC-V/Linux prints `HELLO` and receives an `ACK`.
- FreeRTOS prints one line for the ARM/Linux request and one line for the RISC-V/Linux request.
- The original Phase 4 scripts still run unchanged:

```bash
scripts/heterogeneous-soc/start-ivshmem-server.sh
scripts/heterogeneous-soc/run-arm-phase1.sh
scripts/heterogeneous-soc/run-riscv-phase3.sh
```

- [ ] **Step 4: Commit**

```bash
git add \
  docs/system/devices/heterogeneous-soc.rst \
  contrib/heterogeneous-soc/README.rst \
  docs/heterogeneous-soc-plan.md
git commit -m "docs: document freertos showcase"
```
