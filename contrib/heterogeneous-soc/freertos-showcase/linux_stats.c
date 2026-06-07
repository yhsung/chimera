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

#include "stats_proto.h"

#define HSOC_VENDOR_ID "0x1af4"
#define STATS_MMAP_SIZE ((size_t)4096)
#define STATS_RETRY_SEC 30

static bool read_first_line(const char *path, char *buf, size_t buf_size)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        return false;
    }
    bool ok = fgets(buf, buf_size, f) != NULL;
    fclose(f);
    if (ok) {
        buf[strcspn(buf, "\n")] = '\0';
    }
    return ok;
}

static void shm_read(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    size_t i;
    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

/*
 * Scan all PCI ivshmem devices (vendor 0x1af4) and return the first one whose
 * BAR2 (resource2) begins with HSOC_STATS_MAGIC. Retries for up to
 * STATS_RETRY_SEC seconds to handle the race where linux_stats starts before
 * FreeRTOS has written the magic value.
 */
static volatile struct hsoc_stats_snapshot *find_stats_shm(void)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) {
        sysfs_root = "/sys/bus/pci/devices";
    }

    for (int attempt = 0; attempt < STATS_RETRY_SEC; attempt++) {
        DIR *dir = opendir(sysfs_root);
        if (!dir) {
            perror("opendir");
            return NULL;
        }

        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') {
                continue;
            }

            char vendor_path[PATH_MAX];
            char vendor_val[32];
            if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                         sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) {
                continue;
            }
            if (!read_first_line(vendor_path, vendor_val, sizeof(vendor_val))) {
                continue;
            }
            if (strcmp(vendor_val, HSOC_VENDOR_ID) != 0) {
                continue;
            }

            char res_path[PATH_MAX];
            if (snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                         sysfs_root, entry->d_name) >= (int)sizeof(res_path)) {
                continue;
            }

            int fd = open(res_path, O_RDONLY | O_SYNC);
            if (fd < 0) {
                continue;
            }

            void *p = mmap(NULL, STATS_MMAP_SIZE, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) {
                continue;
            }

            uint32_t magic;
            shm_read(&magic, p, sizeof(magic));
            __sync_synchronize();

            if (magic == HSOC_STATS_MAGIC) {
                closedir(dir);
                return (volatile struct hsoc_stats_snapshot *)p;
            }
            munmap(p, STATS_MMAP_SIZE);
        }
        closedir(dir);

        if (attempt == 0) {
            fprintf(stderr, "[stats] waiting for FreeRTOS stats magic...\n");
        }
        sleep(1);
    }

    return NULL;
}

static void log_snapshot(FILE *log, const struct hsoc_stats_snapshot *snap)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    struct tm *tm_info = gmtime(&ts.tv_sec);
    char timebuf[32];
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%dT%H:%M:%SZ", tm_info);

    fprintf(log,
            "[%s] gen=%" PRIu32
            " arm=%" PRIu32 " cpu=%" PRIu32 ".%02" PRIu32 "%% mem=%" PRIu32 ".%02" PRIu32 "%%"
            " riscv=%" PRIu32 " cpu=%" PRIu32 ".%02" PRIu32 "%% mem=%" PRIu32 ".%02" PRIu32 "%%"
            " mips=%" PRIu32 " cpu=%" PRIu32 ".%02" PRIu32 "%% mem=%" PRIu32 ".%02" PRIu32 "%%"
            " tick=%" PRId64 ".%09" PRId64 "\n",
            timebuf,
            snap->generation,
            snap->arm_count,
            snap->arm_cpu_pct_x100 / 100, snap->arm_cpu_pct_x100 % 100,
            snap->arm_mem_pct_x100 / 100, snap->arm_mem_pct_x100 % 100,
            snap->riscv_count,
            snap->riscv_cpu_pct_x100 / 100, snap->riscv_cpu_pct_x100 % 100,
            snap->riscv_mem_pct_x100 / 100, snap->riscv_mem_pct_x100 % 100,
            snap->mips_count,
            snap->mips_cpu_pct_x100 / 100, snap->mips_cpu_pct_x100 % 100,
            snap->mips_mem_pct_x100 / 100, snap->mips_mem_pct_x100 % 100,
            snap->tick_sec,
            snap->tick_nsec);
    fflush(log);
}

int main(int argc, char *argv[])
{
    const char *log_path = getenv("FREERTOS_STATS_LOG");
    if (!log_path) {
        log_path = "/var/log/chimera-log/chimera-cross-domain.log";
    }

    volatile struct hsoc_stats_snapshot *shm;

    if (argc > 1) {
        int fd = open(argv[1], O_RDONLY | O_SYNC);
        if (fd < 0) {
            perror("open BAR2");
            return 1;
        }
        void *p = mmap(NULL, STATS_MMAP_SIZE, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) {
            perror("mmap BAR2");
            return 1;
        }
        shm = (volatile struct hsoc_stats_snapshot *)p;
    } else {
        shm = find_stats_shm();
    }

    if (!shm) {
        fprintf(stderr, "[stats] could not find stats ivshmem BAR2\n");
        return 1;
    }

    /* Ensure parent directory exists */
    {
        char parent[PATH_MAX];
        size_t len = strlen(log_path);
        if (len > 0 && len < sizeof(parent)) {
            memcpy(parent, log_path, len);
            parent[len] = '\0';
            char *slash = strrchr(parent, '/');
            if (slash && slash != parent) {
                *slash = '\0';
                if (mkdir(parent, 0755) != 0 && errno != EEXIST) {
                    perror(parent);
                    return 1;
                }
            }
        }
    }

    FILE *log = fopen(log_path, "a");
    if (!log) {
        perror("fopen log");
        return 1;
    }

    fprintf(stderr, "[stats] logging to %s\n", log_path);

    uint32_t last_gen = 0;
    for (;;) {
        uint32_t gen = shm->generation;
        __sync_synchronize();

        if (gen != last_gen) {
            struct hsoc_stats_snapshot snap;
            shm_read(&snap, shm, sizeof(snap));
            __sync_synchronize();

            if (snap.magic != HSOC_STATS_MAGIC) {
                continue;
            }

            last_gen = gen;
            log_snapshot(log, &snap);
            fprintf(stderr, "[stats] gen=%" PRIu32 " logged\n", gen);
        }
        sleep(2);
    }

    fclose(log);
    return 0;
}
