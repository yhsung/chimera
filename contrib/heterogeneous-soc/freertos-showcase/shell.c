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

static const char shell_banner[] =
    " ██████╗██╗  ██╗██╗███╗   ███╗███████╗██████╗  █████╗ \n"
    "██╔════╝██║  ██║██║████╗ ████║██╔════╝██╔══██╗██╔══██╗\n"
    "██║     ███████║██║██╔████╔██║█████╗  ██████╔╝███████║\n"
    "██║     ██╔══██║██║██║╚██╔╝██║██╔══╝  ██╔══██╗██╔══██║\n"
    "╚██████╗██║  ██║██║██║ ╚═╝ ██║███████╗██║  ██║██║  ██║\n"
    " ╚═════╝╚═╝  ╚═╝╚═╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝\n";

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

    shell_print(shell_banner);
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
