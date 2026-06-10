#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <net/if.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <linux/can.h>
#include <linux/can/raw.h>

#include "can_proto.h"

#define HSOC_VENDOR_ID "0x1af4"
#define CAN_MMAP_SIZE ((size_t)65536)
#define CAN_RETRY_SEC 30

static const char *g_log_path;
static FILE *g_log;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void log_frame(const char *source, uint32_t id, uint32_t dlc,
                      const uint8_t *data)
{
    struct timespec ts;
    struct tm tm_info;
    char timebuf[32];
    uint32_t i;

    clock_gettime(CLOCK_REALTIME, &ts);
    gmtime_r(&ts.tv_sec, &tm_info);
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%dT%H:%M:%SZ", &tm_info);

    pthread_mutex_lock(&g_log_lock);
    fprintf(g_log, "[%s] CAN/%s id=0x%03" PRIx32 " dlc=%" PRIu32 " data=",
            timebuf, source, id, dlc);
    for (i = 0; i < dlc && i < 8; i++) {
        fprintf(g_log, "%02x%s", data[i], (i + 1 < dlc) ? " " : "");
    }
    fputc('\n', g_log);
    fflush(g_log);
    pthread_mutex_unlock(&g_log_lock);
}

/* ---- Thread 1: SocketCAN reader on can0 ---- */
static void *socketcan_thread(void *arg)
{
    const char *ifname = arg ? (const char *)arg : "can0";
    int s;
    struct sockaddr_can addr;
    struct ifreq ifr;

    s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
    if (s < 0) {
        perror("socket(PF_CAN)");
        return NULL;
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFINDEX, &ifr) < 0) {
        fprintf(stderr, "[can] %s not found (is it up?)\n", ifname);
        close(s);
        return NULL;
    }

    memset(&addr, 0, sizeof(addr));
    addr.can_family = AF_CAN;
    addr.can_ifindex = ifr.ifr_ifindex;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind(can0)");
        close(s);
        return NULL;
    }

    fprintf(stderr, "[can] socketcan reader bound to %s\n", ifname);

    for (;;) {
        struct can_frame frame;
        ssize_t n = read(s, &frame, sizeof(frame));
        if (n < (ssize_t)sizeof(frame)) {
            if (n < 0 && errno != EINTR) {
                /* Avoid a busy-loop on persistent errors (e.g. CAN
                 * bus-off): back off briefly before retrying. */
                usleep(100000);
            }
            continue;
        }
        log_frame("socketcan", frame.can_id & CAN_SFF_MASK,
                  frame.can_dlc, frame.data);
    }

    close(s);
    return NULL;
}

/* ---- Thread 2: IVSHMEM5 reader ---- */
static void shm_read(void *dst, const volatile void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const volatile uint8_t *s = (const volatile uint8_t *)src;
    size_t i;
    for (i = 0; i < n; i++) {
        d[i] = s[i];
    }
}

static volatile struct can_ivshmem_layout *find_can_shm(void)
{
    const char *sysfs_root = getenv("IVSHMEM_SYSFS_ROOT");
    if (!sysfs_root) {
        sysfs_root = "/sys/bus/pci/devices";
    }

    for (int attempt = 0; attempt < CAN_RETRY_SEC; attempt++) {
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
            FILE *vf;
            if (snprintf(vendor_path, sizeof(vendor_path), "%s/%s/vendor",
                         sysfs_root, entry->d_name) >= (int)sizeof(vendor_path)) {
                continue;
            }
            vf = fopen(vendor_path, "r");
            if (!vf) {
                continue;
            }
            bool got = fgets(vendor_val, sizeof(vendor_val), vf) != NULL;
            fclose(vf);
            if (!got) {
                continue;
            }
            vendor_val[strcspn(vendor_val, "\n")] = '\0';
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
            void *p = mmap(NULL, CAN_MMAP_SIZE, PROT_READ, MAP_SHARED, fd, 0);
            close(fd);
            if (p == MAP_FAILED) {
                continue;
            }

            uint32_t magic;
            shm_read(&magic, p, sizeof(magic));
            __sync_synchronize();
            if (magic == CAN_IVSHMEM_MAGIC) {
                closedir(dir);
                return (volatile struct can_ivshmem_layout *)p;
            }
            munmap(p, CAN_MMAP_SIZE);
        }
        closedir(dir);

        if (attempt == 0) {
            fprintf(stderr, "[can] waiting for FreeRTOS CAN ivshmem magic...\n");
        }
        sleep(1);
    }
    return NULL;
}

static void *ivshmem_thread(void *arg)
{
    (void)arg;
    volatile struct can_ivshmem_layout *shm = find_can_shm();
    if (!shm) {
        fprintf(stderr, "[can] could not find CAN ivshmem BAR2\n");
        return NULL;
    }
    fprintf(stderr, "[can] ivshmem reader attached\n");

    uint32_t last_gen = 0;
    for (;;) {
        uint32_t gen = shm->generation;
        __sync_synchronize();
        if (gen != last_gen) {
            struct can_ivshmem_frame f;
            shm_read(&f, (const void *)&shm->frame, sizeof(f));
            __sync_synchronize();
            last_gen = gen;
            log_frame("freertos", f.id, f.dlc, f.data);
        }
        usleep(20000); /* 20 ms */
    }
    return NULL;
}

int main(int argc, char *argv[])
{
    const char *ifname = (argc > 1) ? argv[1] : "can0";

    g_log_path = getenv("CHIMERA_CAN_LOG");
    if (!g_log_path) {
        g_log_path = "/var/log/chimera-log/can-bus.log";
    }

    /* Ensure the parent directory exists. */
    {
        char parent[PATH_MAX];
        size_t len = strlen(g_log_path);
        if (len > 0 && len < sizeof(parent)) {
            memcpy(parent, g_log_path, len + 1);
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

    g_log = fopen(g_log_path, "a");
    if (!g_log) {
        perror("fopen log");
        return 1;
    }
    fprintf(stderr, "[can] logging to %s\n", g_log_path);

    /* Each thread independently logs its own source (SocketCAN can0 /
     * FreeRTOS IVSHMEM5). If one source is unavailable at startup (e.g.
     * can0 doesn't exist yet, or the FreeRTOS CAN ivshmem channel never
     * publishes its magic), that thread logs a message to stderr and
     * returns early, while the other thread keeps running — the daemon
     * intentionally stays alive in this degraded single-source mode rather
     * than exiting, since partial CAN-bus logging is still useful. */
    pthread_t t_sock, t_shm;
    pthread_create(&t_sock, NULL, socketcan_thread, (void *)ifname);
    pthread_create(&t_shm, NULL, ivshmem_thread, NULL);
    pthread_join(t_sock, NULL);
    pthread_join(t_shm, NULL);

    fclose(g_log);
    return 0;
}
