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
#include <poll.h>

#include "can_proto.h"
#include "hello_proto.h"

#define HSOC_BAR2_SIZE      (64U * 1024U * 1024U)
#define HSOC_VENDOR_ID      "0x1af4"
#define HSOC_STATS_MAGIC    0x53544154U
#define HSOC_BOOTLOG_MAGIC  0x424C5447U  /* "BLTG" — boot-log channel, skip */
#define HSOC_DOORBELL_OFFSET  0x00cU    /* BAR0 doorbell register offset */
#define UIO_TIMEOUT_MS         200UL

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

static uint32_t read_cpu_pct_x100(void)
{
    static bool have_prev;
    static unsigned long long prev_idle, prev_total;

    char line[256];
    if (!read_first_line("/proc/stat", line, sizeof(line)))
        return 0;

    unsigned long long user, nice, system, idle, iowait, irq, softirq, steal;
    iowait = irq = softirq = steal = 0;
    int n = sscanf(line, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
                   &user, &nice, &system, &idle,
                   &iowait, &irq, &softirq, &steal);
    if (n < 4)
        return 0;

    unsigned long long total = user + nice + system + idle + iowait + irq + softirq + steal;
    unsigned long long busy_idle = idle + iowait;

    /* First call has no baseline yet, so have_prev is false and pct_x100 stays 0. */
    uint32_t pct_x100 = 0;
    if (have_prev && total > prev_total) {
        unsigned long long dtotal = total - prev_total;
        /* Clamp against underflow: aggregate idle/iowait counters can decrease
         * between samples on some kernels (e.g. around CPU hotplug events),
         * so guard both the subtraction and the dtotal - didle below. */
        unsigned long long didle = (busy_idle >= prev_idle) ? (busy_idle - prev_idle) : 0;
        if (didle > dtotal)
            didle = dtotal;
        pct_x100 = (uint32_t)(10000ULL * (dtotal - didle) / dtotal);
    }
    have_prev = true;
    prev_idle = busy_idle;
    prev_total = total;
    return pct_x100;
}

static uint32_t read_mem_used_pct_x100(void)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f)
        return 0;

    char line[128];
    unsigned long total_kb = 0, avail_kb = 0;
    bool have_total = false, have_avail = false;
    while (fgets(line, sizeof(line), f)) {
        if (!have_total && sscanf(line, "MemTotal: %lu kB", &total_kb) == 1)
            have_total = true;
        else if (!have_avail && sscanf(line, "MemAvailable: %lu kB", &avail_kb) == 1)
            have_avail = true;
        if (have_total && have_avail)
            break;
    }
    fclose(f);

    if (!have_total || total_kb == 0 || avail_kb > total_kb)
        return 0;
    return (uint32_t)(10000ULL * (total_kb - avail_kb) / total_kb);
}

static void build_sysinfo_text(char *buf, size_t n,
                                uint32_t cpu_pct_x100, uint32_t mem_pct_x100)
{
    unsigned int ld_int, ld_frac;
    read_loadavg_fixed(&ld_int, &ld_frac);
    snprintf(buf, n, "ld=%u.%02u cpu=%u.%02u%% mem=%u.%02u%% mf=%uM up=%us",
             ld_int, ld_frac,
             cpu_pct_x100 / 100, cpu_pct_x100 % 100,
             mem_pct_x100 / 100, mem_pct_x100 % 100,
             read_memfree_mb(), read_uptime_sec());
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

/* Doorbell/UIO state — defined here so hybrid_wait_ack() (below) and
 * doorbell_init()/doorbell_ring() (after find_ivshmem_resource()) can
 * share them. */
static int uio_fd = -1;
static volatile uint32_t *bar0 = NULL;
static bool doorbell_available = false;

/*
 * Wait for ACK from FreeRTOS using hybrid interrupt + poll strategy:
 *   1. If UIO is available (uio_fd >= 0): ppoll(fd, 200ms) for doorbell IRQ
 *   2. On timeout or if UIO is absent: busy-wait on flag directly
 *   3. Read the ACK message from shared memory
 */
static void hybrid_wait_ack(struct hsoc_layout *shm,
                            struct hsoc_hello_msg *ack)
{
    if (uio_fd >= 0) {
        struct pollfd pfd = { .fd = uio_fd, .events = POLLIN };
        int ret = poll(&pfd, 1, (int)UIO_TIMEOUT_MS);
        if (ret > 0 && (pfd.revents & POLLIN)) {
            /* Read and discard the UIO event count (uint32_t) */
            uint32_t evt_cnt;
            ssize_t n = read(uio_fd, &evt_cnt, sizeof(evt_cnt));
            (void)n;
            /* IRQ path: doorbell received, ACK should be in shared memory */
        } else {
            /* Fallback path: IRQ missed or timed out, poll flag directly */
        }
    } else {
        /* No UIO available (RISCV/MIPS build or binding failed): busy-wait */
        while (1) {
            __sync_synchronize();
            if (shm->freertos_to_linux.flag == 1) break;
        }
    }

    /* Read the ACK from shared memory (always — works for both paths) */
    __sync_synchronize();
    if (shm->freertos_to_linux.flag == 1) {
        shm_read(ack, &shm->freertos_to_linux.msg, sizeof(*ack));
        __sync_synchronize();
        shm->freertos_to_linux.flag = 0;
    } else {
        memset(ack, 0, sizeof(*ack));
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

/*
 * Locate the sysfs BDF of the ARM-Linux ivshmem-doorbell whose BAR2 shared
 * memory does NOT contain a known magic (STATS, BOOTLOG, CAN). That's the
 * ARM-Linux <-> FreeRTOS syslog channel.
 *
 * Returns a pointer to a static buffer (like find_ivshmem_resource), or NULL.
 */
static const char *find_ivshmem_doorbell(void)
{
    static char bdf_buf[PATH_MAX];
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

        /* Peek at the magic at the start of BAR2 to identify the channel */
        char res2_path[PATH_MAX];
        if (snprintf(res2_path, sizeof(res2_path), "%s/%s/resource2",
                     sysfs_root, entry->d_name) >= (int)sizeof(res2_path)) continue;

        struct stat st;
        if (stat(res2_path, &st) != 0) continue;

        int fd = open(res2_path, O_RDONLY | O_SYNC);
        if (fd < 0) continue;
        void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) continue;

        uint32_t magic;
        shm_read(&magic, p, sizeof(magic));
        __sync_synchronize();
        munmap(p, 4096);

        /* Skip channels whose BAR2 begins with a known non-syslog magic */
        if (magic == HSOC_STATS_MAGIC || magic == HSOC_BOOTLOG_MAGIC ||
            magic == CAN_IVSHMEM_MAGIC) {
            continue;
        }

        /* This is the syslog channel */
        strncpy(bdf_buf, entry->d_name, sizeof(bdf_buf) - 1);
        bdf_buf[sizeof(bdf_buf) - 1] = '\0';
        closedir(dir);
        return bdf_buf;
    }

    closedir(dir);
    return NULL;
}

/*
 * Initialize the doorbell path:
 *   1. mmap BAR0/resource0 for doorbell writes (send direction, no UIO needed)
 *   2. Open /dev/uio0 for interrupt receive (optional — if absent, fall back to poll)
 * Returns 0 on success, -1 on failure (caller degrades gracefully).
 */
static int doorbell_init(void)
{
    char res0_path[PATH_MAX];
    const char *bdf = getenv("IVSHMEM_BDF");
    int fd;

    if (!bdf) {
        bdf = find_ivshmem_doorbell();
        if (!bdf) {
            fprintf(stderr, "[%s] doorbell: no ivshmem BDF found, using poll\n",
                    HSOC_SENDER_LABEL);
            return -1;
        }
    }

    if (snprintf(res0_path, sizeof(res0_path),
                  "/sys/bus/pci/devices/%s/resource0", bdf) >= (int)sizeof(res0_path)) {
        fprintf(stderr, "[%s] doorbell: BDF path too long, using poll\n",
                HSOC_SENDER_LABEL);
        return -1;
    }
    fd = open(res0_path, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "[%s] doorbell: cannot open %s, using poll\n",
                HSOC_SENDER_LABEL, res0_path);
        return -1;
    }

    bar0 = (volatile uint32_t *)mmap(NULL, 4096,
                                     PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, 0);
    close(fd);
    if (bar0 == MAP_FAILED) {
        bar0 = NULL;
        fprintf(stderr, "[%s] doorbell: mmap resource0 failed, using poll\n",
                HSOC_SENDER_LABEL);
        return -1;
    }

    /* Attempt to open UIO for interrupt receive — this is optional.
     * ARM-Linux build: /dev/uio0 should exist if bound in guest-install.
     * RISCV/MIPS builds: UIO is absent, uio_fd stays -1, poll fallback used. */
    uio_fd = open("/dev/uio0", O_RDWR);

    doorbell_available = true;
    fprintf(stderr, "[%s] doorbell: init OK (uio_fd=%d)\n",
            HSOC_SENDER_LABEL, uio_fd);
    return 0;
}

/*
 * Ring the doorbell to interrupt FreeRTOS, signalling that a new HELLO message
 * has been written to IVSHMEM0 shared memory.
 *
 * ivshmem PCI DOORBELL register (BAR0 + 0x0c): a single uint32_t encoding
 * (peer_id << 16) | vector_id. ARM-Linux joins first (peer 0), FreeRTOS
 * joins second (peer 1).
 */
static void doorbell_ring(void)
{
    if (!bar0 || !doorbell_available) return;

    /* IVSHMEM DOORBELL register (BAR0 + 0x0c):
     * Write (peer_id << 16) | vector_id as a single uint32_t.
     * peer_id=1 = FreeRTOS (joined second after ARM-Linux=0).
     * vector=0 = use eventfd[0]. */
    bar0[HSOC_DOORBELL_OFFSET / sizeof(uint32_t)] = (1U << 16);
    __sync_synchronize();
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
        uint32_t cpu_pct_x100 = read_cpu_pct_x100();
        uint32_t mem_pct_x100 = read_mem_used_pct_x100();

        clock_gettime(CLOCK_REALTIME, &ts);
        memset(&msg, 0, sizeof(msg));
        msg.magic             = HSOC_HELLO_MAGIC;
        msg.version           = HSOC_PROTO_VERSION;
        msg.msg_type          = HSOC_MSG_HELLO;
        msg.seq               = seq;
        msg.sender_id         = HSOC_SENDER_ID;
        msg.ts_sec            = ts.tv_sec;
        msg.ts_nsec           = ts.tv_nsec;
        msg.cpu_pct_x100      = cpu_pct_x100;
        msg.mem_used_pct_x100 = mem_pct_x100;
        build_sysinfo_text(msg.text, sizeof(msg.text), cpu_pct_x100, mem_pct_x100);

        shm_write(&shm->linux_to_freertos.msg, &msg, sizeof(msg));
        __sync_synchronize();
        shm->linux_to_freertos.flag = 1;
        hello_count++;

        /* Ring doorbell to notify FreeRTOS via interrupt */
        doorbell_ring();

        /* Primary: interrupt-driven ACK wait with poll fallback */
        hybrid_wait_ack(shm, &ack);

        if (ack.magic != HSOC_HELLO_MAGIC) {
            /* ACK not received (timeout or no UIO and flag not yet set).
             * This is the fallback path; retry on next cycle. */
            static uint32_t warn_count;
            if (warn_count++ % 5 == 0) {
                fprintf(stderr, "[%s] ACK timeout (seq=%" PRIu32
                        ") — doorbell IRQ may be missed\n",
                        HSOC_SENDER_LABEL, seq);
            }
            continue;
        }

        ack_count++;

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
    if (getenv("SYSLOG_SELFTEST")) {
        char text[HSOC_TEXT_LEN];
        build_sysinfo_text(text, sizeof(text),
                           read_cpu_pct_x100(), read_mem_used_pct_x100());
        printf("[%s] SYSINFO #0 %s\n", HSOC_SENDER_LABEL, text);
        fflush(stdout);
        return 0;
    }

    const char *bar2_path = argc > 1 ? argv[1] : find_ivshmem_resource();
    if (!bar2_path) {
        fprintf(stderr, "[%s] cannot locate ivshmem BAR2; pass path explicitly\n",
                HSOC_SENDER_LABEL);
        return 1;
    }

    /* Initialize doorbell/UIO path for interrupt-driven ACK wait */
    doorbell_init();

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
