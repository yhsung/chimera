#include <stddef.h>

#include "boot_log.h"

extern void log_uart(uint32_t level, const char *msg);
extern void log_hex32_uart(uint32_t level, uint32_t v);

#define BOOTLOG_TIMEOUT_TICKS 600000  /* 600 s at 1 ms/tick */

void bootlog_init(struct bootlog_monitor *m,
                  uintptr_t mmio_base, uintptr_t shmem_base,
                  const char *name)
{
    m->link.mmio_base = (volatile uint32_t *)mmio_base;
    m->link.layout    = NULL;   /* not used; bootlog has its own header */
    m->link.name      = name;
    m->header         = (volatile struct hsoc_bootlog_header *)shmem_base;
    m->boot_tick      = 0;
    m->armed          = 1;
    m->initialized    = 1;

    /* Initialize header magic and peer sentinel before any guest reads it */
    m->header->magic = BOOTLOG_MAGIC;
    __sync_synchronize();
    m->header->collector_peer_id = BOOTLOG_COLLECTOR_PEER_UNSET;
    __sync_synchronize();

    /* FreeRTOS itself is booted immediately — mark its slot so bootlog_tick()
     * doesn't wait for a FreeRTOS writer that doesn't exist. */
    m->header->guests[HSOC_GUEST_FREERTOS].status = HSOC_BOOT_COMPLETE;
    __sync_synchronize();

    m->slot_offset = 0;
}

int bootlog_tick(struct bootlog_monitor *m)
{
    if (!m->armed || !m->initialized) {
        return 0;
    }

    m->boot_tick++;

    __sync_synchronize();
    uint32_t peer_id = m->header->collector_peer_id;

    if (peer_id == BOOTLOG_COLLECTOR_PEER_UNSET || peer_id > 0xFFFF) {
        /* Collector not yet connected — log once per second */
        if ((m->boot_tick % 1000) == 0) {
            log_uart(HSOC_LOG_WARN, "[bootlog] waiting for collector (collector_peer_id still UNSET)\n");
        }
        return 0;
    }

    /* Collector just connected — log the peer ID once */
    {
        static uint8_t collector_logged;
        if (!collector_logged) {
            collector_logged = 1;
            log_uart(HSOC_LOG_INFO, "[bootlog] collector connected, peer_id=");
            log_hex32_uart(HSOC_LOG_INFO, peer_id);
            log_uart(HSOC_LOG_INFO, "\n");
        }
    }

    int all_done = 1;
    static const char *guest_labels[] = {
        [HSOC_GUEST_ARM_LINUX]   = "arm",
        [HSOC_GUEST_RISCV_LINUX] = "riscv",
        [HSOC_GUEST_MIPS_LINUX]  = "mips",
        [HSOC_GUEST_FREERTOS]    = "freertos",
    };
    for (int i = 0; i < (int)BOOTLOG_NUM_GUESTS; i++) {
        __sync_synchronize();
        if (m->header->guests[i].status != HSOC_BOOT_COMPLETE) {
            all_done = 0;
        }
    }

    if (m->boot_tick >= BOOTLOG_TIMEOUT_TICKS) {
        log_uart(HSOC_LOG_WARN, "[bootlog] timeout reached (600 s). Ringing doorbell.\n");
        all_done = 1;
    }

    if (!all_done) {
        /* Log remaining guests every 5 seconds */
        if ((m->boot_tick % 5000) == 0) {
            log_uart(HSOC_LOG_WARN, "[bootlog] waiting for guests:");
            for (int i = 0; i < (int)BOOTLOG_NUM_GUESTS; i++) {
                __sync_synchronize();
                if (m->header->guests[i].status != HSOC_BOOT_COMPLETE) {
                    log_uart(HSOC_LOG_WARN, " ");
                    log_uart(HSOC_LOG_WARN, guest_labels[i]);
                }
            }
            log_uart(HSOC_LOG_WARN, "\n");
        }
        return 0;
    }

    /* Increment generation so boot-collector knows to harvest logs */
    m->header->generation++;
    __sync_synchronize();

    /* Ring doorbell: encode (peer_id << 16) | vector 0
     * mmio_base is volatile uint32_t *; DOORBELL register is at byte offset 0xc (index 3) */
    uint32_t doorbell_val = (peer_id << 16) | 0U;
    __sync_synchronize();
    m->link.mmio_base[FREERTOS_IVSHMEM_DOORBELL / sizeof(uint32_t)] = doorbell_val;
    __sync_synchronize();

    log_uart(HSOC_LOG_INFO, "[bootlog] doorbell rung, generation incremented\n");

    m->armed = 0;
    return 1;
}

/* ── FreeRTOS boot-log writer ──────────────────────────────────────────────── */

static void shmem_write32(volatile void *addr, uint32_t val)
{
    volatile uint8_t *d = (volatile uint8_t *)addr;
    d[0] = (uint8_t)(val >> 0);
    d[1] = (uint8_t)(val >> 8);
    d[2] = (uint8_t)(val >> 16);
    d[3] = (uint8_t)(val >> 24);
}

static void shmem_write_buf(volatile void *dst, const void *src, size_t n)
{
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

void bootlog_write(struct bootlog_monitor *m, const char *msg)
{
    if (!m->initialized) {
        return;
    }

    volatile uint8_t *slot = (volatile uint8_t *)m->header
                           + BOOTLOG_SLOT_FREERTOS;
    size_t len = 0;

    while (msg[len] != '\0') {
        len++;
    }
    if (len == 0) {
        return;
    }

    if (m->slot_offset >= BOOTLOG_SLOT_SIZE) {
        static uint8_t truncated;
        if (!truncated) {
            truncated = 1;
            log_uart(HSOC_LOG_ERROR, "[bootlog] FreeRTOS slot truncated\n");
        }
        return;
    }

    size_t writable = BOOTLOG_SLOT_SIZE - m->slot_offset;
    if (len > writable) {
        len = writable;
    }

    shmem_write_buf(slot + m->slot_offset, msg, len);
    m->slot_offset += (uint32_t)len;
    __sync_synchronize();
    shmem_write32(&m->header->guests[HSOC_GUEST_FREERTOS].offset,
                  m->slot_offset);
    __sync_synchronize();
}
