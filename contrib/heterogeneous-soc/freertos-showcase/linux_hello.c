#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "hello_proto.h"

#define HSOC_BAR2_SIZE (64U * 1024U * 1024U)
#define HSOC_VENDOR_ID "0x1af4"

#ifndef HSOC_SENDER_LABEL
#define HSOC_SENDER_LABEL "linux"
#endif

#ifndef HSOC_SENDER_ID
#define HSOC_SENDER_ID HSOC_SENDER_ARM_LINUX
#endif

static bool read_first_line(const char *path, char *buf, size_t buf_size)
{
    FILE *file = fopen(path, "r");

    if (!file) {
        return false;
    }

    if (!fgets(buf, buf_size, file)) {
        fclose(file);
        return false;
    }

    fclose(file);
    buf[strcspn(buf, "\n")] = '\0';
    return true;
}

static const char *find_ivshmem_resource(void)
{
    static char resource_path[PATH_MAX];
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    DIR *devices_dir;
    struct dirent *entry;

    if (!sysfs_root) {
        sysfs_root = "/sys/bus/pci/devices";
    }

    devices_dir = opendir(sysfs_root);
    if (!devices_dir) {
        return NULL;
    }

    while ((entry = readdir(devices_dir)) != NULL) {
        char vendor_path[PATH_MAX];
        char vendor_value[32];
        char candidate_path[PATH_MAX];
        struct stat st;

        if (entry->d_name[0] == '.') {
            continue;
        }

        if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                     sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) {
            continue;
        }

        if (!read_first_line(vendor_path, vendor_value, sizeof(vendor_value))) {
            continue;
        }

        if (strcmp(vendor_value, HSOC_VENDOR_ID) != 0) {
            continue;
        }

        if (snprintf(candidate_path, sizeof(candidate_path), "%s/%s/resource2",
                     sysfs_root, entry->d_name) >= (int)sizeof(candidate_path)) {
            continue;
        }

        if (stat(candidate_path, &st) == 0) {
            strncpy(resource_path, candidate_path, sizeof(resource_path) - 1);
            resource_path[sizeof(resource_path) - 1] = '\0';
            closedir(devices_dir);
            return resource_path;
        }
    }

    closedir(devices_dir);
    return NULL;
}

static void wait_for_flag(volatile uint32_t *flag, uint32_t expected)
{
    while (*flag != expected) {
        __sync_synchronize();
    }
}

static int main_loop(struct hsoc_layout *shm)
{
    uint32_t seq = 0;

    shm->linux_to_freertos.flag = 0;
    shm->freertos_to_linux.flag = 0;

    while (true) {
        struct timespec ts_send;
        struct hsoc_hello_msg ack;

        clock_gettime(CLOCK_REALTIME, &ts_send);
        memset(&shm->linux_to_freertos.msg, 0,
               sizeof(shm->linux_to_freertos.msg));
        shm->linux_to_freertos.msg.magic = HSOC_HELLO_MAGIC;
        shm->linux_to_freertos.msg.version = HSOC_PROTO_VERSION;
        shm->linux_to_freertos.msg.msg_type = HSOC_MSG_HELLO;
        shm->linux_to_freertos.msg.seq = seq;
        shm->linux_to_freertos.msg.sender_id = HSOC_SENDER_ID;
        shm->linux_to_freertos.msg.ts_sec = ts_send.tv_sec;
        shm->linux_to_freertos.msg.ts_nsec = ts_send.tv_nsec;
        snprintf(shm->linux_to_freertos.msg.text,
                 sizeof(shm->linux_to_freertos.msg.text),
                 "hello from %s", HSOC_SENDER_LABEL);
        __sync_synchronize();
        shm->linux_to_freertos.flag = 1;

        printf("[%s] HELLO #%" PRIu32 " %s\n",
               HSOC_SENDER_LABEL, seq, shm->linux_to_freertos.msg.text);

        wait_for_flag(&shm->freertos_to_linux.flag, 1);
        ack = shm->freertos_to_linux.msg;
        __sync_synchronize();
        shm->freertos_to_linux.flag = 0;

        if (ack.magic != HSOC_HELLO_MAGIC) {
            fprintf(stderr, "[%s] Unexpected ACK magic: 0x%08" PRIx32 "\n",
                    HSOC_SENDER_LABEL, ack.magic);
            return 1;
        }

        if (ack.version != HSOC_PROTO_VERSION || ack.msg_type != HSOC_MSG_ACK) {
            fprintf(stderr,
                    "[%s] Unexpected ACK metadata: version=%u type=%u\n",
                    HSOC_SENDER_LABEL, ack.version, ack.msg_type);
            return 1;
        }

        printf("[%s] ACK   #%" PRIu32 " freertos_time=%lld.%09lld text=%s\n",
               HSOC_SENDER_LABEL, ack.seq,
               (long long)ack.ts_sec, (long long)ack.ts_nsec, ack.text);

        seq++;
        sleep(1);
    }
}

int main(int argc, char *argv[])
{
    const char *bar2_path = argc > 1 ? argv[1] : find_ivshmem_resource();
    int fd;
    struct hsoc_layout *shm;
    int rc;

    if (!bar2_path) {
        fprintf(stderr,
                "Unable to locate ivshmem BAR2 resource. Pass the path explicitly.\n");
        return 1;
    }

    fd = open(bar2_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open BAR2");
        return 1;
    }

    shm = mmap(NULL, HSOC_BAR2_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm == MAP_FAILED) {
        perror("mmap BAR2");
        close(fd);
        return 1;
    }

    printf("[%s] ivshmem BAR2 mapped at %p\n", HSOC_SENDER_LABEL, (void *)shm);
    printf("[%s] Starting hello loop (Ctrl-C to stop)...\n\n",
           HSOC_SENDER_LABEL);

    rc = main_loop(shm);
    munmap(shm, HSOC_BAR2_SIZE);
    close(fd);
    return rc;
}
