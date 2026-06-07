#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"
#include "stats_proto.h"
#include "bootlog_proto.h"
#include "boot_log.h"

#define UART0_BASE 0x10000000UL
#define UART0_THR 0x0
#define UART0_LSR 0x5
#define UART0_LSR_THRE 0x20

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
static uint32_t stats_tick;
static struct bootlog_monitor bootlog;

static void uart_putc(char ch)
{
    volatile uint8_t *thr = (volatile uint8_t *)(UART0_BASE + UART0_THR);
    volatile uint8_t *lsr = (volatile uint8_t *)(UART0_BASE + UART0_LSR);

    while ((*lsr & UART0_LSR_THRE) == 0) {
    }

    *thr = (uint8_t)ch;
}

void log_uart(const char *msg)
{
    bootlog_write(&bootlog, msg);

    while (*msg != '\0') {
        if (*msg == '\n') {
            uart_putc('\r');
        }

        uart_putc(*msg++);
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
    __sync_synchronize();
    stats_shmem->generation = stats_shmem->generation + 1;
    __sync_synchronize();
    log_uart("[freertos] stats snapshot written\n");
}

static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count)
{
    struct hsoc_hello_msg hello;
    int64_t ts_sec;
    int64_t ts_nsec;

    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }

    tick_to_timestamp(&ts_sec, &ts_nsec);
    log_uart(log_message);
    freertos_ivshmem_send_ack(link, hello.seq, ts_sec, ts_nsec);
    (*count)++;
}

void log_hex32_uart(uint32_t v)
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
    log_uart(buf);
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

    log_uart("[freertos] showcase task started\n");

    /* ── Startup diagnostics ──────────────────────────────────────────────── */
    {
        log_uart("[diag] tick_rate_hz=");
        log_hex32_uart(configTICK_RATE_HZ);
        log_uart(" heap_free=");
        log_hex32_uart((uint32_t)xPortGetFreeHeapSize());
        log_uart("\n");

        log_uart("[diag] uart_base=");
        log_hex32_uart(UART0_BASE);
        log_uart(" plic_sources=");
        log_hex32_uart(21);
        log_uart("\n");

        log_uart("[diag] IVPOSITION:");
        {
            uint32_t ivp;
            ivp = arm_link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(" arm="); log_hex32_uart(ivp);
            ivp = riscv_link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(" riscv="); log_hex32_uart(ivp);
            ivp = mips_link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(" mips="); log_hex32_uart(ivp);
            ivp = bootlog.link.mmio_base[FREERTOS_IVSHMEM_IVPOSITION / sizeof(uint32_t)];
            log_uart(" bootlog="); log_hex32_uart(ivp);
        }
        log_uart("\n");

        log_uart("[diag] shmem bases: arm=");
        log_hex32_uart(IVSHMEM0_SHMEM);
        log_uart(" riscv=");
        log_hex32_uart(IVSHMEM1_SHMEM);
        log_uart(" mips=");
        log_hex32_uart(IVSHMEM2_SHMEM);
        log_uart(" stats=");
        log_hex32_uart(IVSHMEM3_SHMEM);
        log_uart(" bootlog=");
        log_hex32_uart(IVSHMEM4_SHMEM);
        log_uart("\n");
    }

    for (;;) {
        maybe_service_link(&arm_link,
                           "[freertos] received hello from arm-linux\n",
                           &arm_count);
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n",
                           &riscv_count);
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n",
                           &mips_count);

        if (++stats_tick >= 5000) {
            stats_tick = 0;
            write_stats_snapshot();
        }

        if (++diag_count >= 3000) {
            diag_count = 0;
            log_uart("[diag] arm_flag=");
            log_hex32_uart(arm_link.layout->linux_to_freertos.flag);
            log_uart(" arm_magic=");
            log_hex32_uart(arm_link.layout->linux_to_freertos.msg.magic);
            log_uart(" riscv_flag=");
            log_hex32_uart(riscv_link.layout->linux_to_freertos.flag);
            log_uart(" riscv_magic=");
            log_hex32_uart(riscv_link.layout->linux_to_freertos.msg.magic);
            log_uart(" mips_flag=");
            log_hex32_uart(mips_link.layout->linux_to_freertos.flag);
            log_uart(" mips_magic=");
            log_hex32_uart(mips_link.layout->linux_to_freertos.msg.magic);
            log_uart("\n");
        }

        /* Periodic heap/stack report every 10 seconds */
        {
            static uint32_t health_tick;
            if (++health_tick >= 10000) {
                health_tick = 0;
                log_uart("[diag] heap_free=");
                log_hex32_uart((uint32_t)xPortGetFreeHeapSize());
                log_uart(" stack_hiwat=");
                log_hex32_uart((uint32_t)uxTaskGetStackHighWaterMark(NULL));
                log_uart(" uptime_s=");
                log_hex32_uart((uint32_t)(xTaskGetTickCount() / configTICK_RATE_HZ));
                log_uart("\n");
            }
        }

        bootlog_tick(&bootlog);
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

void vApplicationMallocFailedHook(void)
{
    log_uart("[freertos] malloc failed\n");
    for (;;) {
    }
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *task_name)
{
    (void)task;
    (void)task_name;

    log_uart("[freertos] stack overflow\n");
    for (;;) {
    }
}

int main(void)
{
    BaseType_t rc;

    bootlog_init(&bootlog, IVSHMEM4_MMIO, IVSHMEM4_SHMEM, "boot-log");

    log_uart("[freertos] booting demo firmware\n");
    rc = xTaskCreate(showcase_task, "showcase", 2048, 0,
                     tskIDLE_PRIORITY + 1, 0);
    if (rc != pdPASS) {
        log_uart("[freertos] failed to create showcase task\n");
        return 1;
    }

    vTaskStartScheduler();
    log_uart("[freertos] scheduler exited unexpectedly\n");

    for (;;) {
    }
}
