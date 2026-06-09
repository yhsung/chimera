# CAN Bus Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect ARM-Linux and FreeRTOS guests to a shared `vcan0` CAN bus so a user on Lima can `cansend vcan0 123#DEADBEEF` and have ARM-Linux receive it on `can0` while FreeRTOS receives it via a real GIC interrupt, prints it on UART, and forwards it over a new ivshmem channel (IVSHMEM5) to an ARM-Linux daemon that appends both sources to `/var/log/chimera-log/can-bus.log`.

**Architecture:** Two separate QEMU processes (ARM-Linux `qemu-system-aarch64`, FreeRTOS `qemu-system-arm`) each attach a `can-host-socketcan` backend to Lima's kernel `vcan0`, which broadcasts every frame to all listeners — emulating one physical bus. ARM-Linux uses an existing `kvaser_pci` device → `can0`. The FreeRTOS `chimera-r52-freertos-demo` machine gains an `xlnx-zynqmp-can` controller at `0x50000000` wired to GIC SPI 6 (INTID 38); FreeRTOS services its RX interrupt, decodes the frame, and publishes it on a new IVSHMEM5 channel using the same magic+generation pattern as the existing stats channel. A two-threaded ARM-Linux daemon tails both `can0` (SocketCAN) and IVSHMEM5.

**Tech Stack:** QEMU device model (C, QOM/sysbus), bare-metal FreeRTOS firmware on Cortex-R52 (C + ARM GICv2 MMIO), Linux SocketCAN + ivshmem BAR2 mmap (C), bash launch/harness scripts, `can-utils`.

---

## Design Decisions (read before starting)

These resolve conflicts between the spec (`docs/superpowers/specs/2026-06-10-can-bus-design.md`) and the existing codebase. They are intentional and must be honored:

1. **Real GIC interrupt for CAN RX (user-confirmed).** Unlike the ivshmem channels (which are flag-polled — see `freertos_main.c:297`), CAN RX uses a true interrupt on GIC SPI 6 (INTID 38), dispatched through the existing `vApplicationIRQHandler` alongside the timer tick (INTID 30). `can_init()` must enable the SPI in the GIC distributor itself (enable bit, priority, **and CPU-target register** — SPIs, unlike the banked timer PPI, need an explicit target).

2. **`GIC_NUM_IRQ` 64 → 96 is safe.** The board computes `ppibase = GIC_NUM_IRQ - 32` precisely so the timer PPI wiring tracks the PPI gpio-in block (`hw/intc/arm_gic_common.c:136-146`: SPI inputs are indices `0..num_irq-32-1`, PPI block starts at index `num_irq-32`). Bumping to 96 keeps the timer at INTID 30 and adds SPI headroom. (SPI 6/7 already fit in 64; the bump follows the spec and is harmless.)

3. **IVSHMEM5 uses the stats channel's magic+generation layout, not the spec's "clear-magic" scheme.** The ARM-Linux daemon discovers its BAR2 by scanning for a fixed channel magic (exactly like `linux_stats.c:find_stats_shm`). A per-frame "clear the magic after reading" scheme would erase the discovery marker. Instead FreeRTOS writes the channel magic **once** at init and bumps a `generation` counter per frame; the daemon tracks the last generation it logged. This is the proven pattern already in `stats_proto.h`.

4. **Reading `RXFIFO_ID` pops the entire frame.** In `xlnx-zynqmp-can.c`, `can_rxfifo_post_read_id` (line 781) pops all four FIFO words and latches DLC/DATA1/DATA2 into registers on the **ID read**. The driver MUST read `RXFIFO_ID` (0x50) first, then read DLC/DATA1/DATA2.

5. **The ARM-Linux daemon lives in `contrib/heterogeneous-soc/freertos-showcase/`**, not the spec's `syslog-arm-linux/` directory. All Linux daemons in this repo (`linux_syslog.c`, `linux_stats.c`) live there and the `Makefile`/`common.sh`/install scripts key off it. The shared frame/decode header is `can_proto.h` in the same directory (peer to `hello_proto.h`, `stats_proto.h`).

6. **Runtime caveat — `CAP_NET_RAW`.** `can-host-socketcan` opens an `AF_CAN` raw socket bound to `vcan0`; QEMU needs `CAP_NET_RAW`. Scripts must either run the QEMU binary with that capability (`sudo setcap cap_net_raw+eip <qemu-system-*>`) or accept that the CAN backend is skipped. This is handled explicitly in the script tasks.

7. **Daemon launched via tmux, not a systemd unit.** The spec mentions a `chimera-can-log.service` systemd unit, but no daemon in this repo (`linux_stats`, `syslog-*-linux`, `bootlog-*-linux`) runs under systemd — they are all started by `auto_login_and_run` in `guest-run-phase5-tmux.sh`. The plan follows that established convention (Task 10 Step 3) rather than introducing a one-off systemd unit. The repo's `chimera-syslog.service` is an **Avahi** service-advertisement file, not a daemon unit.

## File Structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `contrib/heterogeneous-soc/freertos-showcase/can_proto.h` | Create | Shared: `can_ivshmem_frame`/`can_ivshmem_layout` structs, `CAN_IVSHMEM_MAGIC`, and pure `static inline` register-decode helpers (host-testable). |
| `contrib/heterogeneous-soc/freertos-showcase/test_can_decode.c` | Create | Host unit test for the decode helpers (TDD). |
| `include/hw/arm/chimera_r52_freertos_demo.h` | Modify | CAN + IVSHMEM5 memmap/SPI enums, props, machine-state fields, `GIC_NUM_IRQ` bump. |
| `hw/arm/chimera_r52_freertos_demo.c` | Modify | memmap entries; instantiate `xlnx-zynqmp-can` @ SPI 6; wire IVSHMEM5 @ SPI 7; register `canbus`/`ivshmem-can-freertos` props. |
| `hw/arm/Kconfig` | Modify | `select XLNX_ZYNQMP` so the CAN device + CAN bus core compile into `arm-softmmu`. |
| `contrib/heterogeneous-soc/freertos-showcase/can_driver.h` | Create | CAN register constants + driver API. |
| `contrib/heterogeneous-soc/freertos-showcase/can_driver.c` | Create | `can_init()` (CAN enable + GIC SPI 6 setup + IVSHMEM5 init), `can_rx_isr()` (drain RX, UART print, publish to IVSHMEM5). |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Modify | Dispatch INTID 38 → `can_rx_isr()`; call `can_init()` in startup. |
| `contrib/heterogeneous-soc/freertos-showcase/Makefile` | Modify | Add `can_driver.c`/`can_proto.h` to the ELF target; add `can-log-arm-linux` target; add `test_can_decode` target. |
| `contrib/heterogeneous-soc/freertos-showcase/can_log.c` | Create | ARM-Linux daemon: thread 1 reads `can0` (SocketCAN), thread 2 polls IVSHMEM5; both append to `can-bus.log`. |
| `scripts/heterogeneous-soc/common.sh` | Modify | `IVSHMEM_CAN_FREERTOS_*` and `CAN_LOG_ARM_BINARY` vars. |
| `scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh` | Create | ivshmem-server for the CAN channel. |
| `scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh` | Modify | Add CAN backend + IVSHMEM5 chardev + machine options. |
| `scripts/heterogeneous-soc/guest-run-arm-phase5.sh` | Modify | Add CAN backend + `kvaser_pci` + IVSHMEM5 ivshmem-doorbell. |
| `scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh` | Modify | Inject `can-log-arm-linux` into the ARM qcow2. |
| `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` | Modify | Start CAN ivshmem-server; bring up `can0` and launch the daemon in the ARM pane. |
| `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh` | Modify | Register the CAN ivshmem-server in startup; ensure Lima `vcan0` exists; pkill pattern. |
| `scripts/heterogeneous-soc/guest-run-can-harness.sh` | Create | Headless pass/fail test: send a frame, assert UART `CAN RX:` line and `can-bus.log` entries. |
| `README.md` / `CLAUDE.md` | Modify | Update the ivshmem channel map with IVSHMEM5 + CAN controller. |

---

## Task 1: CAN frame decode helpers + host unit test (TDD)

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/can_proto.h`
- Test: `contrib/heterogeneous-soc/freertos-showcase/test_can_decode.c`

The decode helpers are pure functions of the raw `xlnx-zynqmp-can` register values, so they are unit-testable on the host. Both the FreeRTOS firmware and the ARM-Linux daemon include this header. Field positions verified against `hw/net/can/xlnx-zynqmp-can.c` (RXFIFO_ID IDH = bits 21–31; RXFIFO_DLC DLC = bits 28–31; DATA1 DB0..DB3 = bits 24..0; DATA2 DB4..DB7 = bits 24..0).

- [ ] **Step 1: Write the failing test**

Create `contrib/heterogeneous-soc/freertos-showcase/test_can_decode.c`:

```c
/* Host unit test for can_proto.h decode helpers. Build: cc -O2 -Wall -o test_can_decode test_can_decode.c */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "can_proto.h"

int main(void)
{
    /* Raw register values QEMU's xlnx-zynqmp-can latches for `cansend vcan0 123#DEADBEEF`:
     * standard ID 0x123 in IDH (bits 21-31), DLC 4 in bits 28-31,
     * data DE AD BE EF packed DB0..DB3 (bits 24..0) of DATA1. */
    uint32_t id_reg  = 0x123u << 21;      /* 0x24600000 */
    uint32_t dlc_reg = 4u << 28;          /* 0x40000000 */
    uint32_t d1      = 0xDEADBEEFu;       /* DB0=DE DB1=AD DB2=BE DB3=EF */
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd contrib/heterogeneous-soc/freertos-showcase && cc -O2 -Wall -o /tmp/test_can_decode test_can_decode.c && /tmp/test_can_decode`
Expected: FAIL — `fatal error: can_proto.h: No such file or directory`.

- [ ] **Step 3: Write `can_proto.h`**

Create `contrib/heterogeneous-soc/freertos-showcase/can_proto.h`:

```c
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd contrib/heterogeneous-soc/freertos-showcase && cc -O2 -Wall -o /tmp/test_can_decode test_can_decode.c && /tmp/test_can_decode`
Expected: PASS — prints `test_can_decode: OK`.

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/can_proto.h \
        contrib/heterogeneous-soc/freertos-showcase/test_can_decode.c
git commit -m "feat(can): add CAN frame proto + decode helpers with host test"
```

---

## Task 2: QEMU machine header — CAN + IVSHMEM5 declarations

**Files:**
- Modify: `include/hw/arm/chimera_r52_freertos_demo.h`

- [ ] **Step 1: Bump `GIC_NUM_IRQ` and add property macros + state fields**

In `include/hw/arm/chimera_r52_freertos_demo.h`, change the GIC sizing constant (line 27) from:

```c
#define CHIMERA_R52_FREERTOS_GIC_NUM_IRQ 64
```

to:

```c
#define CHIMERA_R52_FREERTOS_GIC_NUM_IRQ 96
```

Add two new property-name macros after the existing `CHIMERA_R52_FREERTOS_PROP_IVSHMEM_BOOTLOG` define (line 22):

```c
#define CHIMERA_R52_FREERTOS_PROP_CANBUS "canbus"
#define CHIMERA_R52_FREERTOS_PROP_IVSHMEM_CAN "ivshmem-can-freertos"
```

Add two new fields to `struct ChimeraR52FreeRTOSMachineState` (after `char *ivshmem_bootlog_freertos;`, line 48):

```c
    char *canbus_id;
    char *ivshmem_can_freertos;
```

- [ ] **Step 2: Extend the memmap enum**

Append to the memmap `enum` (after `CHIMERA_R52_FREERTOS_IVSHMEM4_SHMEM,`, line 65):

```c
    CHIMERA_R52_FREERTOS_IVSHMEM5_MMIO,
    CHIMERA_R52_FREERTOS_IVSHMEM5_SHMEM,
    CHIMERA_R52_FREERTOS_CAN_MMIO,
```

- [ ] **Step 3: Extend the SPI enum**

Append to the SPI `enum` (after `CHIMERA_R52_FREERTOS_IVSHMEM4_SPI = 5,`, line 75):

```c
    CHIMERA_R52_FREERTOS_CAN_SPI = 6,
    CHIMERA_R52_FREERTOS_IVSHMEM5_SPI = 7,
```

- [ ] **Step 4: Verify it still parses (sanity compile of the header)**

Run: `cc -fsyntax-only -I include -I . include/hw/arm/chimera_r52_freertos_demo.h 2>&1 | head` (QEMU-internal includes will error, but the new lines must not introduce syntax errors local to this file). Expected: no error pointing at the lines you added. Definitive verification happens at the QEMU build in Task 4.

- [ ] **Step 5: Commit**

```bash
git add include/hw/arm/chimera_r52_freertos_demo.h
git commit -m "feat(can): declare CAN + IVSHMEM5 memmap/SPI/props on chimera-r52 machine"
```

---

## Task 3: QEMU machine — instantiate CAN controller + IVSHMEM5 wiring

**Files:**
- Modify: `hw/arm/chimera_r52_freertos_demo.c`

- [ ] **Step 1: Add memmap entries**

In `hw/arm/chimera_r52_freertos_demo.c`, inside `chimera_r52_memmap[]` (after the IVSHMEM4 entries, line 55), add:

```c
    [CHIMERA_R52_FREERTOS_IVSHMEM5_MMIO] =  { 0x49000000, 0x00001000 },
    [CHIMERA_R52_FREERTOS_IVSHMEM5_SHMEM] = {
        0x4A000000, 0x00010000 /* 64 KiB */
    },
    [CHIMERA_R52_FREERTOS_CAN_MMIO] =       { 0x50000000, 0x00001000 },
```

- [ ] **Step 2: Add the new chardev string properties**

After `CHIMERA_R52_CHARDEV_PROP(ivshmem_bootlog_freertos)` (line 80) add:

```c
CHIMERA_R52_CHARDEV_PROP(ivshmem_can_freertos)
```

The `canbus_id` property is a plain string (not a chardev), so add a getter/setter pair right after, mirroring the macro's bodies but without `qemu_chr_*`:

```c
static char *chimera_r52_get_canbus_id(Object *obj, Error **errp)
{
    ChimeraR52FreeRTOSMachineState *s = CHIMERA_R52_FREERTOS_MACHINE(obj);

    return g_strdup(s->canbus_id);
}

static void chimera_r52_set_canbus_id(Object *obj, const char *value,
                                      Error **errp)
{
    ChimeraR52FreeRTOSMachineState *s = CHIMERA_R52_FREERTOS_MACHINE(obj);

    g_free(s->canbus_id);
    s->canbus_id = g_strdup(value);
}
```

- [ ] **Step 3: Add a CAN-controller instantiation helper**

Add this `#include` near the existing device includes (after `#include "hw/misc/ivshmem-flat.h"`, line 23):

```c
#include "hw/qdev-core.h"
#include "qom/object_interfaces.h"
```

Add a helper function just after `chimera_r52_connect_ivshmem()` (line 108):

```c
#define TYPE_XLNX_ZYNQMP_CAN_DEV "xlnx.zynqmp-can"

static void chimera_r52_connect_can(DeviceState *gic, const char *canbus_id,
                                    hwaddr mmio_base, int spi_index)
{
    Object *canbus;
    DeviceState *dev;
    SysBusDevice *sbd;

    canbus = object_resolve_path_component(object_get_objects_root(),
                                           canbus_id);
    if (!canbus) {
        error_report("canbus object '%s' not found", canbus_id);
        exit(EXIT_FAILURE);
    }

    if (!module_object_class_by_name(TYPE_XLNX_ZYNQMP_CAN_DEV)) {
        error_report("xlnx.zynqmp-can is unavailable in this QEMU build");
        exit(EXIT_FAILURE);
    }

    dev = qdev_new(TYPE_XLNX_ZYNQMP_CAN_DEV);
    object_property_set_link(OBJECT(dev), "canbus", canbus, &error_fatal);
    /* Cortex-R52 demo: nominal 24 MHz CAN reference clock. */
    qdev_prop_set_uint32(dev, "ext_clk_freq", 24000000);

    sbd = SYS_BUS_DEVICE(dev);
    sysbus_realize_and_unref(sbd, &error_fatal);
    sysbus_mmio_map(sbd, 0, mmio_base);
    sysbus_connect_irq(sbd, 0, qdev_get_gpio_in(gic, spi_index));
}
```

- [ ] **Step 4: Resolve the new chardev + wire devices in `chimera_r52_machine_init`**

In `chimera_r52_machine_init()`, add a local declaration next to `Chardev *stats_chr = NULL, *bootlog_chr = NULL;` (line 119):

```c
    Chardev *can_chr = NULL;
```

Add chardev resolution right after the bootlog block (after line 145, before `if (!have_links)`):

```c
    if (s->ivshmem_can_freertos) {
        can_chr = qemu_chr_find(s->ivshmem_can_freertos);
        if (!can_chr) {
            warn_report("chardev '%s' not found, IVSHMEM5 CAN channel skipped",
                        s->ivshmem_can_freertos);
        }
    }
```

Add the IVSHMEM5 + CAN wiring right after the `if (bootlog_chr) { ... }` block (after line 241), before `bootinfo.ram_size = ...`:

```c
    if (can_chr) {
        chimera_r52_connect_ivshmem(
            gicdev, can_chr,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM5_MMIO].base,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_IVSHMEM5_SHMEM].base,
            (uint32_t)chimera_r52_memmap[
                CHIMERA_R52_FREERTOS_IVSHMEM5_SHMEM].size,
            CHIMERA_R52_FREERTOS_IVSHMEM5_SPI);
    }
    if (s->canbus_id) {
        chimera_r52_connect_can(
            gicdev, s->canbus_id,
            chimera_r52_memmap[CHIMERA_R52_FREERTOS_CAN_MMIO].base,
            CHIMERA_R52_FREERTOS_CAN_SPI);
    }
```

- [ ] **Step 5: Register the new machine properties in `chimera_r52_machine_class_init`**

Append after the bootlog property registration (after line 300):

```c
    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_CAN,
                                  chimera_r52_get_ivshmem_can_freertos,
                                  chimera_r52_set_ivshmem_can_freertos);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_IVSHMEM_CAN,
        "Chardev id for the CAN-frame FreeRTOS -> ARM-Linux ivshmem link");

    object_class_property_add_str(oc, CHIMERA_R52_FREERTOS_PROP_CANBUS,
                                  chimera_r52_get_canbus_id,
                                  chimera_r52_set_canbus_id);
    object_class_property_set_description(
        oc, CHIMERA_R52_FREERTOS_PROP_CANBUS,
        "Object id of the can-bus this machine's CAN controller attaches to");
```

- [ ] **Step 6: Commit (build verification deferred to Task 4)**

```bash
git add hw/arm/chimera_r52_freertos_demo.c
git commit -m "feat(can): wire xlnx-zynqmp-can + IVSHMEM5 into chimera-r52 machine"
```

---

## Task 4: Build config — make the CAN device available in `arm-softmmu`

**Files:**
- Modify: `hw/arm/Kconfig` (the `CHIMERA_R52_FREERTOS_DEMO` block, lines 92-98)

The `xlnx-zynqmp-can.c` device file compiles only when `CONFIG_XLNX_ZYNQMP=y` (`hw/net/can/meson.build:7`). `CONFIG_XLNX_ZYNQMP` also `select`s `CAN_BUS`, which is what builds the `can-bus`/`can-host-socketcan` core (`net/can/meson.build`). Selecting it from the board is the minimal way to pull both in for `qemu-system-arm`.

- [ ] **Step 1: Add the `select` to the board's Kconfig**

In `hw/arm/Kconfig`, change the `CHIMERA_R52_FREERTOS_DEMO` block from:

```
config CHIMERA_R52_FREERTOS_DEMO
    bool
    default y
    depends on TCG && ARM
    select ARM_GIC
    select PL011
    select IVSHMEM_FLAT_DEVICE
```

to (add the final line):

```
config CHIMERA_R52_FREERTOS_DEMO
    bool
    default y
    depends on TCG && ARM
    select ARM_GIC
    select PL011
    select IVSHMEM_FLAT_DEVICE
    select XLNX_ZYNQMP
```

- [ ] **Step 2: Build QEMU (configure if needed) and verify the device exists**

Run, on the Lima VM (canonical source is deployed there per `common.sh`):

```bash
limactl shell qemu-dev -- bash -lc '
  set -e
  cd ~/chimera-src 2>/dev/null || cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
  BUILD_DIR="${BUILD_DIR:-$HOME/chimera-build-linux}"
  ninja -C "$BUILD_DIR" qemu-system-arm qemu-system-aarch64
  "$BUILD_DIR/qemu-system-arm" -device help 2>&1 | grep -i "xlnx.zynqmp-can"
  "$BUILD_DIR/qemu-system-aarch64" -device help 2>&1 | grep -i "kvaser_pci"
'
```

Expected: the `ninja` build completes with no errors, and both `grep`s print a matching device line (`name "xlnx.zynqmp-can"` and `name "kvaser_pci"`). If `arm-softmmu` is not in the configured target list, re-run `configure` with `--target-list=...,arm-softmmu,aarch64-softmmu,...` first (see commit `dc4d02b969`).

- [ ] **Step 3: Verify the machine accepts the new properties**

Run:

```bash
limactl shell qemu-dev -- bash -lc '
  BUILD_DIR="${BUILD_DIR:-$HOME/chimera-build-linux}"
  "$BUILD_DIR/qemu-system-arm" -machine chimera-r52-freertos-demo,help 2>&1 | grep -iE "canbus|ivshmem-can-freertos"
'
```

Expected: prints the `canbus` and `ivshmem-can-freertos` machine options.

- [ ] **Step 4: Commit**

```bash
git add hw/arm/Kconfig
git commit -m "build(can): select XLNX_ZYNQMP so chimera-r52 gets CAN device + bus"
```

---

## Task 5: FreeRTOS CAN driver

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/can_driver.h`
- Create: `contrib/heterogeneous-soc/freertos-showcase/can_driver.c`

- [ ] **Step 1: Write the driver header**

Create `contrib/heterogeneous-soc/freertos-showcase/can_driver.h`:

```c
#ifndef HETEROGENEOUS_SOC_FREERTOS_CAN_DRIVER_H
#define HETEROGENEOUS_SOC_FREERTOS_CAN_DRIVER_H

#include <stdint.h>

/* xlnx-zynqmp-can register offsets (see hw/net/can/xlnx-zynqmp-can.c). */
#define CAN_REG_SRR        0x00U   /* SoftwareResetRegister: bit1 CEN, bit0 SRST */
#define CAN_REG_MSR        0x04U   /* ModeSelectRegister (0 = normal) */
#define CAN_REG_SR         0x18U   /* StatusRegister */
#define CAN_REG_ISR        0x1CU   /* InterruptStatusRegister */
#define CAN_REG_IER        0x20U   /* InterruptEnableRegister */
#define CAN_REG_ICR        0x24U   /* InterruptClearRegister */
#define CAN_REG_RXFIFO_ID  0x50U   /* reading this pops the whole RX frame */
#define CAN_REG_RXFIFO_DLC 0x54U
#define CAN_REG_RXFIFO_D1  0x58U
#define CAN_REG_RXFIFO_D2  0x5CU

#define CAN_SRR_CEN        (1U << 1)   /* controller enable */
#define CAN_ISR_RXOK       (1U << 4)   /* RX-OK / ERXOK / CRXOK all bit 4 */

/* Initialise the CAN controller, enable its GIC SPI, and prepare the
 * IVSHMEM5 forwarding channel. Call once, before the scheduler relies on it. */
void can_init(uintptr_t can_mmio_base, uintptr_t ivshmem_can_shmem_base);

/* Called from vApplicationIRQHandler when INTID 38 (CAN SPI 6) fires. */
void can_rx_isr(void);

#endif
```

- [ ] **Step 2: Write the driver implementation**

Create `contrib/heterogeneous-soc/freertos-showcase/can_driver.c`:

```c
#include "can_driver.h"
#include "can_proto.h"
#include "freertos_ivshmem_flat.h"   /* for HSOC_LOG_* levels */

extern void log_uart(uint32_t level, const char *msg);

/* ---- GIC distributor MMIO (GICv2, matches freertos_main.c constants) ---- */
#define GICD_BASE          0x08000000UL
#define GICD_ISENABLER     0x100U   /* +(intid/32)*4, bit intid%32 */
#define GICD_IPRIORITYR    0x400U   /* byte per intid */
#define GICD_ITARGETSR     0x800U   /* byte per intid (CPU target bitmask) */

#define CAN_INTID          38U      /* SPI 6 = INTID 32 + 6 */

static volatile uint32_t *can_regs;          /* CAN MMIO window */
static volatile struct can_ivshmem_layout *can_ivshmem;

static inline uint32_t can_rd(uint32_t off)
{
    return can_regs[off / sizeof(uint32_t)];
}

static inline void can_wr(uint32_t off, uint32_t val)
{
    can_regs[off / sizeof(uint32_t)] = val;
}

static void shmem_write_bytes(volatile void *dst, const void *src, uint32_t n)
{
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    uint32_t i;

    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static void gic_enable_spi(uint32_t intid)
{
    volatile uint32_t *isen =
        (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);
    volatile uint8_t *iprio =
        (volatile uint8_t *)(GICD_BASE + GICD_IPRIORITYR);
    volatile uint8_t *itarget =
        (volatile uint8_t *)(GICD_BASE + GICD_ITARGETSR);

    /* Same mid priority the timer tick uses; route to CPU 0. SPIs (unlike the
     * banked timer PPI) need an explicit ITARGETSR target or they never reach
     * a CPU interface. GICD_CTLR group-0 forwarding is already enabled by the
     * tick setup in vConfigureTickInterrupt(). */
    iprio[intid] = 0xA0;
    itarget[intid] = 0x01;
    isen[intid / 32] = (1U << (intid % 32));
}

static void uart_hex2(uint8_t b)
{
    static const char hex[] = "0123456789abcdef";
    char s[3];
    s[0] = hex[(b >> 4) & 0xf];
    s[1] = hex[b & 0xf];
    s[2] = '\0';
    log_uart(HSOC_LOG_INFO, s);
}

void can_init(uintptr_t can_mmio_base, uintptr_t ivshmem_can_shmem_base)
{
    can_regs = (volatile uint32_t *)can_mmio_base;
    can_ivshmem =
        (volatile struct can_ivshmem_layout *)ivshmem_can_shmem_base;

    /* Publish the channel identity once so the ARM-Linux daemon can find this
     * BAR2 by magic, then zero the generation counter. */
    can_ivshmem->magic = CAN_IVSHMEM_MAGIC;
    can_ivshmem->generation = 0;
    __sync_synchronize();

    /* Normal mode (MSR=0 at reset), enable controller, enable RX-OK IRQ. */
    can_wr(CAN_REG_MSR, 0);
    can_wr(CAN_REG_SRR, CAN_SRR_CEN);
    can_wr(CAN_REG_IER, CAN_ISR_RXOK);

    gic_enable_spi(CAN_INTID);

    log_uart(HSOC_LOG_INFO, "[freertos] CAN controller enabled (SPI 6)\n");
}

void can_rx_isr(void)
{
    uint32_t isr = can_rd(CAN_REG_ISR);
    struct can_ivshmem_frame f;
    uint32_t id_reg, dlc_reg, d1, d2;
    uint32_t i;

    if (!(isr & CAN_ISR_RXOK)) {
        return;
    }

    /* Read RXFIFO_ID FIRST: that read pops the frame and latches DLC/D1/D2. */
    id_reg  = can_rd(CAN_REG_RXFIFO_ID);
    dlc_reg = can_rd(CAN_REG_RXFIFO_DLC);
    d1      = can_rd(CAN_REG_RXFIFO_D1);
    d2      = can_rd(CAN_REG_RXFIFO_D2);

    /* Acknowledge the interrupt (CRXOK is bit 4 of ICR). */
    can_wr(CAN_REG_ICR, CAN_ISR_RXOK);

    f.id  = can_decode_id(id_reg);
    f.dlc = (uint8_t)can_decode_dlc(dlc_reg);
    f.pad[0] = f.pad[1] = f.pad[2] = 0;
    can_decode_data(d1, d2, f.data);

    /* UART: "CAN RX: id=0x123 dlc=4 data=de ad be ef" */
    log_uart(HSOC_LOG_INFO, "CAN RX: id=0x");
    uart_hex2((uint8_t)((f.id >> 8) & 0xf)); /* high nibble of 11-bit id */
    uart_hex2((uint8_t)(f.id & 0xff));
    log_uart(HSOC_LOG_INFO, " dlc=");
    {
        char d[2];
        d[0] = '0' + (char)(f.dlc & 0x7);
        d[1] = '\0';
        log_uart(HSOC_LOG_INFO, d);
    }
    log_uart(HSOC_LOG_INFO, " data=");
    for (i = 0; i < f.dlc; i++) {
        uart_hex2(f.data[i]);
        log_uart(HSOC_LOG_INFO, (i + 1 < f.dlc) ? " " : "\n");
    }
    if (f.dlc == 0) {
        log_uart(HSOC_LOG_INFO, "\n");
    }

    /* Publish to IVSHMEM5: write the frame body, fence, then bump generation. */
    shmem_write_bytes(&can_ivshmem->frame, &f, sizeof(f));
    __sync_synchronize();
    can_ivshmem->generation = can_ivshmem->generation + 1;
    __sync_synchronize();
}
```

> Note: `log_uart` from an IRQ context performs only MMIO + ring-buffer writes (same context the timer tick already runs in). Byte interleaving with the task's own UART output is cosmetically possible but harmless for the demo.

- [ ] **Step 3: Verify it compiles against the bare-metal toolchain (header/syntax check)**

Run:

```bash
limactl shell qemu-dev -- bash -lc '
  cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase 2>/dev/null || cd /Volumes/Samsung970EVOPlus/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
  arm-none-eabi-gcc -c -O2 -Wall -Wextra -ffreestanding \
    -mcpu=cortex-r52 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm \
    -I. -I"$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/include" \
    -I"$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5" \
    can_driver.c -o /tmp/can_driver.o && echo COMPILE_OK
'
```

Expected: prints `COMPILE_OK` with no warnings/errors. (Full ELF link happens in Task 7.)

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/can_driver.h \
        contrib/heterogeneous-soc/freertos-showcase/can_driver.c
git commit -m "feat(can): FreeRTOS CAN driver — init, RX ISR, IVSHMEM5 publish"
```

---

## Task 6: Wire the CAN driver into FreeRTOS main

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`

- [ ] **Step 1: Include the driver and add base-address defines**

After `#include "boot_log.h"` (line 9) add:

```c
#include "can_driver.h"
```

After the `IVSHMEM4_SHMEM` define (line 31) add:

```c
#define IVSHMEM5_MMIO  0x49000000UL
#define IVSHMEM5_SHMEM 0x4A000000UL
#define CAN_MMIO       0x50000000UL
```

- [ ] **Step 2: Dispatch the CAN interrupt**

In `vApplicationIRQHandler` (lines 290-298), add a CAN branch and an INTID define. Change:

```c
/* port.c calls FreeRTOS_Tick_Handler() on each tick. */
extern void FreeRTOS_Tick_Handler(void);
```

to also define the CAN INTID:

```c
/* port.c calls FreeRTOS_Tick_Handler() on each tick. */
extern void FreeRTOS_Tick_Handler(void);

#define R52_CAN_INTID 38U   /* CAN controller on GIC SPI 6 */
```

Then change the handler body from:

```c
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t intid = ulICCIAR & 0x3FFU;

    if (intid == R52_TICK_INTID) {
        FreeRTOS_Tick_Handler();
    }
    /* ivshmem channels are flag-polled; their IRQs (if any fire) are ignored. */
}
```

to:

```c
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t intid = ulICCIAR & 0x3FFU;

    if (intid == R52_TICK_INTID) {
        FreeRTOS_Tick_Handler();
    } else if (intid == R52_CAN_INTID) {
        can_rx_isr();
    }
    /* ivshmem channels are flag-polled; their IRQs (if any fire) are ignored. */
}
```

- [ ] **Step 3: Initialise the CAN controller during startup**

In `showcase_task()`, just after the three `freertos_ivshmem_init(...)` calls and the stats magic init (after line 311, before the `log_uart(HSOC_LOG_INFO, "[freertos] showcase task started\n");`), add:

```c
    can_init(CAN_MMIO, IVSHMEM5_SHMEM);
```

- [ ] **Step 4: Build the full ELF and confirm no regressions**

(Depends on Task 7's Makefile change for `can_driver.c` to be linked. If executing strictly in order, do Task 7 Step 1 first, then return here — or simply run the Task 7 build verification, which covers this.) Run:

```bash
limactl shell qemu-dev -- bash -lc '
  cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase 2>/dev/null || cd /Volumes/Samsung970EVOPlus/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
  make freertos-r52-demo.elf && echo ELF_OK
'
```

Expected: `ELF_OK` (firmware links cleanly).

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "feat(can): dispatch CAN SPI 6 ISR and init CAN in FreeRTOS startup"
```

---

## Task 7: Makefile — link the driver, add daemon + test targets

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 1: Add `can_driver.c` + `can_proto.h` to the ELF target**

Change the `freertos-r52-demo.elf` rule (lines 110-119) so the prerequisite list and the compile command include `can_driver.c`/headers. Replace:

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

with:

```make
freertos-r52-demo.elf: freertos_main.c freertos_ivshmem_flat.c boot_log.c can_driver.c \
		freertos_ivshmem_flat.h freertos_libc.c startup.S linker.ld FreeRTOSConfig.h \
		hello_proto.h stats_proto.h bootlog_proto.h boot_log.h \
		can_driver.h can_proto.h $(FREERTOS_SRCS)
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_PORT_DIR) \
	  startup.S freertos_main.c freertos_ivshmem_flat.c boot_log.c can_driver.c freertos_libc.c \
	  $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@
```

- [ ] **Step 2: Add the ARM-Linux daemon target (gated on `CC_ARM`)**

Extend `SYSLOG_TARGETS` for ARM so the daemon builds with the other ARM Linux binaries. Change (lines 21-23):

```make
ifneq ($(HAVE_CC_ARM),)
SYSLOG_TARGETS += syslog-arm-linux linux-arm-stats
endif
```

to:

```make
ifneq ($(HAVE_CC_ARM),)
SYSLOG_TARGETS += syslog-arm-linux linux-arm-stats can-log-arm-linux
endif
```

Add the build rule after the `linux-arm-stats` rule (after line 75):

```make
can-log-arm-linux: can_log.c can_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) -pthread -o $@ can_log.c
```

- [ ] **Step 3: Add a `check` target for the host decode test**

Append a phony test target so the decode unit test runs from `make`:

```make
.PHONY: check
check: test_can_decode
	./test_can_decode

test_can_decode: test_can_decode.c can_proto.h
	cc -O2 -Wall -o $@ test_can_decode.c
```

Also add `test_can_decode` to the `clean` rule's `rm -f` list (line 122):

```make
clean:
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-r52-demo.elf test_can_decode
```

- [ ] **Step 4: Build everything and run the host test**

```bash
limactl shell qemu-dev -- bash -lc '
  cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase 2>/dev/null || cd /Volumes/Samsung970EVOPlus/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
  make clean && make && make check && ls -l freertos-r52-demo.elf can-log-arm-linux
'
```

Expected: `freertos-r52-demo.elf` and `can-log-arm-linux` both built; `make check` prints `test_can_decode: OK`.

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "build(can): link can_driver into ELF; add can-log daemon + check targets"
```

---

## Task 8: ARM-Linux CAN log daemon

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/can_log.c`

Two threads, one process. Thread 1 reads raw frames from `can0` via SocketCAN. Thread 2 discovers IVSHMEM5 BAR2 by `CAN_IVSHMEM_MAGIC` (reusing the `linux_stats.c` scan pattern) and polls `generation`. Both append to `/var/log/chimera-log/can-bus.log` under a shared mutex.

- [ ] **Step 1: Write the daemon**

Create `contrib/heterogeneous-soc/freertos-showcase/can_log.c`:

```c
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <net/if.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <linux/can.h>
#include <linux/can/raw.h>

#include "can_proto.h"

#define HSOC_VENDOR_ID "0x1af4"
#define CAN_MMAP_SIZE ((size_t)65536)
#define CAN_RETRY_SEC 30

static const char *g_log_path;
static FILE *g_log;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void log_frame(const char *source, uint32_t id, uint32_t dlc,
                      const uint8_t *data)
{
    struct timespec ts;
    struct tm tm_info;
    char timebuf[32];
    uint32_t i;

    clock_gettime(CLOCK_REALTIME, &ts);
    gmtime_r(&ts.tv_sec, &tm_info);
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%dT%H:%M:%SZ", &tm_info);

    pthread_mutex_lock(&g_log_lock);
    fprintf(g_log, "[%s] CAN/%s id=0x%03" PRIx32 " dlc=%" PRIu32 " data=",
            timebuf, source, id, dlc);
    for (i = 0; i < dlc && i < 8; i++) {
        fprintf(g_log, "%02x%s", data[i], (i + 1 < dlc) ? " " : "");
    }
    fputc('\n', g_log);
    fflush(g_log);
    pthread_mutex_unlock(&g_log_lock);
}

/* ---- Thread 1: SocketCAN reader on can0 ---- */
static void *socketcan_thread(void *arg)
{
    const char *ifname = arg ? (const char *)arg : "can0";
    int s;
    struct sockaddr_can addr;
    struct ifreq ifr;

    s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    if (s < 0) {
        perror("socket(PF_CAN)");
        return NULL;
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFINDEX, &ifr) < 0) {
        fprintf(stderr, "[can] %s not found (is it up?)\n", ifname);
        close(s);
        return NULL;
    }

    memset(&addr, 0, sizeof(addr));
    addr.can_family = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind(can0)");
        close(s);
        return NULL;
    }

    fprintf(stderr, "[can] socketcan reader bound to %s\n", ifname);

    for (;;) {
        struct can_frame frame;
        ssize_t n = read(s, &frame, sizeof(frame));
        if (n < (ssize_t)sizeof(frame)) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            continue;
        }
        log_frame("socketcan", frame.can_id & CAN_SFF_MASK,
                  frame.can_dlc, frame.data);
    }

    close(s);
    return NULL;
}

/* ---- Thread 2: IVSHMEM5 reader ---- */
static void shm_read(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    size_t i;
    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static volatile struct can_ivshmem_layout *find_can_shm(void)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) {
        sysfs_root = "/sys/bus/pci/devices";
    }

    for (int attempt = 0; attempt < CAN_RETRY_SEC; attempt++) {
        DIR *dir = opendir(sysfs_root);
        if (!dir) {
            perror("opendir");
            return NULL;
        }

        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') {
                continue;
            }

            char vendor_path[PATH_MAX];
            char vendor_val[32];
            FILE *vf;
            if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                         sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) {
                continue;
            }
            vf = fopen(vendor_path, "r");
            if (!vf) {
                continue;
            }
            bool got = fgets(vendor_val, sizeof(vendor_val), vf) != NULL;
            fclose(vf);
            if (!got) {
                continue;
            }
            vendor_val[strcspn(vendor_val, "\n")] = '\0';
            if (strcmp(vendor_val, HSOC_VENDOR_ID) != 0) {
                continue;
            }

            char res_path[PATH_MAX];
            if (snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                         sysfs_root, entry->d_name) >= (int)sizeof(res_path)) {
                continue;
            }
            int fd = open(res_path, O_RDONLY | O_SYNC);
            if (fd < 0) {
                continue;
            }
            void *p = mmap(NULL, CAN_MMAP_SIZE, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) {
                continue;
            }

            uint32_t magic;
            shm_read(&magic, p, sizeof(magic));
            __sync_synchronize();
            if (magic == CAN_IVSHMEM_MAGIC) {
                closedir(dir);
                return (volatile struct can_ivshmem_layout *)p;
            }
            munmap(p, CAN_MMAP_SIZE);
        }
        closedir(dir);

        if (attempt == 0) {
            fprintf(stderr, "[can] waiting for FreeRTOS CAN ivshmem magic...\n");
        }
        sleep(1);
    }
    return NULL;
}

static void *ivshmem_thread(void *arg)
{
    (void)arg;
    volatile struct can_ivshmem_layout *shm = find_can_shm();
    if (!shm) {
        fprintf(stderr, "[can] could not find CAN ivshmem BAR2\n");
        return NULL;
    }
    fprintf(stderr, "[can] ivshmem reader attached\n");

    uint32_t last_gen = 0;
    for (;;) {
        uint32_t gen = shm->generation;
        __sync_synchronize();
        if (gen != last_gen) {
            struct can_ivshmem_frame f;
            shm_read(&f, (const void *)&shm->frame, sizeof(f));
            __sync_synchronize();
            last_gen = gen;
            log_frame("freertos", f.id, f.dlc, f.data);
        }
        usleep(20000); /* 20 ms */
    }
    return NULL;
}

int main(int argc, char *argv[])
{
    const char *ifname = (argc > 1) ? argv[1] : "can0";

    g_log_path = getenv("CHIMERA_CAN_LOG");
    if (!g_log_path) {
        g_log_path = "/var/log/chimera-log/can-bus.log";
    }

    /* Ensure the parent directory exists. */
    {
        char parent[PATH_MAX];
        size_t len = strlen(g_log_path);
        if (len > 0 && len < sizeof(parent)) {
            memcpy(parent, g_log_path, len + 1);
            char *slash = strrchr(parent, '/');
            if (slash && slash != parent) {
                *slash = '\0';
                if (mkdir(parent, 0755) != 0 && errno != EEXIST) {
                    perror(parent);
                    return 1;
                }
            }
        }
    }

    g_log = fopen(g_log_path, "a");
    if (!g_log) {
        perror("fopen log");
        return 1;
    }
    fprintf(stderr, "[can] logging to %s\n", g_log_path);

    pthread_t t_sock, t_shm;
    pthread_create(&t_sock, NULL, socketcan_thread, (void *)ifname);
    pthread_create(&t_shm, NULL, ivshmem_thread, NULL);
    pthread_join(t_sock, NULL);
    pthread_join(t_shm, NULL);

    fclose(g_log);
    return 0;
}
```

- [ ] **Step 2: Build the daemon (verifies headers/threading link)**

```bash
limactl shell qemu-dev -- bash -lc '
  cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase 2>/dev/null || cd /Volumes/Samsung970EVOPlus/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
  make can-log-arm-linux && file can-log-arm-linux
'
```

Expected: builds with no warnings; `file` reports a statically-linked ARM aarch64 executable.

- [ ] **Step 3: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/can_log.c
git commit -m "feat(can): ARM-Linux can-bus.log daemon (socketcan + ivshmem threads)"
```

---

## Task 9: Launch-script plumbing — env vars, ivshmem server, QEMU options

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh`
- Create: `scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`

- [ ] **Step 1: Add env vars to `common.sh`**

In `scripts/heterogeneous-soc/common.sh`, after the stats channel block (after line 86, the `IVSHMEM_STATS_FREERTOS_SOCKET` line) add:

```bash
IVSHMEM_CAN_FREERTOS_DIR="${IVSHMEM_CAN_FREERTOS_DIR:-/tmp/ivshmem-can-freertos}"
IVSHMEM_CAN_FREERTOS_SOCKET="${IVSHMEM_CAN_FREERTOS_SOCKET:-${IVSHMEM_CAN_FREERTOS_DIR}/sock}"
CAN_VCAN_IF="${CAN_VCAN_IF:-vcan0}"
```

After the `LINUX_ARM_STATS_BINARY` line (line 93) add:

```bash
CAN_LOG_ARM_BINARY="${CAN_LOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/can-log-arm-linux}"
```

- [ ] **Step 2: Create the CAN ivshmem-server script**

Create `scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh` (copy of the stats server, retargeted):

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_CAN_FREERTOS_DIR}"

if [[ -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_CAN_FREERTOS_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_CAN_FREERTOS_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_CAN_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -M ivshmem-can-ft \
    -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" \
    -l "${IVSHMEM_SIZE}" \
    -n "${IVSHMEM_VECTORS}" \
    -v
```

Then: `chmod +x scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh`

- [ ] **Step 3: Add CAN + IVSHMEM5 to the FreeRTOS launch**

In `scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh`, replace the `exec` block (lines 10-19) with:

```bash
can_backend=()
if [[ -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" ]]; then
    can_backend=(
        -object can-bus,id=canbus0
        -object "can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0"
        -chardev "socket,id=canft,path=${IVSHMEM_CAN_FREERTOS_SOCKET}"
    )
fi

machine_opts="chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft,ivshmem-bootlog-freertos=bootft"
if [[ ${#can_backend[@]} -gt 0 ]]; then
    machine_opts+=",canbus=canbus0,ivshmem-can-freertos=canft"
fi

exec "${qemu_bin}" \
    -machine "${machine_opts}" \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -chardev socket,id=statsft,path="${IVSHMEM_STATS_FREERTOS_SOCKET}" \
    -chardev socket,id=bootft,path="${IVSHMEM_BOOTLOG_SOCKET}" \
    "${can_backend[@]}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -monitor unix:/tmp/freertos-monitor.sock,server,nowait \
    -nographic
```

> The CAN backend is added only when the CAN ivshmem socket exists, so the machine still boots when CAN is disabled (the `canbus`/`ivshmem-can-freertos` props are opt-in).

- [ ] **Step 4: Add CAN + `kvaser_pci` + IVSHMEM5 to the ARM-Linux launch**

In `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`, insert before the `exec` (after line 14, `bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"`):

```bash
can_args=()
if [[ -S "${IVSHMEM_CAN_FREERTOS_SOCKET}" ]]; then
    can_args=(
        -object can-bus,id=canbus0
        -object "can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0"
        -device kvaser_pci,canbus=canbus0
        -chardev "socket,id=ivshmem_can,path=${IVSHMEM_CAN_FREERTOS_SOCKET}"
        -device "ivshmem-doorbell,chardev=ivshmem_can,vectors=${IVSHMEM_VECTORS}"
    )
fi
```

Then add `"${can_args[@]}"` to the `exec "${qemu_bin}" ...` argument list — insert it right after the `-device ivshmem-doorbell,chardev=ivshmem_boot,vectors=1 \` line (line 28):

```bash
    "${can_args[@]}" \
```

- [ ] **Step 5: Syntax-check all four scripts**

```bash
bash -n scripts/heterogeneous-soc/common.sh \
        scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh \
        scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh \
        scripts/heterogeneous-soc/guest-run-arm-phase5.sh && echo SYNTAX_OK
```

Expected: prints `SYNTAX_OK`.

- [ ] **Step 6: Commit**

```bash
git add scripts/heterogeneous-soc/common.sh \
        scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh \
        scripts/heterogeneous-soc/guest-run-r52-freertos-phase5.sh \
        scripts/heterogeneous-soc/guest-run-arm-phase5.sh
git commit -m "feat(can): add CAN bus + IVSHMEM5 to FreeRTOS/ARM launch scripts"
```

---

## Task 10: Showcase orchestration — vcan0, server, daemon, can0

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`
- Modify: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh`

- [ ] **Step 1: Install the daemon into the ARM qcow2**

In `scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh`, after the existing ARM inject (line 75) add:

```bash
inject_binary "${ARM_DEBIAN_DISK}"   "${CAN_LOG_ARM_BINARY}"  "can-log-arm-linux"
```

- [ ] **Step 2: Ensure `vcan0` exists + start the CAN ivshmem-server in the showcase**

In `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh`, add the server to the startup list (after the bootlog server line, line 74):

```bash
    "${SCRIPT_DIR}/guest-start-ivshmem-server-can-freertos.sh"
```

Add a `vcan0` bring-up + `CAP_NET_RAW` grant near the top of the run sequence — right before the ivshmem-servers are launched. Insert after the existing pkill block (after line 92, the `pkill -x "ivshmem-server"` line):

```bash
# ── CAN bus: ensure Lima has a vcan0 the QEMU processes can share ────────────
if ! ip link show "${CAN_VCAN_IF:-vcan0}" >/dev/null 2>&1; then
    sudo modprobe vcan 2>/dev/null || true
    sudo ip link add dev "${CAN_VCAN_IF:-vcan0}" type vcan 2>/dev/null || true
fi
sudo ip link set "${CAN_VCAN_IF:-vcan0}" up 2>/dev/null || true

# can-host-socketcan needs CAP_NET_RAW to bind the AF_CAN socket. Grant it to
# the QEMU binaries (no-op if already set / if setcap unavailable).
for _qb in "${BUILD_DIR}/qemu-system-arm" "${BUILD_DIR}/qemu-system-aarch64"; do
    [[ -x "${_qb}" ]] && sudo setcap cap_net_raw+eip "${_qb}" 2>/dev/null || true
done
```

Also add a `pkill` for the CAN server name to the stale-process cleanup (after line 92):

```bash
_exec pkill -f "ivshmem-can-ft"                            2>/dev/null || true
```

- [ ] **Step 3: Bring up `can0` and launch the daemon in the ARM pane**

In `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`, start the CAN ivshmem-server so the standalone tmux path (run without `guest-run-chimera-showcase.sh`) also has the channel. It has no dedicated pane, so launch it in the background. Add this single line immediately after the bootlog server send-keys (line 83):

```bash
( cd "$REPO" && scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh >/dev/null 2>&1 & )
```

Extend the ARM-pane auto-run command list (lines 205-209) to bring up `can0` and launch the daemon. Change:

```bash
auto_login_and_run "$SESSION:0.6" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "syslog-arm-linux &" \
    "bootlog-arm-linux &" \
    "boot-collector" &
```

to:

```bash
auto_login_and_run "$SESSION:0.6" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "syslog-arm-linux &" \
    "bootlog-arm-linux &" \
    "ip link set can0 type can bitrate 500000 2>/dev/null; ip link set can0 up 2>/dev/null" \
    "can-log-arm-linux &" \
    "boot-collector" &
```

> `kvaser_pci` presents a SocketCAN `can0` netdev in the ARM guest. `ip link set can0 ... up` is required before `candump`/the daemon can read it. The `2>/dev/null` keeps the pane clean if CAN was launched disabled.

- [ ] **Step 4: Syntax-check the three scripts**

```bash
bash -n scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh \
        scripts/heterogeneous-soc/guest-run-phase5-tmux.sh \
        scripts/heterogeneous-soc/guest-run-chimera-showcase.sh && echo SYNTAX_OK
```

Expected: prints `SYNTAX_OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-install-syslog-to-guests.sh \
        scripts/heterogeneous-soc/guest-run-phase5-tmux.sh \
        scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
git commit -m "feat(can): orchestrate vcan0, CAN server, can0 + daemon in showcase"
```

---

## Task 11: Headless CAN harness + end-to-end verification + docs

**Files:**
- Create: `scripts/heterogeneous-soc/guest-run-can-harness.sh`
- Modify: `README.md`, `CLAUDE.md`

- [ ] **Step 1: Write the harness**

Create `scripts/heterogeneous-soc/guest-run-can-harness.sh`. It brings up `vcan0`, starts the CAN ivshmem-server and the FreeRTOS guest (capturing serial), sends a frame from Lima, and asserts the FreeRTOS UART `CAN RX:` line. Pass/fail per the repo's autonomous-debug-loop convention.

```bash
#!/usr/bin/env bash
# guest-run-can-harness.sh — headless pass/fail test for CAN RX on FreeRTOS.
# PASS when FreeRTOS prints the decoded frame from a Lima `cansend`.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

CAN_TEST_ID="${CAN_TEST_ID:-123}"
CAN_TEST_DATA="${CAN_TEST_DATA:-DEADBEEF}"
SERIAL_LOG="${SERIAL_LOG:-/tmp/can-harness-freertos.log}"
TIMEOUT="${CAN_HARNESS_TIMEOUT:-60}"

cleanup() {
    pkill -f "qemu-system-arm.*chimera-r52-freertos-demo" 2>/dev/null || true
    pkill -f "ivshmem-can-ft" 2>/dev/null || true
}
trap cleanup EXIT
cleanup
rm -f "${SERIAL_LOG}" "${IVSHMEM_CAN_FREERTOS_SOCKET}"

# vcan0 + CAP_NET_RAW
sudo modprobe vcan 2>/dev/null || true
ip link show "${CAN_VCAN_IF}" >/dev/null 2>&1 || \
    sudo ip link add dev "${CAN_VCAN_IF}" type vcan
sudo ip link set "${CAN_VCAN_IF}" up
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"
sudo setcap cap_net_raw+eip "${qemu_bin}" 2>/dev/null || true

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"

# CAN ivshmem-server
bash "${SCRIPT_DIR}/guest-start-ivshmem-server-can-freertos.sh" >/dev/null 2>&1 &
sleep 1

# Launch FreeRTOS, serial -> file
"${qemu_bin}" \
    -machine "chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,canbus=canbus0,ivshmem-can-freertos=canft" \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -object can-bus,id=canbus0 \
    -object "can-host-socketcan,id=ch0,if=${CAN_VCAN_IF},canbus=canbus0" \
    -chardev socket,id=canft,path="${IVSHMEM_CAN_FREERTOS_SOCKET}" \
    -kernel "${FREERTOS_DEMO_ELF}" \
    -serial file:"${SERIAL_LOG}" -nographic &
sleep 5

# Send the frame and wait for the decoded line.
cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}"

want="CAN RX: id=0x${CAN_TEST_ID}"
elapsed=0
while (( elapsed < TIMEOUT )); do
    if grep -qi "${want}" "${SERIAL_LOG}" 2>/dev/null; then
        echo "PASS: FreeRTOS received CAN frame:"
        grep -i "CAN RX:" "${SERIAL_LOG}" | tail -1
        exit 0
    fi
    cansend "${CAN_VCAN_IF}" "${CAN_TEST_ID}#${CAN_TEST_DATA}" 2>/dev/null || true
    sleep 2; (( elapsed += 2 ))
done

echo "FAIL: no 'CAN RX:' line within ${TIMEOUT}s. Serial tail:"
tail -20 "${SERIAL_LOG}" 2>/dev/null || true
exit 1
```

Then: `chmod +x scripts/heterogeneous-soc/guest-run-can-harness.sh`

- [ ] **Step 2: Run the harness on Lima**

```bash
limactl shell qemu-dev -- bash -lc '
  cd ~/chimera-src 2>/dev/null || cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
  bash scripts/heterogeneous-soc/guest-run-can-harness.sh
'
```

Expected: prints `PASS:` followed by `CAN RX: id=0x123 dlc=4 data=de ad be ef`. If it fails, follow the autonomous-debug-loop in `CLAUDE.md` (diagnose from `/tmp/can-harness-freertos.log`, fix, re-run until 3 consecutive passes).

- [ ] **Step 3: Full end-to-end check via the showcase (manual acceptance, spec §Testing)**

```bash
# On macOS host:
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
# In another terminal, once guests are up:
limactl shell qemu-dev -- cansend vcan0 123#DEADBEEF
# ARM guest receives on can0:
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'timeout 3 candump -n1 can0'
# Both sources land in the log:
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'tail -5 /var/log/chimera-log/can-bus.log'
```

Expected: `candump` shows `can0  123   [4]  DE AD BE EF`; `can-bus.log` contains both a `CAN/socketcan id=0x123 ...` and a `CAN/freertos id=0x123 dlc=4 data=de ad be ef` line; the FreeRTOS tmux pane (`freertos-showcase:0.5`) shows `CAN RX: id=0x123 dlc=4 data=de ad be ef`.

- [ ] **Step 4: Update the ivshmem channel map in the docs**

In `README.md`, find the **ivshmem channel map** table and add the IVSHMEM5 row + CAN controller note (search for `IVSHMEM4`):

```markdown
| IVSHMEM5 | 0x49000000 | 0x4A000000 (64 KiB) | 7 | CAN frames FreeRTOS → ARM-Linux |

CAN controller: `xlnx-zynqmp-can` @ `0x50000000`, GIC SPI 6 (INTID 38). ARM-Linux uses `kvaser_pci` → `can0`. Both QEMU processes share Lima's `vcan0` via `can-host-socketcan`. ARM-Linux daemon `can-log-arm-linux` tails both sources to `/var/log/chimera-log/can-bus.log`.
```

In `CLAUDE.md`, update the **What This Repo Is** paragraph to mention the CAN path (append one sentence after the stats-channel sentence):

```markdown
A CAN bus (`xlnx-zynqmp-can` on FreeRTOS, `kvaser_pci` on ARM-Linux, both bridged to Lima's `vcan0`) lets a host `cansend` reach both guests; FreeRTOS forwards received frames over IVSHMEM5 to an ARM-Linux daemon that logs them to `/var/log/chimera-log/can-bus.log`.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-can-harness.sh README.md CLAUDE.md
git commit -m "test(can): add headless CAN harness; document IVSHMEM5 + CAN bus"
```

---

## Final Verification Checklist

- [ ] `make -C contrib/heterogeneous-soc/freertos-showcase check` → `test_can_decode: OK`
- [ ] `ninja -C "$BUILD_DIR" qemu-system-arm qemu-system-aarch64` builds clean
- [ ] `qemu-system-arm -device help | grep xlnx.zynqmp-can` and `qemu-system-aarch64 -device help | grep kvaser_pci` both match
- [ ] `qemu-system-arm -machine chimera-r52-freertos-demo,help` lists `canbus` + `ivshmem-can-freertos`
- [ ] `make -C contrib/heterogeneous-soc/freertos-showcase` builds `freertos-r52-demo.elf` and `can-log-arm-linux`
- [ ] `guest-run-can-harness.sh` → `PASS` (3 consecutive runs per the autonomous-debug-loop)
- [ ] Showcase: `cansend vcan0 123#DEADBEEF` → `candump can0` shows the frame, FreeRTOS pane prints `CAN RX: id=0x123 dlc=4 data=de ad be ef`, and `can-bus.log` has both `CAN/socketcan` and `CAN/freertos` lines
- [ ] Existing demo still works: timer tick fires (FreeRTOS uptime advances), all three syslog channels still receive HELLO/ACK (the `GIC_NUM_IRQ` bump did not disturb the tick PPI)
