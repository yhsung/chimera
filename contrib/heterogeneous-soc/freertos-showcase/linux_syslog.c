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

#define HSOC_BAR2_SIZE      (64U * 1024U * 1024U)
#define HSOC_VENDOR_ID      "0x1af4"
#define HSOC_STATS_MAGIC    0x53544154U
#define HSOC_BOOTLOG_MAGIC  0x424C5447U  /* "BLTG" — boot-log channel, skip */

#ifndef HSOC_SENDER_LABEL
#define HSOC_SENDER_LABEL "arm-linux"
#endif

#ifndef HSOC_SENDER_ID
#define HSOC_SENDER_ID HSOC_SENDER_ARM_LINUX
#endif

static bool read_first_line(const char *path, char *buf, size_t n)
{
    FILE *f = fopen(path, "r");
    if (!f) return false;
    bool ok = fgets(buf, n, f) != NULL;
    fclose(f);
    if (ok) buf[strcspn(buf, "\n")] = '\0';
    return ok;
}

static void read_loadavg_fixed(unsigned int *ld_int, unsigned int *ld_frac)
{
    char line[64];
    *ld_int = 0;
    *ld_frac = 0;
    if (!read_first_line("/proc/loadavg", line, sizeof(line)))
        return;
    unsigned int i = 0, f = 0;
    int n = sscanf(line, "%u.%u", &i, &f);
    if (n >= 1) {
        *ld_int = i;
        if (n >= 2) {
            while (f >= 100) f /= 10;
            while (f > 0 && f < 10) f *= 10;
            *ld_frac = f;
        }
    }
}

static unsigned int read_memfree_mb(void)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    char line[128];
    unsigned long kb = 0;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "MemFree: %lu kB", &kb) == 1) break;
    }
    fclose(f);
    return (unsigned int)(kb / 1024);
}

static unsigned int read_uptime_sec(void)
{
    char line[64];
    unsigned long v = 0;
    if (read_first_line("/proc/uptime", line, sizeof(line)))
        sscanf(line, "%lu", &v);
    return (unsigned int)v;
}

static void build_sysinfo_text(char *buf, size_t n)
{
    unsigned int ld_int, ld_frac;
    read_loadavg_fixed(&ld_int, &ld_frac);
    snprintf(buf, n, "ld=%u.%02u mf=%uM up=%us",
             ld_int, ld_frac, read_memfree_mb(), read_uptime_sec());
}

/*
 * Volatile byte helpers prevent NEON/SIMD instructions on PCI BAR2 (non-cacheable
 * device memory), which SIGBUS on ARM.
 */
static void shm_write(volatile void *dst, const void *src, size_t n)
{
    volatile uint8_t *d = (volatile uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

static void shm_read(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

static void wait_for_flag(volatile uint32_t *flag, uint32_t expected)
{
    while (true) {
        __sync_synchronize();
        if (*flag == expected) break;
    }
}

static const char *find_ivshmem_resource(void)
{
    static char resource_path[PATH_MAX];
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) sysfs_root = "/sys/bus/pci/devices";

    DIR *dir = opendir(sysfs_root);
    if (!dir) return NULL;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char vendor_path[PATH_MAX], vendor_val[32];
        if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                     sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) continue;
        if (!read_first_line(vendor_path, vendor_val, sizeof(vendor_val))) continue;
        if (strcmp(vendor_val, HSOC_VENDOR_ID) != 0) continue;

        char candidate[PATH_MAX];
        if (snprintf(candidate, sizeof(candidate), "%s/%s/resource2",
                     sysfs_root, entry->d_name) >= (int)sizeof(candidate)) continue;

        struct stat st;
        if (stat(candidate, &st) != 0) continue;

        int fd = open(candidate, O_RDONLY | O_SYNC);
        if (fd < 0) continue;
        void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) continue;

        uint32_t magic;
        shm_read(&magic, p, sizeof(magic));
        __sync_synchronize();
        munmap(p, 4096);

        if (magic == HSOC_STATS_MAGIC || magic == HSOC_BOOTLOG_MAGIC) continue;

        strncpy(resource_path, candidate, sizeof(resource_path) - 1);
        resource_path[sizeof(resource_path) - 1] = '\0';
        closedir(dir);
        return resource_path;
    }
    closedir(dir);
    return NULL;
}

static int main_loop(struct hsoc_layout *shm, unsigned int interval)
{
    uint32_t seq = 0;
    uint32_t hello_count = 0;
    uint32_t ack_count = 0;
    shm->linux_to_freertos.flag = 0;
    shm->freertos_to_linux.flag = 0;
    __sync_synchronize();

    while (true) {
        struct timespec ts;
        struct hsoc_hello_msg msg;
        struct hsoc_hello_msg ack;

        clock_gettime(CLOCK_REALTIME, &ts);
        memset(&msg, 0, sizeof(msg));
        msg.magic     = HSOC_HELLO_MAGIC;
        msg.version   = HSOC_PROTO_VERSION;
        msg.msg_type  = HSOC_MSG_HELLO;
        msg.seq       = seq;
        msg.sender_id = HSOC_SENDER_ID;
        msg.ts_sec    = ts.tv_sec;
        msg.ts_nsec   = ts.tv_nsec;
        build_sysinfo_text(msg.text, sizeof(msg.text));

        shm_write(&shm->linux_to_freertos.msg, &msg, sizeof(msg));
        __sync_synchronize();
        shm->linux_to_freertos.flag = 1;
        hello_count++;

        wait_for_flag(&shm->freertos_to_linux.flag, 1);
        shm_read(&ack, &shm->freertos_to_linux.msg, sizeof(ack));
        __sync_synchronize();
        shm->freertos_to_linux.flag = 0;
        ack_count++;

        if (ack.magic != HSOC_HELLO_MAGIC) {
            fprintf(stderr, "[%s] bad ACK magic: 0x%08" PRIx32 "\n",
                    HSOC_SENDER_LABEL, ack.magic);
            return 1;
        }
        if (ack.version != HSOC_PROTO_VERSION || ack.msg_type != HSOC_MSG_ACK) {
            fprintf(stderr, "[%s] bad ACK: version=%u type=%u\n",
                    HSOC_SENDER_LABEL, ack.version, ack.msg_type);
            return 1;
        }

        /* Print summary every 5 sends */
        if (hello_count % 5 == 0) {
            printf("[%s] SYSINFO #%" PRIu32 " %s\n", HSOC_SENDER_LABEL, seq, msg.text);
            printf("[%s] ACK   #%" PRIu32 " freertos_tick=%lld.%09lld  [hello=%" PRIu32 " ack=%" PRIu32 "]\n",
                   HSOC_SENDER_LABEL, ack.seq,
                   (long long)ack.ts_sec, (long long)ack.ts_nsec,
                   hello_count, ack_count);
            fflush(stdout);
        }

        seq++;
        sleep(interval);
    }
}

int main(int argc, char *argv[])
{
    const char *bar2_path = argc > 1 ? argv[1] : find_ivshmem_resource();
    if (!bar2_path) {
        fprintf(stderr, "[%s] cannot locate ivshmem BAR2; pass path explicitly\n",
                HSOC_SENDER_LABEL);
        return 1;
    }

    const char *interval_str = getenv("SYSLOG_INTERVAL_SEC");
    int interval_val = interval_str ? atoi(interval_str) : 0;
    unsigned int interval = (interval_val >= 1) ? (unsigned int)interval_val : 5;

    int fd = open(bar2_path, O_RDWR | O_SYNC);
    if (fd < 0) { perror("open BAR2"); return 1; }

    struct hsoc_layout *shm = mmap(NULL, HSOC_BAR2_SIZE,
                                   PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm == MAP_FAILED) { perror("mmap BAR2"); close(fd); return 1; }

    printf("[%s] BAR2 mapped at %p, interval=%us\n",
           HSOC_SENDER_LABEL, (void *)shm, interval);
    fflush(stdout);

    int rc = main_loop(shm, interval);
    munmap(shm, HSOC_BAR2_SIZE);
    close(fd);
    return rc;
}
