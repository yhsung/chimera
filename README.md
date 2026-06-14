# Chimera — QEMU Fork for Heterogeneous SoC

This repository is a fork of [QEMU](https://www.qemu.org/) that adds a
custom machine model and ivshmem device for the Chimera heterogeneous SoC
demo, which is now maintained in its own repository:

→ **[chimera-2](https://github.com/yhsung/chimera-2)** — the heterogeneous SoC demo (Apache-2.0)

This repository (chimera) is consumed as chimera-2's `qemu/` git submodule.

---

## Chimera Fork Additions

All custom code lives in a small surface area on top of upstream QEMU:

| File | Purpose |
|---|---|
| `hw/arm/chimera_r52_freertos_demo.c` | Custom `chimera-r52-freertos-demo` QEMU machine: one Cortex-R52 core, GICv2, pl011 UART, six `ivshmem-flat` devices (3 HELLO/ACK + 1 stats + 1 boot-log + 1 CAN) |
| `include/hw/arm/chimera_r52_freertos_demo.h` | Machine state, memory map enum, IRQ numbers |
| `hw/misc/ivshmem-flat.c` | `ivshmem-flat` sysbus device — memory-mapped ivshmem without PCI, connects to ivshmem-server via Unix socket |
| `include/hw/misc/ivshmem-flat.h` | Device state and interface |

The `ivshmem-flat` device is a sysbus alternative to the PCI `ivshmem-doorbell`; FreeRTOS uses it because bare-metal targets lack a PCI bus. Linux guests use the standard PCI `ivshmem-doorbell`.

`CONFIG_CHIMERA_FREERTOS_DEMO` (`hw/riscv/Kconfig`) selects `CONFIG_IVSHMEM_FLAT_DEVICE` (`hw/misc/Kconfig`) automatically. Both are `default y` for their respective targets.

### ivshmem Device Types

- **Linux guests** use `ivshmem-doorbell` (PCI device, BAR2 = 64 MiB shared memory window)
- **FreeRTOS** uses `ivshmem-flat` (custom sysbus device, memory-mapped at fixed addresses)

### FreeRTOS DRAM Configuration

The `chimera-r52-freertos-demo` machine is configured with the following DRAM layout (`hw/arm/chimera_r52_freertos_demo.c`):

| Property | Value | Source |
|---|---|---|
| `mc->default_ram_size` | `128 * MiB` (128 MiB) | `hw/arm/chimera_r52_freertos_demo.c:320` |
| `mc->default_ram_id` | `"arm.chimera.r52.freertos.ram"` | `hw/arm/chimera_r52_freertos_demo.c:319` |
| RAM base address | `0x80000000` | `hw/arm/chimera_r52_freertos_demo.c:29` (`CHIMERA_FREERTOS_RAM` memmap entry) |
| RAM region size (memmap) | `0x08000000` (128 MiB) | `hw/arm/chimera_r52_freertos_demo.c:29` |

The RAM is added to the system memory map via `memory_region_add_subregion()` using the memmap's `base` (0x80000000) and `machine->ram` (sized by `default_ram_size`).

The custom QEMU machine (`hw/arm/chimera_r52_freertos_demo.c`) connects FreeRTOS to all six ivshmem servers simultaneously:

| Link | MMIO base | SHMEM base | Vectors | Direction |
|---|---|---|---|---|
| ARM ↔ FreeRTOS | `0x30000000` | `0x31000000` | 4 | bidirectional (HELLO/ACK) |
| RISCV ↔ FreeRTOS | `0x35000000` | `0x36000000` | 4 | bidirectional (HELLO/ACK) |
| MIPS ↔ FreeRTOS | `0x3A000000` | `0x3B000000` | 4 | bidirectional (HELLO/ACK) |
| Stats FreeRTOS→ARM | `0x3F000000` | `0x40000000` | 4 | FreeRTOS write only (stats snapshot) |
| Boot-log (all guests → ARM) | `0x44000000` | `0x45000000` | 1 | All 4 guests → ARM collector |
| IVSHMEM5 CAN FreeRTOS→ARM | `0x49000000` | `0x4A000000` (64 KiB) | 4 | FreeRTOS write only (decoded CAN frame) |

---

## Implementation Notes

### Volatile byte helpers

All copies to/from ivshmem use explicit volatile byte loops instead of `memcpy`/struct assignment:

- **ARM-Linux**: ARM `printf`/`memcpy` use NEON instructions, which SIGBUS on non-cacheable PCI BAR2 memory.
- **FreeRTOS**: GCC `-O2` loop-invariant code motion (LICM) hoists non-volatile struct reads out of the poll loop.

### Memory barriers

`__sync_synchronize()` is placed around every flag write and read:
- RISCV: emits `fence iorw,iorw`
- AArch64: emits `dmb ish`

This ensures message body writes are globally visible before the flag is set, and that the flag read completes before the message body is read.

### FreeRTOS Exception Handlers

`contrib/heterogeneous-soc/freertos-showcase/startup.S` (now in chimera-2) defines the ARM exception vector table. When adding new MMIO peripherals to the QEMU machine model, ensure addresses are always mapped in `hw/arm/chimera_r52_freertos_demo.c` OR verify the data-abort handler tolerates faults on those regions.

### Naming: mipsel, not mips

The QEMU target for MIPS little-endian is `mipsel-softmmu`, producing `qemu-system-mipsel`. Build artifacts, binaries, and `pkill` patterns must use `mipsel` (not `mips`).

### Naming: r52 (FreeRTOS's CPU) vs. the RISCV-Linux channel

The bare-metal FreeRTOS guest runs on a Cortex-R52 (`qemu-system-arm`, machine `chimera-r52-freertos-demo`, binary `freertos-r52-demo.elf`). The disambiguating prefix for FreeRTOS's own architecture is **`r52`** (not `arm`, which is the Cortex-A53 ARM-Linux guest).

---

## Licensing

This repository is a QEMU fork licensed under **GPL-2.0-or-later**. See the
top-level `LICENSE` and `COPYING`.

For the full heterogeneous SoC demo — including FreeRTOS firmware, Linux
guest daemons, and all build/launch/CI scripts — see
[chimera-2](https://github.com/yhsung/chimera-2), which is licensed under
**Apache-2.0**.

## Design Rationale

Historical design documents and implementation plans for both the QEMU
machine model and the heterogeneous SoC demo are preserved in
[`docs/superpowers/`](docs/superpowers/).

## Building QEMU

See the [upstream QEMU build documentation](https://www.qemu.org/docs/master/system/build.html).

To build with the Chimera machine model configured:

```bash
./configure --target-list=aarch64-softmmu,arm-softmmu,riscv64-softmmu,mipsel-softmmu --enable-debug
ninja qemu-system-aarch64 qemu-system-arm qemu-system-riscv64 qemu-system-mipsel
```
