# FreeRTOS Interactive Shell Design

**Date:** 2026-06-13
**Status:** Draft

## Goal

Add an interactive UART command shell to the bare-metal FreeRTOS (Cortex-R52)
firmware for live debugging and diagnostics: inspect HELLO/ACK counters,
per-guest cpu/mem stats, link state, heap/stack/uptime, CAN controller
status, and adjust the runtime log verbosity — all without rebuilding or
restarting the demo.

UART0 (PL011) is currently TX-only (`uart_putc`); `-nographic` connects it
bidirectionally to the FreeRTOS tmux pane's stdio, so a human can already
type into it — the firmware just never reads `UARTDR`. This design adds RX
support and a small interactive shell on top of it.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ vApplicationIRQHandler (GICv2 dispatch)                          │
│                                                                   │
│   INTID 32 (UART, SPI0) ──► uart_rx_isr()                        │
│     - drains UARTDR while !(UARTFR & RXFE)                       │
│     - xQueueSendFromISR(uart_rx_queue, &byte)                    │
└─────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│ shell_task (new FreeRTOS task, priority tskIDLE_PRIORITY+1)      │
│                                                                   │
│   xQueueReceive(uart_rx_queue, &c, portMAX_DELAY)                │
│   - line editing (echo, backspace/DEL, CR/LF)                    │
│   - tokenize -> argv[]                                           │
│   - dispatch via shell_cmd_table[]                               │
│   - reads state through struct chimera_shell_ctx                 │
└─────────────────────────────────────────────────────────────────┘
                       ▲
                       │ (pointers, populated once at init)
┌─────────────────────────────────────────────────────────────────┐
│ showcase_task (existing, unchanged 10ms loop)                    │
│   - arm/riscv/mips counts, cpu/mem pct, link state, last-hello   │
│   - showcase_task handle                                         │
└─────────────────────────────────────────────────────────────────┘
```

The shell task is fully decoupled from the existing 10ms `showcase_task`
loop: it blocks on a queue fed by the UART RX ISR, so typing has zero impact
on HELLO/ACK/stats/CAN timing, and a slow command handler can't stall ivshmem
servicing.

### UART RX mechanism (PL011, GIC SPI0 / INTID 32)

QEMU's `pl011_can_receive()` ignores `UARTCR` enable bits entirely (RX works
without touching `UARTCR`). `uart_init_rx()`:

1. `UARTIMSC |= INT_RX` (offset `0x38`, bit `0x10`) — enables only the RX
   interrupt source, so TX-complete events don't spuriously assert the
   combined IRQ line.
2. Enables GIC SPI32: `IPRIORITYR[32]=0xA0`, `ITARGETSR[32]=0x01`,
   `ISENABLER[1] |= (1<<0)` — same pattern as `gic_enable_ivshmem_spi()`, but
   **no `ICFGR` write**. Unlike the ivshmem doorbell SPIs (edge-configured
   because `qemu_irq_pulse()` is momentary), PL011's combined IRQ is a
   sustained level (`pl011_update()` calls `qemu_set_irq(level)`), and GIC
   SPIs default to level-sensitive — exactly what's needed here.

`uart_rx_isr()` drains `UARTDR` while `!(UARTFR & RXFE)`, pushing each byte
via `xQueueSendFromISR()` into `uart_rx_queue`. Reading `UARTDR` to empty
auto-clears `UARTRIS.RX` in the PL011 model, so the level line de-asserts
before ISR return — no explicit `UARTICR` write needed, no IRQ storm risk.

## Component Changes

### 1. New: `uart_driver.c` / `uart_driver.h`

Becomes the single PL011 driver (TX *and* RX). Absorbs the existing
`uart_putc()` and `UART0_BASE`/`PL011_DR`/`PL011_FR`/`PL011_FR_TXFF`
definitions out of `freertos_main.c` (currently `static`). Adds:

```c
void uart_init_rx(void);   /* enable UARTIMSC.RX + GIC SPI32 */
void uart_rx_isr(void);    /* called from vApplicationIRQHandler, INTID 32 */
void uart_putc(char ch);   /* moved from freertos_main.c, now exported */

extern QueueHandle_t uart_rx_queue;  /* created by uart_init_rx() */
```

### 2. New: `shell.c` / `shell.h`

```c
struct chimera_shell_guest {
    const char *name;
    const struct freertos_ivshmem_link *link;
    const uint32_t *hello_count;
    const uint32_t *cpu_pct_x100;
    const uint32_t *mem_pct_x100;
    const TickType_t *last_hello_ticks;
};

struct chimera_shell_ctx {
    struct chimera_shell_guest guests[3];  /* arm, riscv, mips */
    TaskHandle_t showcase_task_handle;
};

void shell_init(const struct chimera_shell_ctx *ctx);
```

`shell_init()` calls `uart_init_rx()` and
`xTaskCreate(shell_task, "shell", 1024, ctx, tskIDLE_PRIORITY+1, NULL)`.
`ctx` points at a `static struct chimera_shell_ctx g_shell_ctx` in
`freertos_main.c`, so its lifetime covers the task's lifetime. The 1024-word
(4KB) stack estimate is validated against `uxTaskGetStackHighWaterMark()`
during testing (see Testing).

**Line editing** (`shell_task`, static `char line[81]` + length counter, per
received byte):

- **Printable (0x20–0x7E)**: if `len < 80`, append + echo; otherwise drop
  silently (line-too-long — stops growing until Enter/backspace).
- **Backspace (0x08) or DEL (0x7F)**: if `len > 0`, decrement and echo
  `"\b \b"` to erase the character on the terminal.
- **CR (0x0D) or LF (0x0A)**: echo `"\r\n"`, NUL-terminate `line`, dispatch,
  reprint the prompt (`"chimera> "`). A `\r\n`/`\n\r` pair is treated as
  *one* terminator (swallow-the-pair: remember the last terminator byte and
  ignore an immediate matching partner), so pressing Enter doesn't produce a
  spurious empty command.
- Other control bytes: ignored.

**Tokenizing & dispatch**: an in-place tokenizer splits `line` on spaces into
`argv[]` (max 4 tokens, `argc` count) by writing `'\0'` at each space run —
no `strtok` needed. An empty line (`argc == 0`) just reprints the prompt.
Otherwise, linear-search
`static const struct shell_cmd { const char *name; void (*fn)(const struct chimera_shell_ctx *, int argc, char **argv); const char *help; }`
comparing `argv[0]` against `name`. Unknown command →
`"unknown command: <name> (try 'help')\n"`.

`freertos_libc.c` only provides `memcpy/memmove/memset/memcmp/strcpy/strlen`
— no `strcmp`/`atoi`/`strtol`. `shell.c` adds two small local helpers (not
added to `freertos_libc.c`, shell-specific):

- `str_eq(a, b)` — exact string match.
- `parse_uint(s)` — decimal string → `uint32_t`, used by `loglevel <N>`.

### 3. `freertos_main.c`

- Remove the relocated `uart_putc`/PL011 TX defines (now in
  `uart_driver.c`); `#include "uart_driver.h"`.
- Add `volatile uint32_t g_freertos_log_level = FREERTOS_LOG_LEVEL;` and
  change `log_uart()`'s guard from `level < FREERTOS_LOG_LEVEL` to
  `level < g_freertos_log_level`, making verbosity runtime-adjustable via the
  `loglevel` command.
- Add `R52_UART_INTID 32` and a `vApplicationIRQHandler` branch calling
  `uart_rx_isr()`.
- `main()` captures `showcase_task`'s handle into a new file-static
  `TaskHandle_t g_showcase_task_handle` via `xTaskCreate`'s `pxCreatedTask`
  out-param (currently passed as `0`/discarded).
- After the existing IVSHMEM/CAN init block in `showcase_task`, populate
  `static struct chimera_shell_ctx g_shell_ctx` (guest name/link/count/pct/
  last-hello pointers + `g_showcase_task_handle`) and call
  `shell_init(&g_shell_ctx)`.

### 4. `can_driver.c` / `.h`

Add a status accessor (currently `can_regs`/`can_ivshmem` are file-static
with no external visibility):

```c
struct can_status {
    uint32_t sr;        /* CAN_REG_SR (StatusRegister) */
    uint32_t rx_frames; /* can_ivshmem->generation (frames forwarded) */
};
void can_get_status(struct can_status *out);
```

### 5. `Makefile`

Add `uart_driver.c shell.c` (+ their headers) to `freertos-r52-demo.elf`'s
prerequisites and build command.

### 6. Documentation

`contrib/heterogeneous-soc/freertos-showcase/README.md` and the main
`README.md` Chimera-Specific Code table: add rows for `uart_driver.c/.h` and
`shell.c/.h`, plus a short "Interactive Shell" subsection documenting the
command set and how to attach via tmux.

## Command Set

| Command | Output |
|---|---|
| `help` | One line per command: `name - help text` |
| `stats` | Per guest (arm/riscv/mips): `<name>: hello=<count> cpu=<x.xx>% mem=<x.xx>%` (formatting `cpu_pct_x100`/`mem_pct_x100` as integer+fraction, matching the existing `utoa_dec`-style helpers) |
| `sysinfo` | `heap_free=<bytes> uptime_s=<n> shell_stack_hiwat=<words> showcase_stack_hiwat=<words>` via `xPortGetFreeHeapSize()`, `xTaskGetTickCount()`, and `uxTaskGetStackHighWaterMark()` for both tasks |
| `links` | Per guest: `<name>: ivpos=<hex> l2f_flag=<n> f2l_flag=<n> since_hello=<ms>` (flags from `link->layout`; `since_hello = xTaskGetTickCount() - *last_hello_ticks`, converted to ms) |
| `loglevel [N]` | No arg → prints current numeric level + name (VERBOSE/INFO/WARN/ERROR). Arg `0-3` → sets `g_freertos_log_level`, echoes new value. Out-of-range → `"usage: loglevel [0-3]\n"` |
| `can status` | `sr=<hex> rx_frames=<count>` via `can_get_status()`. Any other/missing argument → `"usage: can status\n"` |

## Edge Cases / Known Limitations

- **UART output interleaving**: `log_uart()` (called from `showcase_task`,
  ISRs, and now `shell_task`) has no cross-task output mutex — this is a
  pre-existing characteristic (e.g. `can_rx_isr` already logs from ISR
  context). A periodic heartbeat/stats line can interleave with shell echo
  mid-command. Not addressed by this design; noted as a known cosmetic
  limitation.
- **Line overflow** (>80 chars without Enter): further input silently
  dropped until Enter/backspace.
- **Empty line**: reprints prompt only, no command dispatched.

## Testing

1. `make freertos-r52-demo.elf` builds cleanly with the new files.
2. Launch via the full showcase (or `guest-run-r52-freertos-phase5.sh`
   directly), attach to the FreeRTOS tmux pane.
3. `tmux send-keys ... "help" Enter` → verify all 6 commands listed with help
   text.
4. Run `stats`, `sysinfo`, `links`, `can status` → sane non-crashing output;
   cross-check `stats` counts against
   `/var/log/chimera-log/chimera-cross-domain.log`.
5. `loglevel 0` (VERBOSE) → confirm previously-suppressed `[V]` lines (e.g.
   `[irq] ... HELLO handled via IRQ`) now appear; `loglevel 1` restores
   default.
6. Type with intentional typos + backspace → confirm correct in-place
   editing.
7. Confirm HELLO/ACK counts (`arm_count` etc.) keep incrementing normally
   while interacting with the shell — i.e., the shell doesn't perturb the
   existing demo.
8. 3 consecutive full showcase runs pass, per the project's autonomous
   debug-loop convention.
