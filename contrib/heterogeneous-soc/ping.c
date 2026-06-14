/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

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

#include "ivshmem_proto.h"

#define BAR2_SIZE (64U * 1024U * 1024U)
#define IVSHMEM_VENDOR_ID "0x1af4"

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

        if (strcmp(vendor_value, IVSHMEM_VENDOR_ID) != 0) {
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

static int64_t diff_ns(const struct timespec *start, const struct timespec *end)
{
    return (end->tv_sec - start->tv_sec) * 1000000000LL +
           (end->tv_nsec - start->tv_nsec);
}

static void wait_for_flag(volatile uint32_t *flag, uint32_t expected)
{
    while (*flag != expected) {
        __sync_synchronize();
    }
}

int main(int argc, char *argv[])
{
    const char *bar2_path = argc > 1 ? argv[1] : find_ivshmem_resource();
    int fd;
    struct shm_layout *shm;
    uint32_t seq = 0;

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

    shm = mmap(NULL, BAR2_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm == MAP_FAILED) {
        perror("mmap BAR2");
        close(fd);
        return 1;
    }

    printf("[ARM] ivshmem BAR2 mapped at %p\n", (void *)shm);
    printf("[ARM] Starting ping loop (Ctrl-C to stop)...\n\n");

    while (true) {
        struct timespec ts_send;
        struct timespec ts_recv;
        struct shm_msg pong;
        int64_t rtt_ns;

        clock_gettime(CLOCK_REALTIME, &ts_send);

        shm->arm_to_riscv.msg.magic = PING_MAGIC;
        shm->arm_to_riscv.msg.seq = seq;
        shm->arm_to_riscv.msg.ts_sec = ts_send.tv_sec;
        shm->arm_to_riscv.msg.ts_nsec = ts_send.tv_nsec;
        __sync_synchronize();
        shm->arm_to_riscv.flag = 1;

        printf("[ARM] PING #%" PRIu32 " sent       %lld.%09lld\n",
               seq,
               (long long)ts_send.tv_sec,
               (long long)ts_send.tv_nsec);

        wait_for_flag(&shm->riscv_to_arm.flag, 1);

        clock_gettime(CLOCK_REALTIME, &ts_recv);
        pong = shm->riscv_to_arm.msg;
        __sync_synchronize();
        shm->riscv_to_arm.flag = 0;

        if (pong.magic != PONG_MAGIC) {
            fprintf(stderr, "[ARM] Unexpected response magic: 0x%08" PRIx32 "\n",
                    pong.magic);
            break;
        }

        rtt_ns = diff_ns(&ts_send, &ts_recv);

        printf("[ARM] PONG #%" PRIu32 " riscv_time %lld.%09lld\n",
               pong.seq,
               (long long)pong.ts_sec,
               (long long)pong.ts_nsec);
        printf("[ARM]          rtt        %lld ns (%.3f ms)\n\n",
               (long long)rtt_ns,
               (double)rtt_ns / 1000000.0);

        seq++;
        sleep(1);
    }

    munmap(shm, BAR2_SIZE);
    close(fd);
    return 1;
}
