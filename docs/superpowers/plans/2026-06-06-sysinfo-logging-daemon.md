# Linux Sysinfo Logging Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `hello-{arm,riscv,mips}-linux` with `syslog-{arm,riscv,mips}-linux` daemons that collect CPU load, free memory, and uptime from `/proc` and send them as periodic ivshmem messages to FreeRTOS.

**Architecture:** New `linux_syslog.c` replaces `linux_hello.c`. It reads `/proc/loadavg`, `/proc/meminfo`, and `/proc/uptime` and formats a compact sysinfo string (`ld=0.25 mf=512M up=1234s`) into the 64-byte `text` field of `struct hsoc_hello_msg`. The existing `hello_proto.h` wire format and FreeRTOS firmware are unchanged — FreeRTOS sees the same HELLO/ACK exchange, just with sysinfo text. Loop interval defaults to 5 s and is overridable via `SYSLOG_INTERVAL_SEC`.

**Tech Stack:** C99, existing `hello_proto.h`, Alpine/Debian Linux `/proc` filesystem, aarch64/riscv64/mipsel cross-compilers.

---

## File Map

| Action | File |
|--------|------|
| Create | `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c` |
| Create | `contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh` |
| Delete | `contrib/heterogeneous-soc/freertos-showcase/linux_hello.c` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/Makefile` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/.gitignore` |
| Modify | `scripts/heterogeneous-soc/common.sh` (lines 96–99) |
| Modify | `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` (lines 103, 161–167) |
| Modify | `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh` (lines 186, 194–198) |

---

## Task 1: Write format test harness

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh`

- [ ] **Step 1.1: Create test script**

```bash
#!/usr/bin/env bash
# Verifies syslog-arm-linux outputs the expected sysinfo format.
# Run on Linux with cross-compiled syslog-arm-linux present.
# Exit 77 = SKIP (binary not built yet).
set -euo pipefail
SHOWCASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SHOWCASE_DIR}/syslog-arm-linux"

if [[ ! -f "${BINARY}" ]]; then
    echo "SKIP: ${BINARY} not built"
    exit 77
fi

TMP_SHM=$(mktemp)
dd if=/dev/zero of="${TMP_SHM}" bs=1M count=64 status=none
chmod 600 "${TMP_SHM}"

OUTPUT=$(timeout 8 "${BINARY}" "${TMP_SHM}" 2>/dev/null | head -1 || true)
rm -f "${TMP_SHM}"

if echo "${OUTPUT}" | grep -qE '\[arm-linux\] SYSINFO #0 ld=[0-9]+\.[0-9]+ mf=[0-9]+M up=[0-9]+s'; then
    echo "PASS: sysinfo format correct"
    echo "  output: ${OUTPUT}"
else
    echo "FAIL: unexpected output format"
    echo "  got: ${OUTPUT}"
    exit 1
fi
```

Write this content to `contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh`.

- [ ] **Step 1.2: Mark executable**

```bash
chmod +x contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh
```

- [ ] **Step 1.3: Run test — verify SKIP (binary not built yet)**

```bash
bash contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh; echo "exit: $?"
```

Expected output: `SKIP: .../syslog-arm-linux not built` and `exit: 77`

- [ ] **Step 1.4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh
git commit -m "test: add syslog sysinfo format verification script"
```

---

## Task 2: Implement linux_syslog.c

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c`

- [ ] **Step 2.1: Write linux_syslog.c**

```c
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

#define HSOC_BAR2_SIZE   (64U * 1024U * 1024U)
#define HSOC_VENDOR_ID   "0x1af4"
#define HSOC_STATS_MAGIC 0x53544154U

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

static float read_loadavg_1min(void)
{
    char line[64];
    float v = 0.0f;
    if (read_first_line("/proc/loadavg", line, sizeof(line)))
        sscanf(line, "%f", &v);
    return v;
}

static unsigned long read_memfree_mb(void)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    char line[128];
    unsigned long kb = 0;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "MemFree: %lu kB", &kb) == 1) break;
    }
    fclose(f);
    return kb / 1024;
}

static unsigned long read_uptime_sec(void)
{
    char line[64];
    unsigned long v = 0;
    if (read_first_line("/proc/uptime", line, sizeof(line)))
        sscanf(line, "%lu", &v);
    return v;
}

static void build_sysinfo_text(char *buf, size_t n)
{
    snprintf(buf, n, "ld=%.2f mf=%luM up=%lus",
             read_loadavg_1min(), read_memfree_mb(), read_uptime_sec());
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
    while (*flag != expected)
        __sync_synchronize();
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

        if (magic == HSOC_STATS_MAGIC) continue;

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
    shm->linux_to_freertos.flag = 0;
    shm->freertos_to_linux.flag = 0;

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

        printf("[%s] SYSINFO #%" PRIu32 " %s\n", HSOC_SENDER_LABEL, seq, msg.text);
        fflush(stdout);

        wait_for_flag(&shm->freertos_to_linux.flag, 1);
        shm_read(&ack, &shm->freertos_to_linux.msg, sizeof(ack));
        __sync_synchronize();
        shm->freertos_to_linux.flag = 0;

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

        printf("[%s] ACK   #%" PRIu32 " freertos_tick=%lld.%09lld\n",
               HSOC_SENDER_LABEL, ack.seq,
               (long long)ack.ts_sec, (long long)ack.ts_nsec);
        fflush(stdout);

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
    unsigned int interval = (interval_str && atoi(interval_str) >= 1)
                            ? (unsigned)atoi(interval_str) : 5;

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
```

Write this content to `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c`.

- [ ] **Step 2.2: Confirm file exists**

```bash
wc -l contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c
```

Expected: `~155 contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c`

---

## Task 3: Update Makefile

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 3.1: Verify Makefile still has hello targets (pre-edit check)**

```bash
grep -c "HELLO_TARGETS" contrib/heterogeneous-soc/freertos-showcase/Makefile
```

Expected: `1`

- [ ] **Step 3.2: Apply Makefile edits**

Replace the `HELLO_TARGETS` block (lines 21–31 currently):

```makefile
HELLO_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
HELLO_TARGETS += hello-arm-linux linux-arm-stats
endif
ifneq ($(HAVE_CC_RISCV),)
HELLO_TARGETS += hello-riscv-linux
endif
ifneq ($(HAVE_CC_MIPS),)
HELLO_TARGETS += hello-mips-linux
endif
```

With:

```makefile
SYSLOG_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
SYSLOG_TARGETS += syslog-arm-linux linux-arm-stats
endif
ifneq ($(HAVE_CC_RISCV),)
SYSLOG_TARGETS += syslog-riscv-linux
endif
ifneq ($(HAVE_CC_MIPS),)
SYSLOG_TARGETS += syslog-mips-linux
endif
```

Replace the `all:` target block:

```makefile
all: $(HELLO_TARGETS) freertos-riscv-demo.elf
ifeq ($(HAVE_CC_ARM),)
	$(warning CC_ARM=$(CC_ARM) not found — hello-arm-linux and linux-arm-stats skipped)
endif
ifeq ($(HAVE_CC_RISCV),)
	$(warning CC_RISCV=$(CC_RISCV) not found — hello-riscv-linux skipped)
endif
ifeq ($(HAVE_CC_MIPS),)
	$(warning CC_MIPS=$(CC_MIPS) not found — hello-mips-linux skipped)
endif
```

With:

```makefile
all: $(SYSLOG_TARGETS) freertos-riscv-demo.elf
ifeq ($(HAVE_CC_ARM),)
	$(warning CC_ARM=$(CC_ARM) not found — syslog-arm-linux and linux-arm-stats skipped)
endif
ifeq ($(HAVE_CC_RISCV),)
	$(warning CC_RISCV=$(CC_RISCV) not found — syslog-riscv-linux skipped)
endif
ifeq ($(HAVE_CC_MIPS),)
	$(warning CC_MIPS=$(CC_MIPS) not found — syslog-mips-linux skipped)
endif
```

Replace the three `hello-*-linux` build rules:

```makefile
hello-arm-linux: linux_hello.c hello_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"arm-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_ARM_LINUX \
	  -o $@ linux_hello.c

hello-riscv-linux: linux_hello.c hello_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"riscv-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_RISCV_LINUX \
	  -o $@ linux_hello.c

hello-mips-linux: linux_hello.c hello_proto.h
	$(CC_MIPS) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"mips-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_MIPS_LINUX \
	  -o $@ linux_hello.c
```

With:

```makefile
syslog-arm-linux: linux_syslog.c hello_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"arm-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_ARM_LINUX \
	  -o $@ linux_syslog.c

syslog-riscv-linux: linux_syslog.c hello_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"riscv-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_RISCV_LINUX \
	  -o $@ linux_syslog.c

syslog-mips-linux: linux_syslog.c hello_proto.h
	$(CC_MIPS) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"mips-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_MIPS_LINUX \
	  -o $@ linux_syslog.c
```

Replace the `clean` target:

```makefile
clean:
	rm -f $(HELLO_TARGETS) freertos-riscv-demo.elf
```

With:

```makefile
clean:
	rm -f $(SYSLOG_TARGETS) freertos-riscv-demo.elf
```

- [ ] **Step 3.3: Verify the edits**

```bash
grep -E "SYSLOG_TARGETS|syslog-(arm|riscv|mips)-linux" \
    contrib/heterogeneous-soc/freertos-showcase/Makefile
```

Expected: 8+ lines including `SYSLOG_TARGETS :=`, `syslog-arm-linux: linux_syslog.c hello_proto.h`, etc.

```bash
grep -c "HELLO_TARGETS\|hello-arm-linux\|hello-riscv-linux\|hello-mips-linux\|linux_hello" \
    contrib/heterogeneous-soc/freertos-showcase/Makefile
```

Expected: `0` (no remaining hello references)

- [ ] **Step 3.4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c \
        contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "feat: replace hello programs with sysinfo logging daemon"
```

---

## Task 4: Build and run format test (Lima only)

> Run inside the Lima `qemu-dev` VM where cross-compilers are installed.

**Files:** (build outputs only)

- [ ] **Step 4.1: Build syslog-arm-linux**

```bash
make -C contrib/heterogeneous-soc/freertos-showcase/ syslog-arm-linux
```

Expected: `aarch64-linux-gnu-gcc -O2 ... -o syslog-arm-linux linux_syslog.c` with no errors.

- [ ] **Step 4.2: Run format test — expect PASS**

```bash
bash contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh
```

Expected:
```
PASS: sysinfo format correct
  output: [arm-linux] SYSINFO #0 ld=0.XX mf=XXXM up=XXXs
```

The daemon prints SYSINFO before waiting for FreeRTOS ACK, so `head -1` captures the line within the 8 s timeout even though no FreeRTOS is running.

- [ ] **Step 4.3: Build all syslog targets**

```bash
make -C contrib/heterogeneous-soc/freertos-showcase/ clean all
```

Expected: Produces `syslog-arm-linux`, `syslog-riscv-linux`, `syslog-mips-linux`, `linux-arm-stats`, `freertos-riscv-demo.elf`. Missing compilers emit warnings (not errors).

---

## Task 5: Update .gitignore

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/.gitignore`

- [ ] **Step 5.1: Replace hello entries with syslog entries**

Current `.gitignore`:
```
# Built binaries — only source files are tracked
freertos-riscv-demo.elf
hello-arm-linux
hello-riscv-linux
hello-mips-linux
linux-arm-stats
```

Updated `.gitignore`:
```
# Built binaries — only source files are tracked
freertos-riscv-demo.elf
syslog-arm-linux
syslog-riscv-linux
syslog-mips-linux
linux-arm-stats
```

- [ ] **Step 5.2: Verify**

```bash
cat contrib/heterogeneous-soc/freertos-showcase/.gitignore
```

Expected: No `hello-*-linux` entries; three `syslog-*-linux` entries present.

---

## Task 6: Update common.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh` (lines 96–99)

- [ ] **Step 6.1: Replace HELLO_*_BINARY variables with SYSLOG_*_BINARY**

Replace lines 96–99:
```bash
HELLO_ARM_BINARY="${HELLO_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-arm-linux}"
HELLO_RISCV_BINARY="${HELLO_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-riscv-linux}"
HELLO_MIPS_BINARY="${HELLO_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-mips-linux}"
LINUX_ARM_STATS_BINARY="${LINUX_ARM_STATS_BINARY:-${FREERTOS_SHOWCASE_DIR}/linux-arm-stats}"
```

With:
```bash
SYSLOG_ARM_BINARY="${SYSLOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/syslog-arm-linux}"
SYSLOG_RISCV_BINARY="${SYSLOG_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/syslog-riscv-linux}"
SYSLOG_MIPS_BINARY="${SYSLOG_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/syslog-mips-linux}"
LINUX_ARM_STATS_BINARY="${LINUX_ARM_STATS_BINARY:-${FREERTOS_SHOWCASE_DIR}/linux-arm-stats}"
```

- [ ] **Step 6.2: Verify**

```bash
grep -n "SYSLOG_\|HELLO_" scripts/heterogeneous-soc/common.sh
```

Expected: Three `SYSLOG_*_BINARY` lines; zero `HELLO_*_BINARY` lines.

---

## Task 7: Update guest-run-phase5-tmux.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`

- [ ] **Step 7.1: Update comment on line 103**

Replace:
```bash
# Wait for the guest shell to be ready, then run the hello binary.
```

With:
```bash
# Wait for the guest shell to be ready, then run the syslog daemon.
```

- [ ] **Step 7.2: Update auto_login_and_run calls (lines 161–167)**

Replace:
```bash
auto_login_and_run "$SESSION:0.5" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "/mnt/pingpong/freertos-showcase/hello-arm-linux" &
auto_login_and_run "$SESSION:0.6" \
    "/mnt/pingpong/freertos-showcase/hello-riscv-linux" &
auto_login_and_run "$SESSION:0.7" \
    "cp /mnt/pingpong/freertos-showcase/hello-mips-linux /tmp/hello-mips-linux && /tmp/hello-mips-linux" &
```

With:
```bash
auto_login_and_run "$SESSION:0.5" \
    "cp /mnt/pingpong/freertos-showcase/linux-arm-stats /tmp/ && /tmp/linux-arm-stats &" \
    "/mnt/pingpong/freertos-showcase/syslog-arm-linux" &
auto_login_and_run "$SESSION:0.6" \
    "/mnt/pingpong/freertos-showcase/syslog-riscv-linux" &
auto_login_and_run "$SESSION:0.7" \
    "cp /mnt/pingpong/freertos-showcase/syslog-mips-linux /tmp/syslog-mips-linux && /tmp/syslog-mips-linux" &
```

- [ ] **Step 7.3: Verify no remaining hello binary references**

```bash
grep -n "hello-arm-linux\|hello-riscv-linux\|hello-mips-linux" \
    scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
```

Expected: No output.

---

## Task 8: Update guest-run-chimera-showcase.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh`

- [ ] **Step 8.1: Update binary check loop (line 186)**

Replace:
```bash
for bin in "${HELLO_ARM_BINARY}" "${HELLO_RISCV_BINARY}" "${HELLO_MIPS_BINARY}" "${LINUX_ARM_STATS_BINARY}"; do
```

With:
```bash
for bin in "${SYSLOG_ARM_BINARY}" "${SYSLOG_RISCV_BINARY}" "${SYSLOG_MIPS_BINARY}" "${LINUX_ARM_STATS_BINARY}"; do
```

- [ ] **Step 8.2: Update MIPS missing-binary warning (lines 194–198)**

Replace:
```bash
    if [[ ! -f "${HELLO_MIPS_BINARY}" ]]; then
        printf '\n\033[1;33mWARNING:\033[0m hello-mips-linux was not built.\n'
        printf '  The MIPS guest will boot but the hello binary will not be present.\n'
        printf '  Install gcc-mipsel-linux-gnu and re-run to fix.\n\n'
    fi
```

With:
```bash
    if [[ ! -f "${SYSLOG_MIPS_BINARY}" ]]; then
        printf '\n\033[1;33mWARNING:\033[0m syslog-mips-linux was not built.\n'
        printf '  The MIPS guest will boot but the syslog daemon will not be present.\n'
        printf '  Install gcc-mipsel-linux-gnu and re-run to fix.\n\n'
    fi
```

- [ ] **Step 8.3: Verify no remaining HELLO_*_BINARY references**

```bash
grep -n "HELLO_\|hello-arm\|hello-riscv\|hello-mips" \
    scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

Expected: No output.

---

## Task 9: Remove linux_hello.c and commit all script changes

**Files:**
- Delete: `contrib/heterogeneous-soc/freertos-showcase/linux_hello.c`

- [ ] **Step 9.1: Verify no remaining references to linux_hello.c**

```bash
grep -rn "linux_hello\|hello-arm-linux\|hello-riscv-linux\|hello-mips-linux\|HELLO_ARM_BINARY\|HELLO_RISCV_BINARY\|HELLO_MIPS_BINARY" \
    scripts/ contrib/heterogeneous-soc/freertos-showcase/ \
    --include="*.sh" --include="*.c" --include="*.h" \
    --include="Makefile" --include=".gitignore"
```

Expected: No output.

- [ ] **Step 9.2: Remove linux_hello.c**

```bash
git rm contrib/heterogeneous-soc/freertos-showcase/linux_hello.c
```

- [ ] **Step 9.3: Stage and commit all remaining changes**

```bash
git add \
    contrib/heterogeneous-soc/freertos-showcase/.gitignore \
    scripts/heterogeneous-soc/common.sh \
    scripts/heterogeneous-soc/guest-run-phase5-tmux.sh \
    scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
git commit -m "feat: update scripts and cleanup — syslog daemons replace hello programs"
```

- [ ] **Step 9.4: Final grep for stray references**

```bash
grep -rn "hello-arm-linux\|hello-riscv-linux\|hello-mips-linux\|linux_hello\|HELLO_ARM\|HELLO_RISCV\|HELLO_MIPS" \
    scripts/ contrib/ \
    --include="*.sh" --include="*.c" --include="*.h" \
    --include="Makefile" --include=".gitignore" \
    | grep -v "^Binary"
```

Expected: No output (CLAUDE.md references to the old binaries are documentation and do not need updating here).

---

## Self-Review

**Spec coverage:**
- ✓ Replaced `hello-{arm,riscv,mips}-linux` with `syslog-{arm,riscv,mips}-linux`
- ✓ Collects CPU load (1-min loadavg from `/proc/loadavg`)
- ✓ Collects free memory (MemFree from `/proc/meminfo`)
- ✓ Collects uptime (seconds from `/proc/uptime`)
- ✓ Sends over ivshmem using unchanged `hello_proto.h` wire format
- ✓ FreeRTOS firmware unchanged
- ✓ Makefile updated
- ✓ All three Linux guest architectures covered
- ✓ Launch scripts updated
- ✓ Old `linux_hello.c` removed
- ✓ `.gitignore` updated

**Protocol compatibility note:** FreeRTOS calls `freertos_ivshmem_poll_hello()` and `freertos_ivshmem_send_ack()` unchanged. The `text` field is not parsed by FreeRTOS — it is only echoed back in the log line `[freertos] received hello from arm-linux`. The sysinfo content is only visible on the Linux guest's stdout.
