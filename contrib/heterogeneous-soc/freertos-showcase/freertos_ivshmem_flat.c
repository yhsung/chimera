#include "freertos_ivshmem_flat.h"

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
    *msg = link->layout->linux_to_freertos.msg;
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
    struct hsoc_hello_msg *msg = &link->layout->freertos_to_linux.msg;

    msg->magic = HSOC_HELLO_MAGIC;
    msg->version = HSOC_PROTO_VERSION;
    msg->msg_type = HSOC_MSG_ACK;
    msg->seq = seq;
    msg->sender_id = HSOC_SENDER_RISCV_FREERTOS;
    msg->ts_sec = ts_sec;
    msg->ts_nsec = ts_nsec;
    copy_text(msg->text, "ack from riscv-freertos");
    __sync_synchronize();
    link->layout->freertos_to_linux.flag = 1;
}
