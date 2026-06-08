# Cortex-R52 FreeRTOS Migration — Design

**Date:** 2026-06-08
**Status:** Approved for planning

## Goal

Replace the bare-metal FreeRTOS guest's CPU architecture from RV64 to Arm
**Cortex-R52**, in place. The guest keeps its existing role in the demo
(receives HELLO from all three Linux guests over `ivshmem-flat`, sends ACK,
and pushes a stats snapshot every 5s) — only the underlying CPU, QEMU
machine, and bare-metal toolchain change. This is a single-core port (no
SMP/dual-core), motivated by wanting the demo's "heterogeneous SoC" story to
be backed by a real automotive/safety-class ARM core rather than a generic
RV64 hart.

## Naming convention

The disambiguating prefix for FreeRTOS's *own* architecture is **`r52`**
(not `arm`, which is already used by the Cortex-A53 ARM-Linux guest). This
prefix applies only to identifiers that name FreeRTOS's CPU/machine/binary —
**not** to the RISCV-Linux↔FreeRTOS ivshmem channel, whose names
(`IVSHMEM_RISCV_FREERTOS_*`, `riscv_link`/`riscv_count`,
`guest-start-ivshmem-server-riscv-freertos.sh`, `syslog-riscv-linux`, etc.)
describe the **RISCV-Linux guest's channel** and are independent of what CPU
FreeRTOS itself runs on. These stay untouched.

## 1. QEMU machine

A new file `hw/arm/chimera_r52_freertos_demo.c` (+ header
`include/hw/arm/chimera_r52_freertos_demo.h`), registered as machine type
`chimera-r52-freertos-demo`, modeled closely on the existing
`hw/riscv/chimera_freertos_demo.c` (371 lines — small and purpose-built):

- **CPU**: single `cortex-r52` core (`ARM_CPU_TYPE_NAME("cortex-r52")`),
  reset vector pointing at a small mask ROM, mirroring the existing
  machine's reset setup.
- **Interrupt controller**: a GIC instance feeding the 5 `ivshmem-flat` IRQ
  lines plus the UART IRQ. *(Open question — see Risks.)*
- **UART**: a memory-mapped `pl011`, matching what the ARM-Linux `virt`
  machine already uses, for console/log output.
- **Timer**: ARM generic/system timer driving the FreeRTOS tick.
- **Memory map**: a flat single RAM region (origin/size sized to fit the
  firmware plus the ivshmem MMIO/SHMEM windows), mirroring the existing
  demo's simple layout rather than AN536's multi-region ATCM/BTCM/DDR split.
- **ivshmem wiring**: the same `chimera_freertos_connect_ivshmem()`-style
  helper, realizing 5 `TYPE_IVSHMEM_FLAT` devices (3 HELLO/ACK + 1 stats + 1
  boot-log) with IRQs connected to the GIC instead of the PLIC.
- **Kconfig**: new `CONFIG_CHIMERA_R52_FREERTOS_DEMO` in `hw/arm/Kconfig`,
  `select CONFIG_IVSHMEM_FLAT_DEVICE`; `hw/riscv/Kconfig` loses
  `CONFIG_CHIMERA_FREERTOS_DEMO` and its `select`.
- **Binary**: launches via `qemu-system-arm` — Cortex-R52 implements
  Armv8-R **AArch32 only** (no 64-bit mode), unlike the RV64 machine which
  used `qemu-system-riscv64`.

We use `hw/arm/mps3r.c` (the existing in-tree `mps3-an536` dual Cortex-R52
machine) purely as an implementation reference for CPU/GIC realization
patterns — we do not extend or modify it. A dedicated, minimal machine keeps
the project's established "one small focused machine per guest type"
pattern and avoids dragging in AN536 peripherals (I2C, SPI, RTC, watchdog,
SCC, dual-core wiring) that don't serve this demo.

## 2. FreeRTOS port, toolchain, and firmware code

- **Toolchain**: swap `gcc-riscv64-unknown-elf`/`binutils-riscv64-unknown-elf`
  for `gcc-arm-none-eabi`/`binutils-arm-none-eabi` in
  `guest-install-lima-guest.sh` and the `_pkg_check` calls in
  `guest-run-chimera-showcase.sh` (confirmed nothing besides the FreeRTOS
  Makefile uses the bare-metal RISC-V toolchain, so this is a swap, not an
  addition). Makefile: `CROSS_COMPILE ?= arm-none-eabi-`,
  `CFLAGS_BARE` retargeted to `-mcpu=cortex-r52` plus whatever FPU/mode
  flags the chosen port needs.
- **FreeRTOS port**: switch `FREERTOS_PORT_DIR` from `portable/GCC/RISC-V`
  to whichever Cortex-R port the pre-implementation spike selects from
  `ARM_CR5`, `ARM_CRx_MPU`, or `ARM_CRx_No_GIC` (all present in the cloned
  `FreeRTOS-Kernel`); drop the RISC-V `chip_specific_extensions` include.
- **`startup.S`**: rewritten in ARM assembly — exception vector table
  (Reset/Undef/SVC/Prefetch Abort/Data Abort/IRQ/FIQ), per-mode stack setup,
  BSS clear, branch to `main`. Replaces the RISC-V `mtvec`/trap-handler
  wiring with the chosen port's expected handler symbols (e.g. an
  `FreeRTOS_IRQ_Handler`-style entry instead of
  `freertos_risc_v_trap_handler`).
- **`linker.ld`**: new `MEMORY`/`SECTIONS` matching the new QEMU machine's
  RAM base/size; `KEEP()` rules updated to the new port's handler symbol
  names.
- **`FreeRTOSConfig.h`**: swap RISC-V tick/interrupt config
  (`configMTIME_BASE_ADDRESS`, etc.) for the Cortex-R equivalents
  (`configINTERRUPT_CONTROLLER_BASE_ADDRESS`, `configSETUP_TICK_INTERRUPT()`,
  etc.).
- **Identity strings only**: rename `HSOC_SENDER_RISCV_FREERTOS` →
  `HSOC_SENDER_R52_FREERTOS` (the wire-protocol numeric value **stays `3`**
  — only the C identifier changes) and the ACK payload string
  `"ack from riscv-freertos"` → `"ack from r52-freertos"` in
  `freertos_ivshmem_flat.c`. All `riscv_link`/`riscv_count`/
  `IVSHMEM_RISCV_FREERTOS_*` references are the RISCV-Linux channel and are
  **not** touched.

## 3. Build scripts, launch scripts, and naming sweep

| Old | New |
|---|---|
| `hw/riscv/chimera_freertos_demo.c` (+ `.h`) | `hw/arm/chimera_r52_freertos_demo.c` (+ `.h`) |
| machine `chimera-riscv-freertos-demo` | `chimera-r52-freertos-demo` |
| `freertos-riscv-demo.elf` / `FREERTOS_DEMO_ELF` | `freertos-r52-demo.elf` |
| `guest-run-riscv-freertos-phase5.sh` | `guest-run-r52-freertos-phase5.sh` |
| `CROSS_COMPILE = riscv64-unknown-elf-` | `arm-none-eabi-` |
| pkg `gcc/binutils-riscv64-unknown-elf` | `gcc/binutils-arm-none-eabi` |
| `qemu-system-riscv64` (FreeRTOS launch script only) | `qemu-system-arm` |
| `HSOC_SENDER_RISCV_FREERTOS` | `HSOC_SENDER_R52_FREERTOS` (value unchanged: `3`) |

**Untouched** — names the RISCV-**Linux** guest's channel, independent of
FreeRTOS's CPU: `IVSHMEM_RISCV_FREERTOS_DIR/SOCKET`,
`ivshmem-riscv-freertos=...` chardev id, `riscv_link`/`riscv_count`,
`guest-start-ivshmem-server-riscv-freertos.sh`, `syslog-riscv-linux`,
`bootlog-riscv-linux`.

Other mechanical updates: `guest-build-freertos-showcase.sh` and
`guest-run-chimera-showcase.sh` (`_pkg_check` lines, tmux pane labels)
updated to the new binary/machine names.

## 4. Testing and validation plan

Incremental bring-up, mirroring how you'd validate new bare-metal silicon:

1. **Standalone boot**: launch `chimera-r52-freertos-demo` alone with
   `-nographic`; confirm the FreeRTOS banner and UART log lines appear
   (proves CPU + GIC + UART + tick all function). Retarget
   `guest-run-freertos-harness.sh`'s pass condition accordingly.
2. **Single-channel ivshmem**: bring up one Linux guest (e.g. ARM-Linux)
   plus the new FreeRTOS guest; confirm a HELLO/ACK round-trip on that one
   channel. Isolates `ivshmem-flat` + GIC IRQ wiring from the other four
   channels.
3. **Full showcase**: run `guest-run-chimera-showcase.sh` end-to-end with
   all three Linux guests plus the stats and boot-log channels; confirm
   `/var/log/chimera-log/chimera-cross-domain.log` shows `r52` sender
   entries and existing harnesses pass.

## 5. Documentation updates

- `README.md`: architecture table (CPU type, machine name), Chimera-Specific
  Code file table, wire-protocol sender-ID label, Building
  QEMU/FreeRTOS sections (toolchain, paths).
- `contrib/heterogeneous-soc/freertos-showcase/README.md`: cross-compiler
  line.
- `CLAUDE.md`: add a short note to the Naming section (alongside the
  existing "mipsel, not mips" guidance) clarifying `r52` (FreeRTOS's own
  arch) vs. the RISCV-Linux channel naming, so future agents don't conflate
  the two.

## Risks / open questions (to resolve via a short spike before full implementation)

- **GIC version / FreeRTOS port pairing**: `ARM_CR5` expects a
  memory-mapped GICv2-style CPU interface; `mps3-an536` instantiates a
  GICv3. Which GIC version the new machine should expose — and which of
  `ARM_CR5` / `ARM_CRx_MPU` / `ARM_CRx_No_GIC` pairs with it — needs a quick
  spike (e.g. booting a minimal "blink UART" image) before the full firmware
  port is attempted.
- **Compiler flags**: exact `-mcpu`/`-mfpu`/mode flags for `cortex-r52`
  under `arm-none-eabi-gcc` depend on the chosen port's expectations
  (e.g. VFP availability, ARM vs Thumb).
