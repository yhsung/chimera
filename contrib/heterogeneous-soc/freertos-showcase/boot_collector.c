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

#include "bootlog_proto.h"

#define COLLECT_LOG_DIR      "/var/log/boot-logs"
#define POLL_INTERVAL_US     2000000  /* 2 seconds */

static const char *guest_names[] = {
    [HSOC_GUEST_ARM_LINUX]   = "guest-arm",
    [HSOC_GUEST_RISCV_LINUX] = "guest-riscv",
    [HSOC_GUEST_MIPS_LINUX]  = "guest-mips",
    [HSOC_GUEST_FREERTOS]    = "guest-freertos",
};

static const unsigned int slot_offsets[] = {
    [HSOC_GUEST_ARM_LINUX]   = BOOTLOG_SLOT_ARM,
    [HSOC_GUEST_RISCV_LINUX] = BOOTLOG_SLOT_RISCV,
    [HSOC_GUEST_MIPS_LINUX]  = BOOTLOG_SLOT_MIPS,
    [HSOC_GUEST_FREERTOS]    = BOOTLOG_SLOT_FREERTOS,
};

static volatile struct hsoc_bootlog_header *header;

static void shm_read_buf(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

static int write_guest_log(int guest_idx, const char *dir_path)
{
    if (guest_idx < 0 || guest_idx >= (int)BOOTLOG_NUM_GUESTS) {
        fprintf(stderr, "[boot-collector] write_guest_log: invalid index %d\n",
                guest_idx);
        return -1;
    }

    char file_path[PATH_MAX];
    snprintf(file_path, sizeof(file_path), "%s/%s.log",
             dir_path, guest_names[guest_idx]);

    __sync_synchronize();
    uint32_t offset = header->guests[guest_idx].offset;
    if (offset == 0) return 0;
    if (offset > BOOTLOG_SLOT_SIZE) offset = BOOTLOG_SLOT_SIZE;

    const volatile uint8_t *slot =
        (const volatile uint8_t *)header + slot_offsets[guest_idx];

    uint8_t *buf = malloc(offset);
    if (!buf) {
        fprintf(stderr, "[boot-collector] malloc(%" PRIu32 ") failed\n", offset);
        return -1;
    }
    shm_read_buf(buf, slot, offset);

    FILE *f = fopen(file_path, "w");
    if (!f) {
        perror(file_path);
        free(buf);
        return -1;
    }
    size_t written = fwrite(buf, 1, offset, f);
    fclose(f);
    free(buf);

    if (written != offset) {
        fprintf(stderr, "[boot-collector] short write to %s: %zu/%" PRIu32 "\n",
                file_path, written, offset);
        return -1;
    }
    fprintf(stderr, "[boot-collector] wrote %s (%" PRIu32 " bytes)\n",
            file_path, offset);
    return (int)offset;
}

static volatile struct hsoc_bootlog_header *find_bootlog_shm(void)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) sysfs_root = "/sys/bus/pci/devices";

    for (int attempt = 0; attempt < 30; attempt++) {
        DIR *dir = opendir(sysfs_root);
        if (!dir) { perror("opendir"); return NULL; }

        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (entry->d_name[0] == '.') continue;

            char vendor_path[PATH_MAX];
            snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                     sysfs_root, entry->d_name);
            FILE *f = fopen(vendor_path, "r");
            if (!f) continue;
            char vendor[32];
            if (!fgets(vendor, sizeof(vendor), f)) { fclose(f); continue; }
            fclose(f);
            vendor[strcspn(vendor, "\n")] = '\0';
            if (strcmp(vendor, "0x1af4") != 0) continue;

            char res_path[PATH_MAX];
            snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                     sysfs_root, entry->d_name);
            /* Don't close fd yet — if magic matches, reuse it */
            int fd = open(res_path, O_RDONLY | O_SYNC);
            if (fd < 0) continue;

            void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
            if (p == MAP_FAILED) { close(fd); continue; }
            uint32_t magic = *(volatile uint32_t *)p;
            __sync_synchronize();
            munmap(p, 4096);

            if (magic == BOOTLOG_MAGIC) {
                void *full = mmap(NULL, BOOTLOG_BAR2_SIZE, PROT_READ,
                                  MAP_SHARED, fd, 0);
                close(fd);
                if (full == MAP_FAILED) { closedir(dir); return NULL; }
                closedir(dir);
                return (volatile struct hsoc_bootlog_header *)full;
            }
            close(fd);
        }
        closedir(dir);
        if (attempt == 0)
            fprintf(stderr, "[boot-collector] waiting for boot-log BAR2...\n");
        sleep(1);
    }
    fprintf(stderr, "[boot-collector] timed out waiting for boot-log BAR2 after 30 attempts\n");
    return NULL;
}

int main(int argc, char *argv[])
{
    const char *bar2_path = argc > 1 ? argv[1] : NULL;

    if (bar2_path) {
        int fd = open(bar2_path, O_RDONLY | O_SYNC);
        if (fd < 0) { perror("open BAR2"); return 1; }
        void *p = mmap(NULL, BOOTLOG_BAR2_SIZE, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) { perror("mmap BAR2"); return 1; }
        header = (volatile struct hsoc_bootlog_header *)p;
    } else {
        header = find_bootlog_shm();
    }

    if (!header) {
        fprintf(stderr, "[boot-collector] could not find boot-log ivshmem BAR2\n");
        return 1;
    }
    __sync_synchronize();
    if (header->magic != BOOTLOG_MAGIC) {
        fprintf(stderr, "[boot-collector] bad magic 0x%08" PRIx32 "\n",
                header->magic);
        return 1;
    }

    if (mkdir(COLLECT_LOG_DIR, 0755) != 0 && errno != EEXIST) {
        perror(COLLECT_LOG_DIR);
        return 1;
    }

    fprintf(stderr, "[boot-collector] monitoring boot-log BAR2 at %p\n",
            (void *)header);

    uint32_t last_gen = 0;
    for (;;) {
        usleep(POLL_INTERVAL_US);

        __sync_synchronize();
        uint32_t gen = header->generation;

        if (gen == 0 && last_gen == 0) continue;

        if (gen != last_gen) {
            fprintf(stderr, "[boot-collector] generation %" PRIu32
                    " -> %" PRIu32 "\n", last_gen, gen);
            last_gen = gen;

            int collected = 0;
            for (int i = 0; i < (int)BOOTLOG_NUM_GUESTS; i++) {
                int ret = write_guest_log(i, COLLECT_LOG_DIR);
                if (ret > 0) collected++;
            }
            fprintf(stderr, "[boot-collector] collected %d/%u guest logs\n",
                    collected, BOOTLOG_NUM_GUESTS);
        }
    }
}
