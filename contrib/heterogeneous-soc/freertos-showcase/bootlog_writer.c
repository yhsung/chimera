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

#ifndef HSOC_BOOTLOG_GUEST
#define HSOC_BOOTLOG_GUEST HSOC_GUEST_ARM_LINUX
#endif

#ifndef HSOC_BOOTLOG_LABEL
#define HSOC_BOOTLOG_LABEL "arm-linux"
#endif

static volatile struct hsoc_bootlog_header *header;
static volatile uint8_t *slot_base;
static uint32_t slot_offset;

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

static void write_with_offset(const char *buf, size_t len)
{
    if (slot_offset >= BOOTLOG_SLOT_SIZE) {
        static bool trunc_written = false;
        if (!trunc_written) {
            size_t tlen = BOOTLOG_TRUNC_MARKER_SIZE;
            if (tlen < BOOTLOG_SLOT_SIZE) {
                shmem_write_buf(slot_base + BOOTLOG_SLOT_SIZE - tlen,
                                BOOTLOG_TRUNC_MARKER, tlen);
            }
            __sync_synchronize();
            shmem_write32(&header->guests[HSOC_BOOTLOG_GUEST].offset,
                          BOOTLOG_SLOT_SIZE);
            __sync_synchronize();
            trunc_written = true;
        }
        return;
    }

    size_t writable = BOOTLOG_SLOT_SIZE - slot_offset;
    if (len > writable) {
        len = writable;
    }
    if (len == 0) {
        return;
    }

    shmem_write_buf(slot_base + slot_offset, buf, len);
    slot_offset += (uint32_t)len;
    __sync_synchronize();
    shmem_write32(&header->guests[HSOC_BOOTLOG_GUEST].offset, slot_offset);
    __sync_synchronize();
}

static void append_kmsg_line(const char *line)
{
    size_t len = strlen(line);
    write_with_offset(line, len);
    write_with_offset("\n", 1);
}

static int drain_kmsg(int fd)
{
    char buf[4096];
    int count = 0;
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        append_kmsg_line(buf);
        count++;
    }
    return count;
}

static bool find_bootlog_bar2(char *path_out, size_t path_out_size)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) {
        sysfs_root = "/sys/bus/pci/devices";
    }

    DIR *dir = opendir(sysfs_root);
    if (!dir) {
        perror("opendir");
        return false;
    }

    bool found = false;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') {
            continue;
        }

        char vendor_path[PATH_MAX];
        snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                 sysfs_root, entry->d_name);
        FILE *f = fopen(vendor_path, "r");
        if (!f) {
            continue;
        }
        char vendor[32] = {0};
        if (!fgets(vendor, sizeof(vendor), f)) {
            fclose(f);
            continue;
        }
        fclose(f);
        vendor[strcspn(vendor, "\n")] = '\0';
        if (strcmp(vendor, "0x1af4") != 0) {
            continue;
        }

        char res_path[PATH_MAX];
        snprintf(res_path, sizeof(res_path), "%s/%s/resource2",
                 sysfs_root, entry->d_name);

        int fd = open(res_path, O_RDONLY | O_SYNC);
        if (fd < 0) {
            continue;
        }
        void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) {
            continue;
        }
        volatile uint32_t *vp = (volatile uint32_t *)p;
        uint32_t magic = *vp;
        __sync_synchronize();
        munmap(p, 4096);

        if (magic == BOOTLOG_MAGIC) {
            snprintf(path_out, path_out_size, "%s", res_path);
            found = true;
            break;
        }
    }
    closedir(dir);
    return found;
}

int main(int argc, char *argv[])
{
    const char *bar2_path = (argc > 1) ? argv[1] : NULL;
    static char path_buf[PATH_MAX];

    if (!bar2_path) {
        if (!find_bootlog_bar2(path_buf, sizeof(path_buf))) {
            fprintf(stderr, "[bootlog-writer:%s] cannot locate boot-log ivshmem BAR2\n",
                    HSOC_BOOTLOG_LABEL);
            return 1;
        }
        bar2_path = path_buf;
    }

    int fd = open(bar2_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open BAR2");
        return 1;
    }

    void *base = mmap(NULL, BOOTLOG_BAR2_SIZE, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        perror("mmap BAR2");
        close(fd);
        return 1;
    }
    close(fd);

    header = (volatile struct hsoc_bootlog_header *)base;

    /* Wait for FreeRTOS to initialize the header magic */
    for (int i = 0; i < 30; i++) {
        __sync_synchronize();
        if (header->magic == BOOTLOG_MAGIC) {
            break;
        }
        sleep(1);
    }

    if (header->magic != BOOTLOG_MAGIC) {
        fprintf(stderr, "[bootlog-writer:%s] bad magic after 30 s wait\n",
                HSOC_BOOTLOG_LABEL);
        return 1;
    }

    /* Select our slot */
    switch (HSOC_BOOTLOG_GUEST) {
    case HSOC_GUEST_ARM_LINUX:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_ARM;
        break;
    case HSOC_GUEST_RISCV_LINUX:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_RISCV;
        break;
    case HSOC_GUEST_MIPS_LINUX:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_MIPS;
        break;
    default:
        slot_base = (volatile uint8_t *)base + BOOTLOG_SLOT_FREERTOS;
        break;
    }

    __sync_synchronize();
    slot_offset = header->guests[HSOC_BOOTLOG_GUEST].offset;
    if (slot_offset >= BOOTLOG_SLOT_SIZE) {
        slot_offset = 0;
    }

    /* Write boot header line */
    char boot_header[256];
    time_t now = time(NULL);
    struct tm *tm_info = gmtime(&now);
    strftime(boot_header, sizeof(boot_header),
             "[bootlog] %Y-%m-%dT%H:%M:%SZ booting " HSOC_BOOTLOG_LABEL "\n",
             tm_info);
    write_with_offset(boot_header, strlen(boot_header));
    fprintf(stderr, "%s", boot_header);

#if HSOC_BOOTLOG_GUEST == HSOC_GUEST_ARM_LINUX
    /* ARM-Linux: read IVPOSITION from BAR0 (resource0) and write collector_peer_id */
    {
        size_t blen = strlen(bar2_path);
        if (blen > 10 && strcmp(bar2_path + blen - 10, "/resource2") == 0) {
            char mmio_path[PATH_MAX];
            memcpy(mmio_path, bar2_path, blen - 9);
            memcpy(mmio_path + blen - 9, "resource0\0", 10);

            int mmio_fd = open(mmio_path, O_RDONLY | O_SYNC);
            if (mmio_fd >= 0) {
                volatile uint32_t *mmio = mmap(NULL, 4096, PROT_READ,
                                               MAP_SHARED, mmio_fd, 0);
                if (mmio != MAP_FAILED) {
                    /* IVPOSITION register is at byte offset 0x08 = index 2 */
                    uint32_t ivposition;
                    __sync_synchronize();
                    ivposition = mmio[2];
                    __sync_synchronize();
                    munmap((void *)mmio, 4096);

                    shmem_write32(&header->collector_peer_id, ivposition);
                    __sync_synchronize();
                    fprintf(stderr, "[bootlog-writer:arm-linux] "
                            "set collector_peer_id = %" PRIu32 "\n", ivposition);
                }
                close(mmio_fd);
            }
        }
    }
#endif

    /* Mark our guest as boot-complete */
    __sync_synchronize();
    shmem_write32(&header->guests[HSOC_BOOTLOG_GUEST].status,
                  HSOC_BOOT_COMPLETE);
    __sync_synchronize();

    /* Drain existing kernel messages */
    int kmsg_fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kmsg_fd >= 0) {
        int n = drain_kmsg(kmsg_fd);
        fprintf(stderr, "[bootlog-writer:%s] drained %d existing kmsg lines\n",
                HSOC_BOOTLOG_LABEL, n);
        close(kmsg_fd);
    } else {
        fprintf(stderr, "[bootlog-writer:%s] warning: cannot open /dev/kmsg (%s)\n",
                HSOC_BOOTLOG_LABEL, strerror(errno));
    }

    fprintf(stderr, "[bootlog-writer:%s] entering polling loop\n",
            HSOC_BOOTLOG_LABEL);

    for (;;) {
        sleep(2);
        kmsg_fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
        if (kmsg_fd >= 0) {
            drain_kmsg(kmsg_fd);
            close(kmsg_fd);
        }
    }
}
