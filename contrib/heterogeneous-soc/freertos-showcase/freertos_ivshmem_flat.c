#include "freertos_ivshmem_flat.h"

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

int freertos_ivshmem_poll_hello(struct freertos_ivshmem_link *link,
                                struct hsoc_hello_msg *msg)
{
    if (link->layout->linux_to_freertos.flag != 1) {
        return 0;
    }

    __sync_synchronize();
    shmem_read(msg, &link->layout->linux_to_freertos.msg, sizeof(*msg));
    link->layout->linux_to_freertos.flag = 0;
    __sync_synchronize();

    return msg->magic == HSOC_HELLO_MAGIC &&
           msg->version == HSOC_PROTO_VERSION &&
           msg->msg_type == HSOC_MSG_HELLO;
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
    ack.sender_id = HSOC_SENDER_RISCV_FREERTOS;
    ack.ts_sec = ts_sec;
    ack.ts_nsec = ts_nsec;
    copy_text(ack.text, "ack from riscv-freertos");

    shmem_write(&link->layout->freertos_to_linux.msg, &ack, sizeof(ack));
    __sync_synchronize();
    link->layout->freertos_to_linux.flag = 1;
}
