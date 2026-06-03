#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "freertos_ivshmem_flat.h"

#define UART0_BASE 0x10000000UL
#define UART0_THR 0x0
#define UART0_LSR 0x5
#define UART0_LSR_THRE 0x20

#define IVSHMEM0_MMIO 0x30000000UL
#define IVSHMEM0_SHMEM 0x31000000UL
#define IVSHMEM1_MMIO 0x35000000UL
#define IVSHMEM1_SHMEM 0x36000000UL

static struct freertos_ivshmem_link arm_link;
static struct freertos_ivshmem_link riscv_link;

static void uart_putc(char ch)
{
    volatile uint8_t *thr = (volatile uint8_t *)(UART0_BASE + UART0_THR);
    volatile uint8_t *lsr = (volatile uint8_t *)(UART0_BASE + UART0_LSR);

    while ((*lsr & UART0_LSR_THRE) == 0) {
    }

    *thr = (uint8_t)ch;
}

static void log_uart(const char *msg)
{
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

static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message)
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
}

static void showcase_task(void *opaque)
{
    (void)opaque;

    freertos_ivshmem_init(&arm_link, IVSHMEM0_MMIO, IVSHMEM0_SHMEM,
                          "arm-linux");
    freertos_ivshmem_init(&riscv_link, IVSHMEM1_MMIO, IVSHMEM1_SHMEM,
                          "riscv-linux");

    log_uart("[freertos] showcase task started\n");

    for (;;) {
        maybe_service_link(&arm_link,
                           "[freertos] received hello from arm-linux\n");
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n");
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
