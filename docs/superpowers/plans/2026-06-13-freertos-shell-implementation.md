# FreeRTOS Interactive Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an interrupt-driven UART command shell to the bare-metal FreeRTOS (Cortex-R52) firmware, exposing `help`, `stats`, `sysinfo`, `links`, `loglevel`, and `can status` for live debugging without rebuilding.

**Architecture:** GIC SPI32 (UART0 RX, level-sensitive) feeds bytes into `uart_rx_queue` via `uart_rx_isr()`; a new `shell` task (priority `tskIDLE_PRIORITY+1`, 1024-word stack) blocks on that queue, does line editing/tokenizing, and dispatches into a command table that reads existing `showcase_task` state through a `struct chimera_shell_ctx` populated once at init. Pure parsing helpers (`shell_str_eq`/`shell_parse_uint`/`shell_tokenize`) live in a host-testable header, mirroring the existing `can_proto.h` / `test_can_decode.c` pattern.

**Tech Stack:** C (freestanding, `-ffreestanding -mcpu=cortex-r52`), FreeRTOS (ARM_CR5 port: tasks, queues), GICv2, PL011 UART. Host-side unit tests built with `cc -O2 -Wall`.

**Design spec:** `docs/superpowers/specs/2026-06-13-freertos-shell-design.md` (approved).

---

## File Structure

All paths relative to `contrib/heterogeneous-soc/freertos-showcase/` unless noted.

| File | Status | Responsibility |
|---|---|---|
| `shell_parse.h` | new | Pure, host-testable string helpers (`shell_str_eq`, `shell_parse_uint`, `shell_tokenize`) — freestanding libc has no `strcmp`/`atoi` |
| `test_shell_parse.c` | new | Host unit test for `shell_parse.h`, run via `make check` |
| `uart_driver.h` / `uart_driver.c` | new | PL011 UART driver: `uart_putc()` (TX, moved from `freertos_main.c`), `uart_init_rx()` / `uart_rx_isr()` (RX via GIC SPI32), `uart_rx_queue` |
| `can_driver.h` / `can_driver.c` | modified | Add `struct can_status` + `can_get_status()` accessor for the `can status` command |
| `shell.h` / `shell.c` | new | `struct chimera_shell_ctx`/`struct chimera_shell_guest`, `shell_init()`, the `shell` task (line editing + dispatch), and the 6 command handlers |
| `freertos_main.c` | modified | Wire in `uart_driver.h`/`shell.h`, runtime `g_freertos_log_level`, UART IRQ dispatch, populate `g_shell_ctx`, capture `g_showcase_task_handle` |
| `Makefile` | modified | Add `uart_driver.c shell.c` (+headers) to the ELF build; add `test_shell_parse` to `check` |
| `.gitignore` | modified | Ignore `test_shell_parse` binary |
| `contrib/heterogeneous-soc/freertos-showcase/README.md` | modified | Directory-layout table rows for the 5 new/changed files |
| `README.md` (repo root) | modified | Chimera-Specific Code table rows + new "Interactive Shell" section |

---

### Task 1: Shell parsing helpers (TDD)

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/test_shell_parse.c`
- Create: `contrib/heterogeneous-soc/freertos-showcase/shell_parse.h`

- [ ] **Step 1: Write the failing test**

Create `contrib/heterogeneous-soc/freertos-showcase/test_shell_parse.c`:

```c
/* Host unit test for shell_parse.h helpers. Build: cc -O2 -Wall -o test_shell_parse test_shell_parse.c */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "shell_parse.h"

int main(void)
{
    /* shell_str_eq */
    assert(shell_str_eq("help", "help"));
    assert(!shell_str_eq("help", "hel"));
    assert(!shell_str_eq("hel", "help"));
    assert(!shell_str_eq("help", "Help"));
    assert(shell_str_eq("", ""));

    /* shell_parse_uint */
    assert(shell_parse_uint("0") == 0);
    assert(shell_parse_uint("3") == 3);
    assert(shell_parse_uint("42") == 42);
    assert(shell_parse_uint("") == 0);
    assert(shell_parse_uint("abc") == 0);
    assert(shell_parse_uint("12abc") == 12);

    /* shell_tokenize */
    {
        char line[32];
        char *argv[SHELL_MAX_ARGS];
        int argc;

        strcpy(line, "help");
        argc = shell_tokenize(line, argv);
        assert(argc == 1);
        assert(shell_str_eq(argv[0], "help"));

        strcpy(line, "can status");
        argc = shell_tokenize(line, argv);
        assert(argc == 2);
        assert(shell_str_eq(argv[0], "can"));
        assert(shell_str_eq(argv[1], "status"));

        strcpy(line, "  loglevel   2  ");
        argc = shell_tokenize(line, argv);
        assert(argc == 2);
        assert(shell_str_eq(argv[0], "loglevel"));
        assert(shell_str_eq(argv[1], "2"));

        strcpy(line, "");
        argc = shell_tokenize(line, argv);
        assert(argc == 0);

        strcpy(line, "   ");
        argc = shell_tokenize(line, argv);
        assert(argc == 0);

        /* More than SHELL_MAX_ARGS tokens: argc caps, first SHELL_MAX_ARGS
         * tokens are still correctly terminated. */
        strcpy(line, "a b c d e f");
        argc = shell_tokenize(line, argv);
        assert(argc == SHELL_MAX_ARGS);
        assert(shell_str_eq(argv[0], "a"));
        assert(shell_str_eq(argv[1], "b"));
        assert(shell_str_eq(argv[2], "c"));
        assert(shell_str_eq(argv[3], "d"));
    }

    printf("test_shell_parse: OK\n");
    return 0;
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `contrib/heterogeneous-soc/freertos-showcase/`):

```bash
cc -O2 -Wall -o test_shell_parse test_shell_parse.c
```

Expected: FAIL — `fatal error: 'shell_parse.h' file not found` (or `No such file or directory`).

- [ ] **Step 3: Write the implementation**

Create `contrib/heterogeneous-soc/freertos-showcase/shell_parse.h`:

```c
#ifndef HETEROGENEOUS_SOC_FREERTOS_SHELL_PARSE_H
#define HETEROGENEOUS_SOC_FREERTOS_SHELL_PARSE_H

#include <stdint.h>

#define SHELL_MAX_ARGS 4

/* Exact string comparison (freestanding libc has no strcmp). */
static inline int shell_str_eq(const char *a, const char *b)
{
    while (*a != '\0' && *b != '\0') {
        if (*a != *b) {
            return 0;
        }
        a++;
        b++;
    }
    return *a == *b;
}

/* Decimal string -> uint32_t. Stops at the first non-digit. Empty/non-digit
 * input returns 0. */
static inline uint32_t shell_parse_uint(const char *s)
{
    uint32_t v = 0;

    while (*s >= '0' && *s <= '9') {
        v = (v * 10u) + (uint32_t)(*s - '0');
        s++;
    }

    return v;
}

/* Split `line` in place on runs of spaces, writing '\0' at each separator and
 * filling argv[] with pointers to up to SHELL_MAX_ARGS tokens. Returns the
 * token count (argc). Extra tokens beyond SHELL_MAX_ARGS are ignored (argc
 * caps at SHELL_MAX_ARGS, but parsing still consumes the whole line so a
 * later '\0' isn't left mid-string). */
static inline int shell_tokenize(char *line, char *argv[SHELL_MAX_ARGS])
{
    int argc = 0;
    char *p = line;

    while (*p != '\0') {
        while (*p == ' ') {
            *p = '\0';
            p++;
        }

        if (*p == '\0') {
            break;
        }

        if (argc < SHELL_MAX_ARGS) {
            argv[argc++] = p;
        }

        while (*p != '\0' && *p != ' ') {
            p++;
        }
    }

    return argc;
}

#endif
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
cc -O2 -Wall -o test_shell_parse test_shell_parse.c && ./test_shell_parse
```

Expected: PASS — prints `test_shell_parse: OK` with no warnings.

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/shell_parse.h contrib/heterogeneous-soc/freertos-showcase/test_shell_parse.c
git commit -m "feat(freertos): add shell_parse helpers with host unit test"
```

---

### Task 2: UART driver (TX move + interrupt-driven RX)

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/uart_driver.h`
- Create: `contrib/heterogeneous-soc/freertos-showcase/uart_driver.c`

- [ ] **Step 1: Write `uart_driver.h`**

Create `contrib/heterogeneous-soc/freertos-showcase/uart_driver.h`:

```c
#ifndef HETEROGENEOUS_SOC_FREERTOS_UART_DRIVER_H
#define HETEROGENEOUS_SOC_FREERTOS_UART_DRIVER_H

#include <stdint.h>

#include "FreeRTOS.h"
#include "queue.h"

/* GIC SPI for UART0 (PL011), CHIMERA_R52_FREERTOS_UART_SPI = 0 -> INTID 32. */
#define R52_UART_INTID 32U

/* RX byte queue, created by uart_init_rx(). shell_task() blocks on this. */
extern QueueHandle_t uart_rx_queue;

/* Write one character to UART0 (PL011 UARTDR), busy-waiting while TXFF. */
void uart_putc(char ch);

/* Enable PL011 RX interrupt (UARTIMSC.RX) and GIC SPI32 (level-sensitive,
 * priority 0xA0, target CPU0). Creates uart_rx_queue. Call once from
 * showcase_task's init, after the tick interrupt is configured. */
void uart_init_rx(void);

/* Called from vApplicationIRQHandler when intid == R52_UART_INTID (32).
 * Drains UARTDR while !(UARTFR & RXFE), pushing each byte to
 * uart_rx_queue via xQueueSendFromISR(). */
void uart_rx_isr(void);

#endif
```

- [ ] **Step 2: Write `uart_driver.c`**

Create `contrib/heterogeneous-soc/freertos-showcase/uart_driver.c`:

```c
#include "uart_driver.h"

#define UART0_BASE 0x10000000UL
#define PL011_DR    0x00U  /* data register */
#define PL011_FR    0x18U  /* flag register */
#define PL011_IMSC  0x38U  /* interrupt mask set/clear register */

#define PL011_FR_RXFE 0x10U  /* receive FIFO empty */
#define PL011_FR_TXFF 0x20U  /* transmit FIFO full */
#define PL011_INT_RX  0x10U  /* RX interrupt (UARTRIS/UARTIMSC bit 4) */

#define GICD_BASE       0x08000000UL
#define GICD_ISENABLER  0x100U  /* +(intid/32)*4 */
#define GICD_IPRIORITYR 0x400U  /* +intid */
#define GICD_ITARGETSR  0x800U  /* byte per intid */

#define UART_RX_QUEUE_LEN 64

QueueHandle_t uart_rx_queue;

void uart_putc(char ch)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);

    while ((*fr & PL011_FR_TXFF) != 0) {
    }

    *dr = (uint32_t)(uint8_t)ch;
}

static void gic_enable_uart_rx_spi(void)
{
    volatile uint8_t  *iprio   = (volatile uint8_t  *)(GICD_BASE + GICD_IPRIORITYR);
    volatile uint8_t  *itarget = (volatile uint8_t  *)(GICD_BASE + GICD_ITARGETSR);
    volatile uint32_t *isen    = (volatile uint32_t *)(GICD_BASE + GICD_ISENABLER);

    /* Same mid priority/target-CPU0 convention as the other SPIs enabled in
     * freertos_main.c and can_driver.c. PL011's combined IRQ is a sustained
     * level (pl011_update() calls qemu_set_irq(level)), and GIC SPIs default
     * to level-sensitive, so unlike the edge-configured ivshmem doorbell
     * SPIs, GICD_ICFGR is left untouched here. */
    iprio[R52_UART_INTID]   = 0xA0;
    itarget[R52_UART_INTID] = 0x01;
    isen[R52_UART_INTID / 32] |= (1U << (R52_UART_INTID % 32));
}

void uart_init_rx(void)
{
    volatile uint32_t *imsc = (volatile uint32_t *)(UART0_BASE + PL011_IMSC);

    uart_rx_queue = xQueueCreate(UART_RX_QUEUE_LEN, sizeof(uint8_t));

    /* Enable only the RX interrupt source, so TX-complete events (INT_TX)
     * don't spuriously assert the combined IRQ line. */
    *imsc |= PL011_INT_RX;

    gic_enable_uart_rx_spi();
}

void uart_rx_isr(void)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);
    BaseType_t higher_priority_task_woken = pdFALSE;

    while ((*fr & PL011_FR_RXFE) == 0) {
        uint8_t byte = (uint8_t)(*dr & 0xFFU);
        xQueueSendFromISR(uart_rx_queue, &byte, &higher_priority_task_woken);
    }

    portYIELD_FROM_ISR(higher_priority_task_woken);
}
```

- [ ] **Step 3: Syntax-check on the Lima VM**

Deploy and compile (no link — `freertos_main.c` doesn't reference this file yet):

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && arm-none-eabi-gcc -O2 -Wall -Wextra -ffreestanding -fno-omit-frame-pointer -mcpu=cortex-r52 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm -ffunction-sections -fdata-sections -I. -I$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/include -I$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5 -fsyntax-only uart_driver.c'
```

Expected: no output (clean compile, no warnings).

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/uart_driver.h contrib/heterogeneous-soc/freertos-showcase/uart_driver.c
git commit -m "feat(freertos): add PL011 UART driver with interrupt-driven RX"
```

---

### Task 3: CAN status accessor

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/can_driver.h`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/can_driver.c`

- [ ] **Step 1: Add `struct can_status` and the declaration to `can_driver.h`**

In `contrib/heterogeneous-soc/freertos-showcase/can_driver.h`, the file currently ends with:

```c
/* Initialise the CAN controller, enable its GIC SPI, and prepare the
 * IVSHMEM5 forwarding channel. Call once, before the scheduler relies on it. */
void can_init(uintptr_t can_mmio_base, uintptr_t ivshmem_can_shmem_base);

/* Called from vApplicationIRQHandler when INTID 38 (CAN SPI 6) fires. */
void can_rx_isr(void);

#endif
```

Replace with:

```c
/* Initialise the CAN controller, enable its GIC SPI, and prepare the
 * IVSHMEM5 forwarding channel. Call once, before the scheduler relies on it. */
void can_init(uintptr_t can_mmio_base, uintptr_t ivshmem_can_shmem_base);

/* Called from vApplicationIRQHandler when INTID 38 (CAN SPI 6) fires. */
void can_rx_isr(void);

struct can_status {
    uint32_t sr;        /* CAN_REG_SR (StatusRegister) */
    uint32_t rx_frames; /* can_ivshmem->generation (frames forwarded) */
};

/* Snapshot of CAN controller status, for the shell's `can status` command. */
void can_get_status(struct can_status *out);

#endif
```

- [ ] **Step 2: Implement `can_get_status()` in `can_driver.c`**

In `contrib/heterogeneous-soc/freertos-showcase/can_driver.c`, the file currently ends with `can_rx_isr()`'s closing brace (line 144-145):

```c
    /* Publish to IVSHMEM5: write the frame body, fence, then bump generation. */
    shmem_write_bytes(&can_ivshmem->frame, &f, sizeof(f));
    __sync_synchronize();
    can_ivshmem->generation = can_ivshmem->generation + 1;
    __sync_synchronize();
}
```

Append after the closing `}`:

```c

void can_get_status(struct can_status *out)
{
    out->sr = can_rd(CAN_REG_SR);
    out->rx_frames = can_ivshmem->generation;
}
```

- [ ] **Step 3: Syntax-check on the Lima VM**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && arm-none-eabi-gcc -O2 -Wall -Wextra -ffreestanding -fno-omit-frame-pointer -mcpu=cortex-r52 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm -ffunction-sections -fdata-sections -I. -I$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/include -I$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5 -fsyntax-only can_driver.c'
```

Expected: no output (clean compile, no warnings).

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/can_driver.h contrib/heterogeneous-soc/freertos-showcase/can_driver.c
git commit -m "feat(freertos): add can_get_status() accessor for shell"
```

---

### Task 4: Shell task, line editor, and command table

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/shell.h`
- Create: `contrib/heterogeneous-soc/freertos-showcase/shell.c`

- [ ] **Step 1: Write `shell.h`**

Create `contrib/heterogeneous-soc/freertos-showcase/shell.h`:

```c
#ifndef HETEROGENEOUS_SOC_FREERTOS_SHELL_H
#define HETEROGENEOUS_SOC_FREERTOS_SHELL_H

#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"

#define CHIMERA_SHELL_NUM_GUESTS 3

struct chimera_shell_guest {
    const char *name;
    const struct freertos_ivshmem_link *link;
    const uint32_t *hello_count;
    const uint32_t *cpu_pct_x100;
    const uint32_t *mem_pct_x100;
    const TickType_t *last_hello_ticks;
};

struct chimera_shell_ctx {
    struct chimera_shell_guest guests[CHIMERA_SHELL_NUM_GUESTS];
    TaskHandle_t showcase_task_handle;
};

/*
 * Create the shell task (priority tskIDLE_PRIORITY+1, 1024-word stack).
 * Calls uart_init_rx() internally to enable UART RX interrupts.
 * `ctx` must remain valid for the lifetime of the shell task — pass a
 * pointer to a static/file-scope struct.
 */
void shell_init(const struct chimera_shell_ctx *ctx);

#endif
```

- [ ] **Step 2: Write `shell.c`**

Create `contrib/heterogeneous-soc/freertos-showcase/shell.c`:

```c
#include "shell.h"

#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

#include "can_driver.h"
#include "shell_parse.h"
#include "uart_driver.h"

extern volatile uint32_t g_freertos_log_level;

#define SHELL_LINE_MAX 80
#define SHELL_STACK_WORDS 1024
#define SHELL_PROMPT "chimera> "

static void shell_print(const char *s)
{
    while (*s != '\0') {
        if (*s == '\n') {
            uart_putc('\r');
        }
        uart_putc(*s++);
    }
}

static char *shell_utoa(char *buf, uint32_t val)
{
    char tmp[12];
    int i, j;

    if (val == 0) {
        tmp[0] = '0';
        i = 1;
    } else {
        i = 0;
        while (val > 0) {
            tmp[i++] = '0' + (val % 10);
            val /= 10;
        }
    }

    for (j = 0; j < i; j++) {
        buf[j] = tmp[i - 1 - j];
    }

    buf[j] = '\0';
    return buf + j;
}

static char *shell_utoa_hex(char *buf, uint32_t v)
{
    static const char hex[] = "0123456789abcdef";

    buf[0] = '0';
    buf[1] = 'x';
    buf[2] = hex[(v >> 28) & 0xf];
    buf[3] = hex[(v >> 24) & 0xf];
    buf[4] = hex[(v >> 20) & 0xf];
    buf[5] = hex[(v >> 16) & 0xf];
    buf[6] = hex[(v >> 12) & 0xf];
    buf[7] = hex[(v >> 8) & 0xf];
    buf[8] = hex[(v >> 4) & 0xf];
    buf[9] = hex[v & 0xf];
    buf[10] = '\0';
    return buf + 10;
}

/* "<int>.<2-digit frac>" from an x100 fixed-point value, e.g. 1234 -> "12.34" */
static char *shell_utoa_pct(char *buf, uint32_t val_x100)
{
    char *p = shell_utoa(buf, val_x100 / 100);

    *p++ = '.';
    *p++ = '0' + (val_x100 / 10) % 10;
    *p++ = '0' + val_x100 % 10;
    *p = '\0';
    return p;
}

static void cmd_help(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
static void cmd_stats(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
static void cmd_sysinfo(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
static void cmd_links(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
static void cmd_loglevel(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
static void cmd_can(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);

struct shell_cmd {
    const char *name;
    void (*fn)(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
    const char *help;
};

static const struct shell_cmd shell_cmd_table[] = {
    { "help",     cmd_help,     "list available commands" },
    { "stats",    cmd_stats,    "per-guest HELLO count, cpu%, mem%" },
    { "sysinfo",  cmd_sysinfo,  "heap free, uptime, stack high-water marks" },
    { "links",    cmd_links,    "per-channel IVPOSITION, flags, time since last HELLO" },
    { "loglevel", cmd_loglevel, "get/set runtime log verbosity (0=VERBOSE..3=ERROR)" },
    { "can",      cmd_can,      "'can status' - CAN controller status register, frames forwarded" },
};

#define SHELL_NUM_CMDS (sizeof(shell_cmd_table) / sizeof(shell_cmd_table[0]))

static void cmd_help(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    uint32_t i;

    (void)ctx;
    (void)argc;
    (void)argv;

    for (i = 0; i < SHELL_NUM_CMDS; i++) {
        shell_print(shell_cmd_table[i].name);
        shell_print(" - ");
        shell_print(shell_cmd_table[i].help);
        shell_print("\n");
    }
}

static void cmd_stats(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    int i;
    char buf[16];

    (void)argc;
    (void)argv;

    for (i = 0; i < CHIMERA_SHELL_NUM_GUESTS; i++) {
        const struct chimera_shell_guest *g = &ctx->guests[i];

        shell_print(g->name);
        shell_print(": hello=");
        shell_utoa(buf, *g->hello_count);
        shell_print(buf);
        shell_print(" cpu=");
        shell_utoa_pct(buf, *g->cpu_pct_x100);
        shell_print(buf);
        shell_print("% mem=");
        shell_utoa_pct(buf, *g->mem_pct_x100);
        shell_print(buf);
        shell_print("%\n");
    }
}

static void cmd_sysinfo(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    char buf[12];

    (void)argc;
    (void)argv;

    shell_print("heap_free=");
    shell_utoa(buf, (uint32_t)xPortGetFreeHeapSize());
    shell_print(buf);
    shell_print(" uptime_s=");
    shell_utoa(buf, (uint32_t)(xTaskGetTickCount() / configTICK_RATE_HZ));
    shell_print(buf);
    shell_print(" shell_stack_hiwat=");
    shell_utoa(buf, (uint32_t)uxTaskGetStackHighWaterMark(NULL));
    shell_print(buf);
    shell_print(" showcase_stack_hiwat=");
    shell_utoa(buf, (uint32_t)uxTaskGetStackHighWaterMark(ctx->showcase_task_handle));
    shell_print(buf);
    shell_print("\n");
}

static void cmd_links(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    int i;
    char buf[12];

    (void)argc;
    (void)argv;

    for (i = 0; i < CHIMERA_SHELL_NUM_GUESTS; i++) {
        const struct chimera_shell_guest *g = &ctx->guests[i];
        uint32_t ivpos = g->link->mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
        TickType_t since = xTaskGetTickCount() - *g->last_hello_ticks;

        shell_print(g->name);
        shell_print(": ivpos=");
        shell_utoa_hex(buf, ivpos);
        shell_print(buf);
        shell_print(" l2f_flag=");
        shell_utoa(buf, g->link->layout->linux_to_freertos.flag);
        shell_print(buf);
        shell_print(" f2l_flag=");
        shell_utoa(buf, g->link->layout->freertos_to_linux.flag);
        shell_print(buf);
        shell_print(" since_hello=");
        shell_utoa(buf, (uint32_t)(since * portTICK_PERIOD_MS));
        shell_print(buf);
        shell_print("ms\n");
    }
}

static const char *const shell_log_level_names[] = {
    "VERBOSE", "INFO", "WARN", "ERROR",
};

static void cmd_loglevel(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    char buf[12];

    (void)ctx;

    if (argc >= 2) {
        uint32_t requested = shell_parse_uint(argv[1]);

        if (requested > HSOC_LOG_ERROR) {
            shell_print("usage: loglevel [0-3]\n");
            return;
        }

        g_freertos_log_level = requested;
    }

    shell_print("loglevel=");
    shell_utoa(buf, g_freertos_log_level);
    shell_print(buf);
    shell_print(" (");
    shell_print(shell_log_level_names[g_freertos_log_level]);
    shell_print(")\n");
}

static void cmd_can(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    struct can_status st;
    char buf[12];

    (void)ctx;

    if (argc < 2 || !shell_str_eq(argv[1], "status")) {
        shell_print("usage: can status\n");
        return;
    }

    can_get_status(&st);

    shell_print("sr=");
    shell_utoa_hex(buf, st.sr);
    shell_print(buf);
    shell_print(" rx_frames=");
    shell_utoa(buf, st.rx_frames);
    shell_print(buf);
    shell_print("\n");
}

static void shell_dispatch(const struct chimera_shell_ctx *ctx, char *line)
{
    char *argv[SHELL_MAX_ARGS];
    int argc = shell_tokenize(line, argv);
    uint32_t i;

    if (argc == 0) {
        return;
    }

    for (i = 0; i < SHELL_NUM_CMDS; i++) {
        if (shell_str_eq(argv[0], shell_cmd_table[i].name)) {
            shell_cmd_table[i].fn(ctx, argc, argv);
            return;
        }
    }

    shell_print("unknown command: ");
    shell_print(argv[0]);
    shell_print(" (try 'help')\n");
}

static void shell_task(void *param)
{
    const struct chimera_shell_ctx *ctx = (const struct chimera_shell_ctx *)param;
    char line[SHELL_LINE_MAX + 1];
    uint32_t len = 0;
    uint8_t last_term = 0;

    shell_print("\n" SHELL_PROMPT);

    for (;;) {
        uint8_t c;

        if (xQueueReceive(uart_rx_queue, &c, portMAX_DELAY) != pdTRUE) {
            continue;
        }

        if (c == '\r' || c == '\n') {
            if (last_term != 0 && last_term != c) {
                /* second half of a CRLF/LFCR pair: swallow it */
                last_term = 0;
                continue;
            }

            last_term = c;
            shell_print("\r\n");
            line[len] = '\0';
            shell_dispatch(ctx, line);
            len = 0;
            shell_print(SHELL_PROMPT);
            continue;
        }

        last_term = 0;

        if (c == 0x08 || c == 0x7f) {
            if (len > 0) {
                len--;
                shell_print("\b \b");
            }
            continue;
        }

        if (c >= 0x20 && c < 0x7f) {
            if (len < SHELL_LINE_MAX) {
                line[len++] = (char)c;
                uart_putc((char)c);
            }
            continue;
        }

        /* other control bytes: ignored */
    }
}

void shell_init(const struct chimera_shell_ctx *ctx)
{
    uart_init_rx();

    xTaskCreate(shell_task, "shell", SHELL_STACK_WORDS, (void *)ctx,
                tskIDLE_PRIORITY + 1, NULL);
}
```

- [ ] **Step 3: Syntax-check on the Lima VM**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && arm-none-eabi-gcc -O2 -Wall -Wextra -ffreestanding -fno-omit-frame-pointer -mcpu=cortex-r52 -mfpu=neon-fp-armv8 -mfloat-abi=hard -marm -ffunction-sections -fdata-sections -I. -I$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/include -I$HOME/heterogeneous-soc-freertos/FreeRTOS-Kernel/portable/GCC/ARM_CR5 -fsyntax-only shell.c'
```

Expected: no output (clean compile, no warnings). `g_freertos_log_level`, used but not yet defined anywhere, is fine for `-fsyntax-only` — it's an `extern` declaration; the definition is added in Task 5.

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/shell.h contrib/heterogeneous-soc/freertos-showcase/shell.c
git commit -m "feat(freertos): add interactive shell task and command table"
```

---

### Task 5: Wire the shell into `freertos_main.c` and the Makefile

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/.gitignore`

- [ ] **Step 1: Add new includes**

In `freertos_main.c`, lines 1-10 currently read:

```c
#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"
#include "stats_proto.h"
#include "bootlog_proto.h"
#include "boot_log.h"
#include "can_driver.h"
```

Add two includes after `can_driver.h`:

```c
#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"
#include "stats_proto.h"
#include "bootlog_proto.h"
#include "boot_log.h"
#include "can_driver.h"
#include "uart_driver.h"
#include "shell.h"
```

- [ ] **Step 2: Add the runtime log-level global**

Lines 12-21 currently read:

```c
/* Minimum log severity for output. Messages below this level are suppressed.
 * Override at build time with -DFREERTOS_LOG_LEVEL=HSOC_LOG_VERBOSE etc. */
#ifndef FREERTOS_LOG_LEVEL
#define FREERTOS_LOG_LEVEL HSOC_LOG_INFO
#endif

#define UART0_BASE 0x10000000UL
#define PL011_DR   0x00    /* data register */
#define PL011_FR   0x18    /* flag register */
#define PL011_FR_TXFF 0x20 /* transmit FIFO full */
```

Replace with (adds `g_freertos_log_level` and drops the now-relocated `PL011_DR`/`PL011_FR`/`PL011_FR_TXFF` defines — but keeps `UART0_BASE`, which the startup-diagnostics block at line 371 (`log_hex32_uart(HSOC_LOG_VERBOSE, UART0_BASE)`) still needs; `uart_driver.c` has its own copy of `UART0_BASE` for its own use):

```c
/* Minimum log severity for output. Messages below this level are suppressed.
 * Override at build time with -DFREERTOS_LOG_LEVEL=HSOC_LOG_VERBOSE etc. */
#ifndef FREERTOS_LOG_LEVEL
#define FREERTOS_LOG_LEVEL HSOC_LOG_INFO
#endif

/* Runtime-adjustable copy of the initial log level, settable via the
 * shell's `loglevel` command. */
volatile uint32_t g_freertos_log_level = FREERTOS_LOG_LEVEL;

/* Used by the startup-diagnostics block in showcase_task(); PL011 register
 * offsets (no longer needed here) moved to uart_driver.c. */
#define UART0_BASE 0x10000000UL
```

- [ ] **Step 3: Add shell context globals**

Lines 37-53 currently read:

```c
static struct freertos_ivshmem_link arm_link;
static struct freertos_ivshmem_link riscv_link;
static struct freertos_ivshmem_link mips_link;

static volatile struct hsoc_stats_snapshot *stats_shmem =
    (volatile struct hsoc_stats_snapshot *)IVSHMEM3_SHMEM;
static uint32_t arm_count;
static uint32_t riscv_count;
static uint32_t mips_count;
static uint32_t arm_cpu_pct, arm_mem_pct;
static uint32_t riscv_cpu_pct, riscv_mem_pct;
static uint32_t mips_cpu_pct, mips_mem_pct;
static uint32_t stats_tick;
static TickType_t arm_last_hello_ticks;
static TickType_t riscv_last_hello_ticks;
static TickType_t mips_last_hello_ticks;
static struct bootlog_monitor bootlog;
```

Add two new statics after `bootlog`:

```c
static struct freertos_ivshmem_link arm_link;
static struct freertos_ivshmem_link riscv_link;
static struct freertos_ivshmem_link mips_link;

static volatile struct hsoc_stats_snapshot *stats_shmem =
    (volatile struct hsoc_stats_snapshot *)IVSHMEM3_SHMEM;
static uint32_t arm_count;
static uint32_t riscv_count;
static uint32_t mips_count;
static uint32_t arm_cpu_pct, arm_mem_pct;
static uint32_t riscv_cpu_pct, riscv_mem_pct;
static uint32_t mips_cpu_pct, mips_mem_pct;
static uint32_t stats_tick;
static TickType_t arm_last_hello_ticks;
static TickType_t riscv_last_hello_ticks;
static TickType_t mips_last_hello_ticks;
static struct bootlog_monitor bootlog;
static struct chimera_shell_ctx g_shell_ctx;
static TaskHandle_t g_showcase_task_handle;
```

- [ ] **Step 4: Remove the relocated `uart_putc()`**

Lines 55-65 currently read:

```c
static void uart_putc(char ch)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);

    while ((*fr & PL011_FR_TXFF) != 0) {
    }

    *dr = (uint32_t)(uint8_t)ch;
}

static char *utoa_dec(char *buf, uint32_t val)
```

Delete the `uart_putc()` function (now provided by `uart_driver.c`/`uart_driver.h`), leaving:

```c
static char *utoa_dec(char *buf, uint32_t val)
```

as the start of that block (i.e. the blank line and the whole `uart_putc` definition above it are removed).

- [ ] **Step 5: Change `log_uart()`'s level guard to the runtime variable**

The guard (originally around line 101) currently reads:

```c
    /* Suppress messages below the configured log level */
    if (level < FREERTOS_LOG_LEVEL) {
        return;
    }
```

Replace with:

```c
    /* Suppress messages below the configured log level */
    if (level < g_freertos_log_level) {
        return;
    }
```

- [ ] **Step 6: Add the UART RX branch to `vApplicationIRQHandler`**

The handler (originally lines 311-336) currently ends:

```c
    } else if (intid == R52_IVSHMEM2_INTID) {
        log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem2: SPI35 dispatched\n");
        freertos_ivshmem_isr(&mips_link, &mips_count, &mips_cpu_pct, &mips_mem_pct,
                              &mips_last_hello_ticks, (1U << 16) | 0U);
    } else {
        log_uart(HSOC_LOG_WARN, "[irq] unexpected intid=");
        log_hex32_uart(HSOC_LOG_WARN, intid);
        log_uart(HSOC_LOG_WARN, "\n");
    }
}
```

Insert a new branch for `R52_UART_INTID` before the final `else`:

```c
    } else if (intid == R52_IVSHMEM2_INTID) {
        log_uart(HSOC_LOG_VERBOSE, "[irq] ivshmem2: SPI35 dispatched\n");
        freertos_ivshmem_isr(&mips_link, &mips_count, &mips_cpu_pct, &mips_mem_pct,
                              &mips_last_hello_ticks, (1U << 16) | 0U);
    } else if (intid == R52_UART_INTID) {
        uart_rx_isr();
    } else {
        log_uart(HSOC_LOG_WARN, "[irq] unexpected intid=");
        log_hex32_uart(HSOC_LOG_WARN, intid);
        log_uart(HSOC_LOG_WARN, "\n");
    }
}
```

- [ ] **Step 7: Populate `g_shell_ctx` and call `shell_init()` in `showcase_task`**

The init block (originally lines 353-360) currently reads:

```c
    /* Enable IVSHMEM0/1/2 GIC SPIs for interrupt-driven HELLO reception.
     * The GICD_CTLR group-0 forwarding is already enabled by
     * vConfigureTickInterrupt(). */
    gic_enable_ivshmem_spi(R52_IVSHMEM0_INTID);
    gic_enable_ivshmem_spi(R52_IVSHMEM1_INTID);
    gic_enable_ivshmem_spi(R52_IVSHMEM2_INTID);

    log_uart(HSOC_LOG_INFO, "[freertos] showcase task started\n");
```

Insert the `g_shell_ctx` setup and `shell_init()` call between the GIC enables and the "showcase task started" log line:

```c
    /* Enable IVSHMEM0/1/2 GIC SPIs for interrupt-driven HELLO reception.
     * The GICD_CTLR group-0 forwarding is already enabled by
     * vConfigureTickInterrupt(). */
    gic_enable_ivshmem_spi(R52_IVSHMEM0_INTID);
    gic_enable_ivshmem_spi(R52_IVSHMEM1_INTID);
    gic_enable_ivshmem_spi(R52_IVSHMEM2_INTID);

    g_shell_ctx.guests[0].name = "arm-linux";
    g_shell_ctx.guests[0].link = &arm_link;
    g_shell_ctx.guests[0].hello_count = &arm_count;
    g_shell_ctx.guests[0].cpu_pct_x100 = &arm_cpu_pct;
    g_shell_ctx.guests[0].mem_pct_x100 = &arm_mem_pct;
    g_shell_ctx.guests[0].last_hello_ticks = &arm_last_hello_ticks;

    g_shell_ctx.guests[1].name = "riscv-linux";
    g_shell_ctx.guests[1].link = &riscv_link;
    g_shell_ctx.guests[1].hello_count = &riscv_count;
    g_shell_ctx.guests[1].cpu_pct_x100 = &riscv_cpu_pct;
    g_shell_ctx.guests[1].mem_pct_x100 = &riscv_mem_pct;
    g_shell_ctx.guests[1].last_hello_ticks = &riscv_last_hello_ticks;

    g_shell_ctx.guests[2].name = "mips-linux";
    g_shell_ctx.guests[2].link = &mips_link;
    g_shell_ctx.guests[2].hello_count = &mips_count;
    g_shell_ctx.guests[2].cpu_pct_x100 = &mips_cpu_pct;
    g_shell_ctx.guests[2].mem_pct_x100 = &mips_mem_pct;
    g_shell_ctx.guests[2].last_hello_ticks = &mips_last_hello_ticks;

    g_shell_ctx.showcase_task_handle = g_showcase_task_handle;

    shell_init(&g_shell_ctx);

    log_uart(HSOC_LOG_INFO, "[freertos] showcase task started\n");
```

- [ ] **Step 8: Capture the showcase task handle in `main()`**

`main()` (originally lines 509-510) currently reads:

```c
    rc = xTaskCreate(showcase_task, "showcase", 2048, 0,
                     tskIDLE_PRIORITY + 1, 0);
```

Replace the discarded last argument with `&g_showcase_task_handle`:

```c
    rc = xTaskCreate(showcase_task, "showcase", 2048, 0,
                     tskIDLE_PRIORITY + 1, &g_showcase_task_handle);
```

- [ ] **Step 9: Add `uart_driver.c` and `shell.c` to the Makefile**

In `contrib/heterogeneous-soc/freertos-showcase/Makefile`, the `freertos-r52-demo.elf` target (lines 113-123) currently reads:

```makefile
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

Replace with:

```makefile
freertos-r52-demo.elf: freertos_main.c freertos_ivshmem_flat.c boot_log.c can_driver.c \
		uart_driver.c shell.c \
		freertos_ivshmem_flat.h freertos_libc.c startup.S linker.ld FreeRTOSConfig.h \
		hello_proto.h stats_proto.h bootlog_proto.h boot_log.h \
		can_driver.h can_proto.h uart_driver.h shell.h shell_parse.h $(FREERTOS_SRCS)
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_PORT_DIR) \
	  startup.S freertos_main.c freertos_ivshmem_flat.c boot_log.c can_driver.c uart_driver.c shell.c freertos_libc.c \
	  $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@
```

- [ ] **Step 10: Add `test_shell_parse` to `clean` and `check`**

The end of the Makefile (lines 125-133) currently reads:

```makefile
clean:
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-r52-demo.elf test_can_decode

check: test_can_decode
	./test_can_decode

test_can_decode: test_can_decode.c can_proto.h
	cc -O2 -Wall -o $@ test_can_decode.c
```

Replace with:

```makefile
clean:
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-r52-demo.elf test_can_decode test_shell_parse

check: test_can_decode test_shell_parse
	./test_can_decode
	./test_shell_parse

test_can_decode: test_can_decode.c can_proto.h
	cc -O2 -Wall -o $@ test_can_decode.c

test_shell_parse: test_shell_parse.c shell_parse.h
	cc -O2 -Wall -o $@ test_shell_parse.c
```

- [ ] **Step 11: Ignore the new test binary**

`contrib/heterogeneous-soc/freertos-showcase/.gitignore` currently ends with:

```
boot-collector
test_can_decode
```

Add `test_shell_parse`:

```
boot-collector
test_can_decode
test_shell_parse
```

- [ ] **Step 12: Deploy and build the full ELF**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && make freertos-r52-demo.elf'
```

Expected: `freertos-r52-demo.elf` builds with no errors (link succeeds — `shell_init`, `uart_init_rx`, `uart_putc`, `uart_rx_isr`, `can_get_status` all resolve).

- [ ] **Step 13: Run `make check`**

```bash
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && make check'
```

Expected:

```
./test_can_decode
test_can_decode_id: OK
...
./test_shell_parse
test_shell_parse: OK
```

(exact `test_can_decode` lines per its existing output — both binaries must exit 0).

- [ ] **Step 14: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c contrib/heterogeneous-soc/freertos-showcase/Makefile contrib/heterogeneous-soc/freertos-showcase/.gitignore
git commit -m "feat(freertos): wire interactive shell into firmware build"
```

---

### Task 6: Documentation

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/README.md`
- Modify: `README.md` (repo root)

- [ ] **Step 1: Add new files to the freertos-showcase directory-layout table**

In `contrib/heterogeneous-soc/freertos-showcase/README.md`, the "FreeRTOS Firmware" table (lines 19-31) currently reads:

```markdown
| File | Purpose |
|---|---|
| `freertos_main.c` | Entry point (`main`), FreeRTOS `showcase_task` that polls all three HELLO/ACK channels every 1 ms, sends periodic stats snapshots (every 5 s), and runs the boot-log monitor |
| `freertos_ivshmem_flat.c` | `ivshmem-flat` device driver — `freertos_ivshmem_init`, `poll_hello`, `send_ack` with explicit volatile byte loops (no `memcpy`) and `__sync_synchronize()` fences |
| `freertos_ivshmem_flat.h` | `struct freertos_ivshmem_link`, MMIO register offsets (`INTMASK`/`INTSTATUS`/`IVPOSITION`/`DOORBELL`), function declarations |
| `boot_log.c` | Boot-log monitor (`bootlog_init`, `bootlog_tick`, `bootlog_write`) — waits for collector peer ID from ARM, rings doorbell when all guests are booted, writes FreeRTOS UART output into its boot-log slot |
| `boot_log.h` | `struct bootlog_monitor` and function declarations |
| `freertos_libc.c` | Freestanding libc implementations: `memcpy`, `memmove`, `memset`, `memcmp`, `strcpy`, `strlen` |
| `string.h` | libc string header (freestanding) |
| `stdlib.h` | Minimal libc stdlib header (`EXIT_SUCCESS`/`EXIT_FAILURE`) |
| `startup.S` | ARM `_start`: exception vector table, per-mode stacks, enable FPU, clear BSS, call `main` |
| `linker.ld` | Linker script — RAM at `0x80000000`, 8 MiB, `.vectors` section + ARM_CR5 handler `KEEP` |
| `FreeRTOSConfig.h` | Kernel config: 10 MHz CPU clock, 1 kHz tick, 64 KiB heap, `configINTERRUPT_CONTROLLER_BASE_ADDRESS` / `configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET` for GICv2, generic-timer tick |
```

Insert 5 new rows after the `boot_log.h` row (before `freertos_libc.c`):

```markdown
| File | Purpose |
|---|---|
| `freertos_main.c` | Entry point (`main`), FreeRTOS `showcase_task` that polls all three HELLO/ACK channels every 1 ms, sends periodic stats snapshots (every 5 s), and runs the boot-log monitor |
| `freertos_ivshmem_flat.c` | `ivshmem-flat` device driver — `freertos_ivshmem_init`, `poll_hello`, `send_ack` with explicit volatile byte loops (no `memcpy`) and `__sync_synchronize()` fences |
| `freertos_ivshmem_flat.h` | `struct freertos_ivshmem_link`, MMIO register offsets (`INTMASK`/`INTSTATUS`/`IVPOSITION`/`DOORBELL`), function declarations |
| `boot_log.c` | Boot-log monitor (`bootlog_init`, `bootlog_tick`, `bootlog_write`) — waits for collector peer ID from ARM, rings doorbell when all guests are booted, writes FreeRTOS UART output into its boot-log slot |
| `boot_log.h` | `struct bootlog_monitor` and function declarations |
| `uart_driver.c` | PL011 UART driver — `uart_putc()` (TX), `uart_init_rx()` / `uart_rx_isr()` (RX via GIC SPI32, feeds `uart_rx_queue`) |
| `uart_driver.h` | `uart_rx_queue` (`QueueHandle_t`), `uart_putc()`/`uart_init_rx()`/`uart_rx_isr()` declarations, `R52_UART_INTID` |
| `shell.c` | Interactive UART command shell — `shell_task` (line editing, tokenizing, dispatch), `help`/`stats`/`sysinfo`/`links`/`loglevel`/`can status` commands |
| `shell.h` | `struct chimera_shell_ctx`/`struct chimera_shell_guest`, `shell_init()` declaration |
| `shell_parse.h` | Freestanding-libc-safe parsing helpers: `shell_str_eq`, `shell_parse_uint`, `shell_tokenize` |
| `freertos_libc.c` | Freestanding libc implementations: `memcpy`, `memmove`, `memset`, `memcmp`, `strcpy`, `strlen` |
| `string.h` | libc string header (freestanding) |
| `stdlib.h` | Minimal libc stdlib header (`EXIT_SUCCESS`/`EXIT_FAILURE`) |
| `startup.S` | ARM `_start`: exception vector table, per-mode stacks, enable FPU, clear BSS, call `main` |
| `linker.ld` | Linker script — RAM at `0x80000000`, 8 MiB, `.vectors` section + ARM_CR5 handler `KEEP` |
| `FreeRTOSConfig.h` | Kernel config: 10 MHz CPU clock, 1 kHz tick, 64 KiB heap, `configINTERRUPT_CONTROLLER_BASE_ADDRESS` / `configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET` for GICv2, generic-timer tick |
```

- [ ] **Step 2: Update the main README's Chimera-Specific Code source listing**

In `README.md` (repo root), the source-layout code block (around line 678-686) currently reads:

```
    boot_log.c                — Boot-log monitor: waits for collector, rings doorbell when all 4 guests booted
    boot_log.h                — struct bootlog_monitor and function declarations
    can_driver.c              — xlnx-zynqmp-can driver: GIC SPI 6 (INTID 38) RX ISR, decodes RXFIFO registers, publishes frame to IVSHMEM5
    can_driver.h              — CAN controller register offsets (xlnx-zynqmp-can), can_init()/can_rx_isr() declarations
    freertos_libc.c           — Freestanding libc (memcpy, memmove, memset, memcmp, strcpy, strlen)
    string.h / stdlib.h       — Libc headers for freestanding environment
    startup.S                 — RISC-V _start: set stack pointer, install mtvec, clear BSS, call main
    linker.ld                 — Linker script (RAM at 0x80000000, 8 MiB, KEEP trap handler)
    FreeRTOSConfig.h          — Kernel config (10 MHz CPU, 1 kHz tick, 64 KiB heap)
```

Replace with (adds `can_get_status()` to the `can_driver.h` line and inserts the 5 new files before `freertos_libc.c`):

```
    boot_log.c                — Boot-log monitor: waits for collector, rings doorbell when all 4 guests booted
    boot_log.h                — struct bootlog_monitor and function declarations
    can_driver.c              — xlnx-zynqmp-can driver: GIC SPI 6 (INTID 38) RX ISR, decodes RXFIFO registers, publishes frame to IVSHMEM5
    can_driver.h              — CAN controller register offsets (xlnx-zynqmp-can), can_init()/can_rx_isr()/can_get_status() declarations
    uart_driver.c             — PL011 UART driver: uart_putc() (TX), uart_init_rx()/uart_rx_isr() (RX via GIC SPI32)
    uart_driver.h             — uart_rx_queue, uart_putc()/uart_init_rx()/uart_rx_isr() declarations, R52_UART_INTID
    shell.c                   — Interactive UART shell: shell_task (line editing, tokenizing, dispatch), help/stats/sysinfo/links/loglevel/can status
    shell.h                   — struct chimera_shell_ctx/chimera_shell_guest, shell_init() declaration
    shell_parse.h             — Freestanding-safe parsing helpers: shell_str_eq, shell_parse_uint, shell_tokenize
    freertos_libc.c           — Freestanding libc (memcpy, memmove, memset, memcmp, strcpy, strlen)
    string.h / stdlib.h       — Libc headers for freestanding environment
    startup.S                 — RISC-V _start: set stack pointer, install mtvec, clear BSS, call main
    linker.ld                 — Linker script (RAM at 0x80000000, 8 MiB, KEEP trap handler)
    FreeRTOSConfig.h          — Kernel config (10 MHz CPU, 1 kHz tick, 64 KiB heap)
```

- [ ] **Step 3: Add the new "Interactive Shell" section**

In `README.md` (repo root), the "Tmux Pane Layout" section (lines 347-367) currently ends with:

```markdown
Navigate with **Ctrl-b** + arrow keys. All Linux panes auto-login as `root`, mount the 9p virtfs share, and launch their daemons once the guest boots. The syslog daemons (`syslog-{arm,riscv,mips}-linux`) are pre-installed into each guest's `/usr/local/bin/` by `guest-install-syslog-to-guests.sh` and run directly from the guest filesystem. In pane 6, `linux-arm-stats` runs in the background before `syslog-arm-linux` starts; stats are appended to `/var/log/chimera-log/chimera-cross-domain.log` inside the ARM guest.

---

## Guest Networking & Avahi Discovery
```

Insert a new section between the `---` and `## Guest Networking & Avahi Discovery`:

```markdown
Navigate with **Ctrl-b** + arrow keys. All Linux panes auto-login as `root`, mount the 9p virtfs share, and launch their daemons once the guest boots. The syslog daemons (`syslog-{arm,riscv,mips}-linux`) are pre-installed into each guest's `/usr/local/bin/` by `guest-install-syslog-to-guests.sh` and run directly from the guest filesystem. In pane 6, `linux-arm-stats` runs in the background before `syslog-arm-linux` starts; stats are appended to `/var/log/chimera-log/chimera-cross-domain.log` inside the ARM guest.

---

## Interactive Shell

The FreeRTOS firmware exposes an interactive debug shell on UART0 — the same
serial console used for log output (`-nographic`, tmux pane 5 in the 9-pane
layout above). UART0 RX is interrupt-driven (GIC SPI32 / INTID 32,
level-sensitive); a dedicated `shell` task reads bytes from `uart_rx_queue`
(filled by `uart_rx_isr()`), does line editing (echo, backspace/DEL, CR/LF),
tokenizes, and dispatches into `shell_cmd_table[]` (`shell.c`).

Attach to the FreeRTOS pane and type at the `chimera> ` prompt:

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "help" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -20
```

### Commands

| Command | Output |
|---|---|
| `help` | One line per command: `name - help text` |
| `stats` | Per guest (arm-linux/riscv-linux/mips-linux): `<name>: hello=<count> cpu=<x.xx>% mem=<x.xx>%` |
| `sysinfo` | `heap_free=<bytes> uptime_s=<n> shell_stack_hiwat=<words> showcase_stack_hiwat=<words>` |
| `links` | Per guest: `<name>: ivpos=<hex> l2f_flag=<n> f2l_flag=<n> since_hello=<ms>ms` |
| `loglevel [N]` | No arg: print current level (`0`=VERBOSE..`3`=ERROR) and name. `N` in `0-3`: set `g_freertos_log_level`. Out of range: `usage: loglevel [0-3]` |
| `can status` | `sr=<hex> rx_frames=<count>` from the CAN controller's status register and the IVSHMEM5 generation counter |

Output from `log_uart()` (heartbeats, IRQ diagnostics, etc.) can interleave
with shell echo/output — both write to UART0 with no shared mutex.

---

## Guest Networking & Avahi Discovery
```

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/README.md README.md
git commit -m "docs: document the FreeRTOS interactive shell"
```

---

### Task 7: Integration test

**Files:** none (verification only)

- [ ] **Step 1: Deploy and launch the full showcase**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

Wait for the 8-pane tmux session (`freertos-showcase`) to come up and for all three Linux guests to boot (watch for HELLO/ACK activity).

- [ ] **Step 2: `help` lists all 6 commands**

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "help" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -10
```

Expected: 6 lines, one per command — `help`, `stats`, `sysinfo`, `links`, `loglevel`, `can` — each followed by `- <help text>`.

- [ ] **Step 3: `stats`, `sysinfo`, `links`, `can status` produce sane output**

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "stats" Enter
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "sysinfo" Enter
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "links" Enter
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "can status" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -30
```

Expected (each on its own line, after the corresponding `chimera> ` echo):
- `stats`: 3 lines `arm-linux: hello=<N> cpu=<X.XX>% mem=<X.XX>%` (and `riscv-linux`/`mips-linux`), with `hello` counts > 0 once guests have sent HELLOs.
- `sysinfo`: one line `heap_free=<N> uptime_s=<N> shell_stack_hiwat=<N> showcase_stack_hiwat=<N>`, all non-crashing positive integers.
- `links`: 3 lines `<name>: ivpos=0x... l2f_flag=<0|1> f2l_flag=<0|1> since_hello=<N>ms`.
- `can status`: one line `sr=0x... rx_frames=<N>`.

- [ ] **Step 4: Cross-check `stats` HELLO counts against the cross-domain log, and confirm they keep incrementing**

```bash
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost 'tail -5 /var/log/chimera-log/chimera-cross-domain.log'
```

Expected: `arm_count`/`riscv_count`/`mips_count` in the latest cross-domain snapshot are close to (within a few of) the `hello=` values from Step 3 — the shell doesn't perturb the counters.

Then wait ~10s and re-run `stats` to confirm the counts are still climbing while the shell is in use:

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "stats" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -5
```

Expected: each `hello=<N>` is strictly greater than the corresponding value from Step 3 — HELLO/ACK traffic is unaffected by the shell task.

- [ ] **Step 5: `loglevel` get/set**

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "loglevel" Enter
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "loglevel 0" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -10
```

Expected: first `loglevel` prints `loglevel=1 (INFO)` (the default `FREERTOS_LOG_LEVEL`). `loglevel 0` prints `loglevel=0 (VERBOSE)`, and within a few seconds previously-suppressed `[V]`-tagged lines (e.g. `[irq] ... HELLO handled via IRQ`) start appearing in the pane. Restore with:

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "loglevel 1" Enter
```

- [ ] **Step 6: Line editing (backspace) and unknown command**

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "statz" BSpace BSpace "ts" Enter
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "bogus" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -10
```

Expected: the first line dispatches as `stats` (typed `statz`, backspaced over `z` and `t`, retyped `ts` → `stats`) and produces the same 3-line output as Step 3. The second line prints `unknown command: bogus (try 'help')`.

- [ ] **Step 7: Repeat 2 more times (3 consecutive passes)**

```bash
limactl shell qemu-dev -- bash -c 'pkill qemu-system; rm -f /tmp/*.sock'
```

Then repeat Steps 1-6 two more times. All 3 runs must pass Steps 2-6 with no crashes, hangs, or `vApplicationStackOverflowHook`/`vApplicationMallocFailedHook` messages in the FreeRTOS pane.

- [ ] **Step 8: Final commit (only if Step 7 required fixes)**

If all 3 runs passed without code changes, no commit is needed — Task 5/6's commits already cover the implementation. If a bug was found and fixed during this task, commit it:

```bash
git add -A
git commit -m "fix(freertos): <describe the integration-test fix>"
```

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-13-freertos-shell-implementation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
