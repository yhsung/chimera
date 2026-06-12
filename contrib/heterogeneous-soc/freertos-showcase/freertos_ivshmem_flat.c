#include "freertos_ivshmem_flat.h"

#include "FreeRTOS.h"
#include "task.h"

/*
 * log_uart is defined in freertos_main.c; used here for diagnostic output.
 */
extern void log_uart(uint32_t level, const char *msg);

/*
 * Volatile byte helpers prevent GCC's loop-invariant code motion (LICM) from
 * hoisting reads from or writes to the ivshmem shared-memory region out of the
 * poll loop.  Without these, GCC -O2 can treat a non-volatile struct read
 * through a non-volatile pointer as loop-invariant, reading the msg once
 * (returning all-zeros on the first iteration before Linux has written
 * anything) and reusing the stale cached value on every subsequent iteration.
 * The volatile flag field is already protected against this, but the msg body
 * fields are not — they need the same treatment.
 */

static void log_hex32(uint32_t level, uint32_t v)
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

static void shmem_read(void *dst, const volatile void *src, uint32_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    uint32_t i;

    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static void shmem_write(volatile void *dst, const void *src, uint32_t n)
{
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    uint32_t i;

    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static void copy_text(char *dest, const char *src)
{
    uint32_t i;

    for (i = 0; i + 1 < HSOC_TEXT_LEN && src[i] != '\0'; i++) {
        dest[i] = src[i];
    }

    dest[i] = '\0';

    for (i++; i < HSOC_TEXT_LEN; i++) {
        dest[i] = '\0';
    }
}

/*
 * ISR-safe tick-to-timestamp conversion.
 * Uses xTaskGetTickCountFromISR() instead of xTaskGetTickCount() because
 * we run in interrupt context (safe to call at task level too, but we keep
 * the ISR variant self-contained to avoid coupling with freertos_main.c).
 */
static void tick_to_timestamp_isr(int64_t *ts_sec, int64_t *ts_nsec)
{
    TickType_t ticks = xTaskGetTickCountFromISR();
    const int64_t ns_per_tick = 1000000000LL / configTICK_RATE_HZ;

    *ts_sec = ticks / configTICK_RATE_HZ;
    *ts_nsec = (ticks % configTICK_RATE_HZ) * ns_per_tick;
}

/*
 * Called from vApplicationIRQHandler on GIC SPI 1/2/3 (INTID 33/34/35) for
 * the arm-linux/riscv-linux/mips-linux links respectively.
 * Reads the HELLO from the link's shared memory, sends ACK, rings doorbell.
 * Follows the same volatile-byte-access rules as the poll path.
 *
 * This QEMU ivshmem-flat model (hw/misc/ivshmem-flat.c) raises the GIC IRQ
 * unconditionally whenever the peer signals our eventfd — INTSTATUS/INTMASK
 * are reserved/no-op in this device revision, so the shared flag below is
 * the only real gate.
 */
void freertos_ivshmem_isr(struct freertos_ivshmem_link *link,
                          uint32_t *count,
                          uint32_t *cpu_pct,
                          uint32_t *mem_pct,
                          uint32_t *last_hello_ticks,
                          uint32_t doorbell_ring_value)
{
    struct hsoc_hello_msg msg;
    int64_t ts_sec, ts_nsec;

    __sync_synchronize();
    if (link->layout->linux_to_freertos.flag == 1) {
        /* Volatile byte-loop copy of the message from shared memory */
        shmem_read(&msg, &link->layout->linux_to_freertos.msg, sizeof(msg));

        if (msg.magic == HSOC_HELLO_MAGIC &&
            msg.version == HSOC_PROTO_VERSION &&
            msg.msg_type == HSOC_MSG_HELLO) {

            /* Build and send ACK with ISR-safe timestamp */
            tick_to_timestamp_isr(&ts_sec, &ts_nsec);
            freertos_ivshmem_send_ack(link, msg.seq, ts_sec, ts_nsec);

            /* Update the caller's stats/heartbeat bookkeeping, mirroring the
             * old poll path's behavior. The ISR now always wins the
             * flag-clear race, so the poll path never observes a HELLO on
             * this link and these counters would otherwise stay frozen at
             * zero. */
            (*count)++;
            *cpu_pct = msg.cpu_pct_x100;
            *mem_pct = msg.mem_used_pct_x100;
            *last_hello_ticks = xTaskGetTickCountFromISR();

            /* Ring doorbell (write doorbell_ring_value = (peer_id << 16) |
             * vector to DOORBELL reg @ offset 0xc) to notify the Linux guest
             * that the ACK is ready. FreeRTOS joins each per-channel
             * ivshmem-server first and is peer 0 (confirmed via IVPOSITION);
             * the Linux guest is peer 1, vector 0 — same convention as
             * boot_log.c's doorbell ring. The caller supplies
             * doorbell_ring_value per link. */
            link->mmio_base[FREERTOS_IVSHMEM_DOORBELL / sizeof(uint32_t)] = doorbell_ring_value;

            log_uart(HSOC_LOG_INFO, "[irq] ");
            log_uart(HSOC_LOG_INFO, link->name);
            log_uart(HSOC_LOG_INFO, ": HELLO handled via IRQ\n");
        } else {
            log_uart(HSOC_LOG_ERROR, "[irq] ");
            log_uart(HSOC_LOG_ERROR, link->name);
            log_uart(HSOC_LOG_ERROR, ": validation failed: magic=");
            log_hex32(HSOC_LOG_ERROR, msg.magic);
            log_uart(HSOC_LOG_ERROR, " ver=");
            log_hex32(HSOC_LOG_ERROR, msg.version);
            log_uart(HSOC_LOG_ERROR, " type=");
            log_hex32(HSOC_LOG_ERROR, msg.msg_type);
            log_uart(HSOC_LOG_ERROR, "\n");
        }

        /* Acknowledge the HELLO by clearing the flag */
        link->layout->linux_to_freertos.flag = 0;
        __sync_synchronize();
    }
}

void freertos_ivshmem_init(struct freertos_ivshmem_link *link,
                           uintptr_t mmio_base,
                           uintptr_t shmem_base,
                           const char *name)
{
    link->mmio_base = (volatile uint32_t *)mmio_base;
    link->layout = (struct hsoc_layout *)shmem_base;
    link->name = name;
    link->layout->linux_to_freertos.flag = 0;
    link->layout->freertos_to_linux.flag = 0;
}

void freertos_ivshmem_send_ack(struct freertos_ivshmem_link *link,
                               uint32_t seq,
                               int64_t ts_sec,
                               int64_t ts_nsec)
{
    struct hsoc_hello_msg ack;

    ack.magic = HSOC_HELLO_MAGIC;
    ack.version = HSOC_PROTO_VERSION;
    ack.msg_type = HSOC_MSG_ACK;
    ack.seq = seq;
    ack.sender_id = HSOC_SENDER_R52_FREERTOS;
    ack.ts_sec = ts_sec;
    ack.ts_nsec = ts_nsec;
    copy_text(ack.text, "ack from r52-freertos");

    shmem_write(&link->layout->freertos_to_linux.msg, &ack, sizeof(ack));
    __sync_synchronize();
    link->layout->freertos_to_linux.flag = 1;
    __sync_synchronize();
}
