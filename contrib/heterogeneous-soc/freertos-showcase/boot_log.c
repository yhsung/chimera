#include <stddef.h>

#include "boot_log.h"

extern void log_uart(const char *msg);

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
        return 0;
    }

    int all_done = 1;
    for (int i = 0; i < (int)BOOTLOG_NUM_GUESTS; i++) {
        __sync_synchronize();
        if (m->header->guests[i].status != HSOC_BOOT_COMPLETE) {
            all_done = 0;
        }
    }

    if (m->boot_tick >= BOOTLOG_TIMEOUT_TICKS) {
        log_uart("[bootlog] timeout reached (600 s). Ringing doorbell.\n");
        all_done = 1;
    }

    if (!all_done) {
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

    log_uart("[bootlog] doorbell rung, generation incremented\n");

    m->armed = 0;
    return 1;
}
