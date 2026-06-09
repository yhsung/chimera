#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"
#include "stats_proto.h"
#include "bootlog_proto.h"
#include "boot_log.h"

/* Minimum log severity for output. Messages below this level are suppressed.
 * Override at build time with -DFREERTOS_LOG_LEVEL=HSOC_LOG_VERBOSE etc. */
#ifndef FREERTOS_LOG_LEVEL
#define FREERTOS_LOG_LEVEL HSOC_LOG_VERBOSE
#endif

#define UART0_BASE 0x10000000UL
#define PL011_DR   0x00    /* data register */
#define PL011_FR   0x18    /* flag register */
#define PL011_FR_TXFF 0x20 /* transmit FIFO full */

#define IVSHMEM0_MMIO 0x30000000UL
#define IVSHMEM0_SHMEM 0x31000000UL
#define IVSHMEM1_MMIO 0x35000000UL
#define IVSHMEM1_SHMEM 0x36000000UL
#define IVSHMEM2_MMIO  0x3A000000UL
#define IVSHMEM2_SHMEM 0x3B000000UL
#define IVSHMEM3_MMIO  0x3F000000UL
#define IVSHMEM3_SHMEM 0x40000000UL
#define IVSHMEM4_MMIO  0x44000000UL
#define IVSHMEM4_SHMEM 0x45000000UL

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

static void uart_putc(char ch)
{
    volatile uint32_t *dr = (volatile uint32_t *)(UART0_BASE + PL011_DR);
    volatile uint32_t *fr = (volatile uint32_t *)(UART0_BASE + PL011_FR);

    while ((*fr & PL011_FR_TXFF) != 0) {
    }

    *dr = (uint32_t)(uint8_t)ch;
}

static char *utoa_dec(char *buf, uint32_t val)
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

void log_uart(uint32_t level, const char *msg)
{
    char prefix[40];
    TickType_t ticks;
    uint32_t msec;
    char *p;
    const char *m;
    const char *tag;

    /* Suppress messages below the configured log level */
    if (level < FREERTOS_LOG_LEVEL) {
        return;
    }

    switch (level) {
    case HSOC_LOG_ERROR:   tag = "E"; break;
    case HSOC_LOG_WARN:    tag = "W"; break;
    case HSOC_LOG_VERBOSE: tag = "V"; break;
    default:               tag = "I"; break;
    }

    if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) {
        ticks = xTaskGetTickCount();
    } else {
        ticks = 0;
    }

    msec = (ticks % configTICK_RATE_HZ) * 1000U / configTICK_RATE_HZ;

    p = prefix;
    p[0] = '[';
    p = utoa_dec(p + 1, ticks / configTICK_RATE_HZ);
    p[0] = '.';
    p[1] = '0' + (msec / 100) % 10;
    p[2] = '0' + (msec / 10) % 10;
    p[3] = '0' + msec % 10;
    p[4] = ']';
    p[5] = ' ';
    p[6] = '[';
    p[7] = tag[0];
    p[8] = ']';
    p[9] = ' ';
    p[10] = '\0';

    bootlog_write(&bootlog, prefix);
    bootlog_write(&bootlog, msg);

    p = prefix;

    while (*p != '\0') {
        if (*p == '\n') {
            uart_putc('\r');
        }

        uart_putc(*p++);
    }

    m = msg;

    while (*m != '\0') {
        if (*m == '\n') {
            uart_putc('\r');
        }

        uart_putc(*m++);
    }
}

static void tick_to_timestamp(int64_t *ts_sec, int64_t *ts_nsec)
{
    TickType_t ticks = xTaskGetTickCount();
    const int64_t ns_per_tick = 1000000000LL / configTICK_RATE_HZ;

    *ts_sec = ticks / configTICK_RATE_HZ;
    *ts_nsec = (ticks % configTICK_RATE_HZ) * ns_per_tick;
}

static void write_stats_snapshot(void)
{
    int64_t ts_sec, ts_nsec;

    stats_shmem->arm_count   = arm_count;
    stats_shmem->riscv_count = riscv_count;
    stats_shmem->mips_count  = mips_count;
    tick_to_timestamp(&ts_sec, &ts_nsec);
    stats_shmem->tick_sec  = ts_sec;
    stats_shmem->tick_nsec = ts_nsec;
    stats_shmem->arm_cpu_pct_x100   = arm_cpu_pct;
    stats_shmem->arm_mem_pct_x100   = arm_mem_pct;
    stats_shmem->riscv_cpu_pct_x100 = riscv_cpu_pct;
    stats_shmem->riscv_mem_pct_x100 = riscv_mem_pct;
    stats_shmem->mips_cpu_pct_x100  = mips_cpu_pct;
    stats_shmem->mips_mem_pct_x100  = mips_mem_pct;
    __sync_synchronize();
    stats_shmem->generation = stats_shmem->generation + 1;
    __sync_synchronize();
    log_uart(HSOC_LOG_VERBOSE, "[freertos] stats snapshot written\n");
}

static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count,
                               uint32_t *cpu_pct,
                               uint32_t *mem_pct,
                               TickType_t *last_hello_ticks)
{
    struct hsoc_hello_msg hello;
    int64_t ts_sec;
    int64_t ts_nsec;

    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }

    tick_to_timestamp(&ts_sec, &ts_nsec);
    log_uart(HSOC_LOG_VERBOSE, log_message);
    freertos_ivshmem_send_ack(link, hello.seq, ts_sec, ts_nsec);
    (*count)++;
    *cpu_pct = hello.cpu_pct_x100;
    *mem_pct = hello.mem_used_pct_x100;
    *last_hello_ticks = xTaskGetTickCount();
}

void log_hex32_uart(uint32_t level, uint32_t v)
{
    static const char hex[] = "0123456789abcdef";
    char buf[11];
    buf[0] = '0'; buf[1] = 'x';
    buf[2] = hex[(v >> 28) & 0xf];
    buf[3] = hex[(v >> 24) & 0xf];
    buf[4] = hex[(v >> 20) & 0xf];
    buf[5] = hex[(v >> 16) & 0xf];
    buf[6] = hex[(v >> 12) & 0xf];
    buf[7] = hex[(v >> 8) & 0xf];
    buf[8] = hex[(v >> 4) & 0xf];
    buf[9] = hex[v & 0xf];
    buf[10] = '\0';
    log_uart(level, buf);
}

/* ── Cortex-R52 generic-timer tick + GICv2 IRQ dispatch ──────────────────── */
#define R52_TICK_INTID            30U      /* NS-EL1 physical timer PPI */
#define GICD_BASE                 0x08000000UL
#define GICD_CTLR                 0x000U
#define GICD_ISENABLER            0x100U    /* +(intid/32)*4 */
#define GICD_IPRIORITYR           0x400U    /* +intid */
#define GICC_BASE                 0x08010000UL
#define GICC_CTLR                 0x000U

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

    /* Enable the GIC CPU interface (group 0, non-secure). */
    {
        volatile uint32_t *gicc_ctlr = (volatile uint32_t *)(GICC_BASE + GICC_CTLR);
        *gicc_ctlr |= 1U; /* EnableGrp0 */
    }

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

static void showcase_task(void *opaque)
{
    (void)opaque;
    uint32_t diag_count = 0;

    freertos_ivshmem_init(&arm_link,  IVSHMEM0_MMIO, IVSHMEM0_SHMEM, "arm-linux");
    freertos_ivshmem_init(&riscv_link, IVSHMEM1_MMIO, IVSHMEM1_SHMEM, "riscv-linux");
    freertos_ivshmem_init(&mips_link,  IVSHMEM2_MMIO, IVSHMEM2_SHMEM, "mips-linux");

    stats_shmem->magic      = HSOC_STATS_MAGIC;
    stats_shmem->generation = 0;
    __sync_synchronize();

    log_uart(HSOC_LOG_INFO, "[freertos] showcase task started\n");

    /* ── Startup diagnostics ──────────────────────────────────────────────── */
    {
        log_uart(HSOC_LOG_VERBOSE, "[diag] tick_rate_hz=");
        log_hex32_uart(HSOC_LOG_VERBOSE, configTICK_RATE_HZ);
        log_uart(HSOC_LOG_VERBOSE, " heap_free=");
        log_hex32_uart(HSOC_LOG_VERBOSE, (uint32_t)xPortGetFreeHeapSize());
        log_uart(HSOC_LOG_VERBOSE, "\n");

        log_uart(HSOC_LOG_VERBOSE, "[diag] uart_base=");
        log_hex32_uart(HSOC_LOG_VERBOSE, UART0_BASE);
        log_uart(HSOC_LOG_VERBOSE, " gic_spis=");
        log_hex32_uart(HSOC_LOG_VERBOSE, 6);
        log_uart(HSOC_LOG_VERBOSE, "\n");

        log_uart(HSOC_LOG_VERBOSE, "[diag] IVPOSITION:");
        {
            uint32_t ivp;
            ivp = arm_link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(HSOC_LOG_VERBOSE, " arm="); log_hex32_uart(HSOC_LOG_VERBOSE, ivp);
            ivp = riscv_link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(HSOC_LOG_VERBOSE, " riscv="); log_hex32_uart(HSOC_LOG_VERBOSE, ivp);
            ivp = mips_link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(HSOC_LOG_VERBOSE, " mips="); log_hex32_uart(HSOC_LOG_VERBOSE, ivp);
            ivp = bootlog.link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(HSOC_LOG_VERBOSE, " bootlog="); log_hex32_uart(HSOC_LOG_VERBOSE, ivp);
        }
        log_uart(HSOC_LOG_VERBOSE, "\n");

        log_uart(HSOC_LOG_VERBOSE, "[diag] shmem bases: arm=");
        log_hex32_uart(HSOC_LOG_VERBOSE, IVSHMEM0_SHMEM);
        log_uart(HSOC_LOG_VERBOSE, " riscv=");
        log_hex32_uart(HSOC_LOG_VERBOSE, IVSHMEM1_SHMEM);
        log_uart(HSOC_LOG_VERBOSE, " mips=");
        log_hex32_uart(HSOC_LOG_VERBOSE, IVSHMEM2_SHMEM);
        log_uart(HSOC_LOG_VERBOSE, " stats=");
        log_hex32_uart(HSOC_LOG_VERBOSE, IVSHMEM3_SHMEM);
        log_uart(HSOC_LOG_VERBOSE, " bootlog=");
        log_hex32_uart(HSOC_LOG_VERBOSE, IVSHMEM4_SHMEM);
        log_uart(HSOC_LOG_VERBOSE, "\n");
    }

    for (;;) {
        maybe_service_link(&arm_link,
                           "[freertos] received hello from arm-linux\n",
                           &arm_count, &arm_cpu_pct, &arm_mem_pct, &arm_last_hello_ticks);
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n",
                           &riscv_count, &riscv_cpu_pct, &riscv_mem_pct, &riscv_last_hello_ticks);
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n",
                           &mips_count, &mips_cpu_pct, &mips_mem_pct, &mips_last_hello_ticks);

        if (++stats_tick >= 5000) {
            stats_tick = 0;
            write_stats_snapshot();

            /* Heartbeat: monitor after all guests have booted */
            {
                static uint8_t boot_armed;
                TickType_t now = xTaskGetTickCount();

                if (!boot_armed) {
                    if (bootlog_all_booted(&bootlog)) {
                        boot_armed = 1;
                        arm_last_hello_ticks = now;
                        riscv_last_hello_ticks = now;
                        mips_last_hello_ticks = now;
                    }
                }

                if (boot_armed) {
                    if (now - arm_last_hello_ticks > pdMS_TO_TICKS(30000)) {
                        log_uart(HSOC_LOG_ERROR,
                                 "[freertos] heartbeat: arm-linux silent >30s\n");
                    }
                    if (now - riscv_last_hello_ticks > pdMS_TO_TICKS(30000)) {
                        log_uart(HSOC_LOG_ERROR,
                                 "[freertos] heartbeat: riscv-linux silent >30s\n");
                    }
                    if (now - mips_last_hello_ticks > pdMS_TO_TICKS(30000)) {
                        log_uart(HSOC_LOG_ERROR,
                                 "[freertos] heartbeat: mips-linux silent >30s\n");
                    }
                }
            }
        }

#if defined(FREERTOS_DIAG_LOOP)
        if (++diag_count >= 3000) {
            diag_count = 0;
            log_uart(HSOC_LOG_VERBOSE, "[diag] arm_flag=");
            log_hex32_uart(HSOC_LOG_VERBOSE, arm_link.layout->linux_to_freertos.flag);
            log_uart(HSOC_LOG_VERBOSE, " arm_magic=");
            log_hex32_uart(HSOC_LOG_VERBOSE, arm_link.layout->linux_to_freertos.msg.magic);
            log_uart(HSOC_LOG_VERBOSE, " riscv_flag=");
            log_hex32_uart(HSOC_LOG_VERBOSE, riscv_link.layout->linux_to_freertos.flag);
            log_uart(HSOC_LOG_VERBOSE, " riscv_magic=");
            log_hex32_uart(HSOC_LOG_VERBOSE, riscv_link.layout->linux_to_freertos.msg.magic);
            log_uart(HSOC_LOG_VERBOSE, " mips_flag=");
            log_hex32_uart(HSOC_LOG_VERBOSE, mips_link.layout->linux_to_freertos.flag);
            log_uart(HSOC_LOG_VERBOSE, " mips_magic=");
            log_hex32_uart(HSOC_LOG_VERBOSE, mips_link.layout->linux_to_freertos.msg.magic);
            log_uart(HSOC_LOG_VERBOSE, "\n");
        }
#endif // #if defined(FREERTOS_DIAG_LOOP)

        /* Periodic heap/stack report every 10 seconds */
        {
            static uint32_t health_tick;
            if (++health_tick >= 10000) {
                health_tick = 0;
                log_uart(HSOC_LOG_VERBOSE, "[diag] heap_free=");
                log_hex32_uart(HSOC_LOG_VERBOSE, (uint32_t)xPortGetFreeHeapSize());
                log_uart(HSOC_LOG_VERBOSE, " stack_hiwat=");
                log_hex32_uart(HSOC_LOG_VERBOSE, (uint32_t)uxTaskGetStackHighWaterMark(NULL));
                log_uart(HSOC_LOG_VERBOSE, " uptime_s=");
                log_hex32_uart(HSOC_LOG_VERBOSE, (uint32_t)(xTaskGetTickCount() / configTICK_RATE_HZ));
                log_uart(HSOC_LOG_VERBOSE, "\n");
            }
        }

        bootlog_tick(&bootlog);
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

void vApplicationMallocFailedHook(void)
{
    log_uart(HSOC_LOG_ERROR, "[freertos] malloc failed\n");
    for (;;) {
    }
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *task_name)
{
    (void)task;
    (void)task_name;

    log_uart(HSOC_LOG_ERROR, "[freertos] stack overflow\n");
    for (;;) {
    }
}

int main(void)
{
    BaseType_t rc;

    bootlog_init(&bootlog, IVSHMEM4_MMIO, IVSHMEM4_SHMEM, "boot-log");

    log_uart(HSOC_LOG_INFO, "[freertos] booting demo firmware\n");
    rc = xTaskCreate(showcase_task, "showcase", 2048, 0,
                     tskIDLE_PRIORITY + 1, 0);
    if (rc != pdPASS) {
        log_uart(HSOC_LOG_ERROR, "[freertos] failed to create showcase task\n");
        return 1;
    }

    vTaskStartScheduler();
    log_uart(HSOC_LOG_ERROR, "[freertos] scheduler exited unexpectedly\n");

    for (;;) {
    }
}
