# Sysinfo CPU/Memory Cross-Domain Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend each Linux guest's `linux_syslog` daemon to compute aggregate CPU
utilization and used-memory percentage, relay both through FreeRTOS into the stats
snapshot, and print them per-guest in `/var/log/chimera-log/chimera-cross-domain.log`.

**Architecture:** Two new `uint32_t` x100-fixed-point fields (`cpu_pct_x100`,
`mem_used_pct_x100`) are added to the HELLO wire message (`hello_proto.h`, version bumped
to 2) and six mirrored per-guest fields to the FreeRTOS stats snapshot
(`stats_proto.h`) — purely additive struct changes. `linux_syslog.c` delta-samples
`/proc/stat` and reads `/proc/meminfo` once per loop iteration; `freertos_main.c` stashes
the latest per-sender values (mirroring the existing per-sender count tracking) and
copies them into the periodic snapshot write; `linux_stats.c` prints them in
`log_snapshot`.

**Tech Stack:** C99, existing `hello_proto.h`/`stats_proto.h` wire protocols,
`/proc/stat` + `/proc/meminfo`, aarch64/riscv64/mipsel cross-compilers (on the Lima VM),
FreeRTOS firmware (RISC-V).

---

## File Map

| Action | File |
|--------|------|
| Modify | `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/stats_proto.h` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/linux_stats.c` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh` |

---

## Task 1: Extend wire protocol headers

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h:7,22-31`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/stats_proto.h:24-33`

- [x] **Step 1.1: Bump HSOC_PROTO_VERSION and add fields to hsoc_hello_msg**

In `hello_proto.h`, change line 7 from:
```c
#define HSOC_PROTO_VERSION 1U
```
to:
```c
#define HSOC_PROTO_VERSION 2U
```

Then replace the struct (lines 22-31):
```c
struct hsoc_hello_msg {
    uint32_t magic;
    uint16_t version;
    uint16_t msg_type;
    uint32_t seq;
    uint32_t sender_id;
    int64_t ts_sec;
    int64_t ts_nsec;
    char text[HSOC_TEXT_LEN];
};
```
with:
```c
struct hsoc_hello_msg {
    uint32_t magic;
    uint16_t version;
    uint16_t msg_type;
    uint32_t seq;
    uint32_t sender_id;
    int64_t ts_sec;
    int64_t ts_nsec;
    uint32_t cpu_pct_x100;       /* aggregate CPU busy %, x100 fixed-point (1234 = 12.34%) */
    uint32_t mem_used_pct_x100;  /* used-memory %, x100 fixed-point */
    char text[HSOC_TEXT_LEN];
};
```

This insertion point keeps every field naturally aligned: the struct is 32 bytes through
`ts_nsec` (all multiples of 8), the two new `uint32_t` fields add 8 bytes (ending at 40,
still 8-aligned), and `text` (a `char` array needing no alignment) follows — no padding
is introduced or removed anywhere in the layout.

- [x] **Step 1.2: Add per-guest CPU/mem fields to hsoc_stats_snapshot**

In `stats_proto.h`, replace the struct (lines 24-33):
```c
struct hsoc_stats_snapshot {
    uint32_t          magic;       /* HSOC_STATS_MAGIC — identifies this BAR2 */
    volatile uint32_t generation;  /* monotonically incremented by FreeRTOS */
    uint32_t          arm_count;   /* total HELLOs received from ARM-Linux */
    uint32_t          riscv_count; /* total HELLOs received from RISCV-Linux */
    uint32_t          mips_count;  /* total HELLOs received from MIPS-Linux */
    uint32_t          pad;
    int64_t           tick_sec;    /* FreeRTOS tick time of this snapshot */
    int64_t           tick_nsec;
};
```
with:
```c
struct hsoc_stats_snapshot {
    uint32_t          magic;       /* HSOC_STATS_MAGIC — identifies this BAR2 */
    volatile uint32_t generation;  /* monotonically incremented by FreeRTOS */
    uint32_t          arm_count;   /* total HELLOs received from ARM-Linux */
    uint32_t          riscv_count; /* total HELLOs received from RISCV-Linux */
    uint32_t          mips_count;  /* total HELLOs received from MIPS-Linux */
    uint32_t          pad;
    int64_t           tick_sec;    /* FreeRTOS tick time of this snapshot */
    int64_t           tick_nsec;
    uint32_t          arm_cpu_pct_x100;   /* latest ARM-Linux CPU busy %, x100 */
    uint32_t          arm_mem_pct_x100;   /* latest ARM-Linux used-mem %, x100 */
    uint32_t          riscv_cpu_pct_x100; /* latest RISCV-Linux CPU busy %, x100 */
    uint32_t          riscv_mem_pct_x100; /* latest RISCV-Linux used-mem %, x100 */
    uint32_t          mips_cpu_pct_x100;  /* latest MIPS-Linux CPU busy %, x100 */
    uint32_t          mips_mem_pct_x100;  /* latest MIPS-Linux used-mem %, x100 */
};
```

These new fields are appended at the end (8-byte-aligned offset after `tick_nsec`), so
existing fields keep their offsets — `magic`, `generation`, and the three `*_count`
fields that current readers already depend on are untouched.

- [x] **Step 1.3: Verify both headers declare the new fields**

Run:
```bash
grep -c "_pct_x100" contrib/heterogeneous-soc/freertos-showcase/hello_proto.h contrib/heterogeneous-soc/freertos-showcase/stats_proto.h
```
Expected:
```
contrib/heterogeneous-soc/freertos-showcase/hello_proto.h:2
contrib/heterogeneous-soc/freertos-showcase/stats_proto.h:6
```

- [x] **Step 1.4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/hello_proto.h contrib/heterogeneous-soc/freertos-showcase/stats_proto.h
git commit -m "feat: add CPU/memory fields to HELLO and stats snapshot wire protocols"
```

---

## Task 2: Collect CPU/memory in linux_syslog.c and fix the format self-test

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c`
- Modify: `contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh`

This task also fixes a pre-existing bug in `test-syslog-format.sh`: commit `313255c8aa`
moved the `SYSINFO` print to *after* `wait_for_flag()` (which spins forever waiting for a
FreeRTOS ACK that a fake/zeroed shared-memory file never provides — `main_loop` even
resets `freertos_to_linux.flag = 0` at startup, so pre-populating an ACK doesn't help
either) and gated it to every 5th send (so the first print shows `seq=4`, not `seq=0` as
the test's regex requires). The test can currently only time out and FAIL. The fix adds a
`SYSLOG_SELFTEST` self-test mode that prints one formatted SYSINFO line and exits —
sidestepping the ivshmem/ACK exchange entirely, which is also exactly what's needed to
verify the new `cpu=`/`mem=` fields format without a live FreeRTOS responder.

- [x] **Step 2.1: Rewrite test-syslog-format.sh to use self-test mode and the new format**

Replace the entire file content with:
```bash
#!/usr/bin/env bash
# Verifies syslog-arm-linux's SYSINFO line format via its self-test mode
# (SYSLOG_SELFTEST=1 prints one line and exits — no ivshmem/FreeRTOS needed).
# Run on Linux with cross-compiled syslog-arm-linux present.
# Exit 77 = SKIP (binary not built yet).
set -euo pipefail
SHOWCASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SHOWCASE_DIR}/syslog-arm-linux"

if [[ ! -f "${BINARY}" ]]; then
    echo "SKIP: ${BINARY} not built"
    exit 77
fi

OUTPUT=$(SYSLOG_SELFTEST=1 timeout 8 "${BINARY}" 2>/dev/null | grep -m1 "SYSINFO" || true)

if echo "${OUTPUT}" | grep -qE '\[arm-linux\] SYSINFO #0 ld=[0-9]+\.[0-9]+ cpu=[0-9]+\.[0-9]+% mem=[0-9]+\.[0-9]+% mf=[0-9]+M up=[0-9]+s'; then
    echo "PASS: sysinfo format correct"
    echo "  output: ${OUTPUT}"
else
    echo "FAIL: unexpected output format"
    echo "  got: ${OUTPUT}"
    exit 1
fi
```

- [x] **Step 2.2: Run the test — verify it still SKIPs (binary not yet rebuilt)**

Run: `bash contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh; echo "exit: $?"`
Expected: `SKIP: .../syslog-arm-linux not built` and `exit: 77` (cross-compilers and the
prebuilt binary live on the Lima VM, not this host — see `CLAUDE.md`)

- [x] **Step 2.3: Add CPU and memory sampling functions**

In `linux_syslog.c`, insert the following two functions immediately after
`read_uptime_sec` (after its closing brace, before `build_sysinfo_text`):
```c
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

    uint32_t pct_x100 = 0;
    if (have_prev && total > prev_total) {
        unsigned long long dtotal = total - prev_total;
        unsigned long long didle = busy_idle - prev_idle;
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
```

`read_cpu_pct_x100` keeps delta-sampling state in `static` variables across calls — CPU
busy % is a rate and needs two `/proc/stat` samples with a time delta between them. The
first call has no baseline and returns `0`; subsequent calls (one per `main_loop`
iteration, every `interval` seconds) compute the percentage from the delta since the
previous call.

- [x] **Step 2.4: Update build_sysinfo_text to take and print the new metrics**

Replace:
```c
static void build_sysinfo_text(char *buf, size_t n)
{
    unsigned int ld_int, ld_frac;
    read_loadavg_fixed(&ld_int, &ld_frac);
    snprintf(buf, n, "ld=%u.%02u mf=%uM up=%us",
             ld_int, ld_frac, read_memfree_mb(), read_uptime_sec());
}
```
with:
```c
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
```

`cpu_pct_x100`/`mem_pct_x100` are now **parameters** rather than computed internally —
this matters because `read_cpu_pct_x100` is stateful (see Step 2.3): calling it a second
time within the same loop iteration would consume the "current sample" as its own
baseline before the real next iteration runs, corrupting the rate calculation. Each
metric must be sampled exactly once per iteration and the value reused everywhere it's
needed (wire field and text rendering alike).

- [x] **Step 2.5: Sample once per iteration, populate the new wire fields, and pass values into build_sysinfo_text**

In `main_loop`, replace:
```c
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
```
with:
```c
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
```

- [x] **Step 2.6: Add SYSLOG_SELFTEST mode to main()**

Replace:
```c
int main(int argc, char *argv[])
{
    const char *bar2_path = argc > 1 ? argv[1] : find_ivshmem_resource();
```
with:
```c
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
```

This is an entirely separate, early-exit code path — it never touches BAR2/ivshmem, so
it cannot affect the production HELLO/ACK loop, and it gives the format test a
deterministic, instantaneous way to check `build_sysinfo_text`'s output.

- [x] **Step 2.7: Run the format test again — still expect SKIP on this host**

Run: `bash contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh; echo "exit: $?"`
Expected: `SKIP: .../syslog-arm-linux not built` and `exit: 77`

This confirms the rewritten script still runs cleanly (no syntax errors) — full `PASS`
verification against the cross-compiled binary happens in Task 5 on the Lima VM.

- [x] **Step 2.8: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh
git commit -m "feat: collect CPU/memory usage in linux_syslog and fix format self-test"
```

---

## Task 2a: Fix CPU idle-delta underflow found in code review

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c` (`read_cpu_pct_x100`, added in Task 2)

Code review of Task 2's `read_cpu_pct_x100` (landed in `fe177a2372`) found a bug before
Task 3 began: the `total > prev_total` guard ensures `dtotal > 0` but does not guarantee
`didle <= dtotal`. If the aggregate idle/iowait counters in `/proc/stat` decrease between
samples — a known edge case around CPU hotplug events on some kernels — `busy_idle -
prev_idle` underflows to a huge `unsigned long long`, and the subsequent `dtotal - didle`
underflows again, producing a garbage `pct_x100` that can wildly exceed 100% (reproduced
as `pct_x100 = 11111`). Landed as `ae44c9d7ae`, between the Task 2 and Task 3 commits.

- [x] **Step 2a.1: Clamp the idle delta against underflow**

Replace:
```c
    uint32_t pct_x100 = 0;
    if (have_prev && total > prev_total) {
        unsigned long long dtotal = total - prev_total;
        unsigned long long didle = busy_idle - prev_idle;
        pct_x100 = (uint32_t)(10000ULL * (dtotal - didle) / dtotal);
    }
```
with:
```c
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
```

`didle` is clamped twice: first against underflow in the subtraction itself (defaulting to
`0` when `busy_idle < prev_idle`), then against exceeding `dtotal` (busy time can never be
negative, so the idle delta can never legitimately exceed the total delta). Both guards
are needed — the first prevents wraparound in the subtraction itself, the second prevents
a still-too-large `didle` (e.g. if `busy_idle` legitimately grew a lot while `prev_idle`
lagged) from underflowing `dtotal - didle`.

- [x] **Step 2a.2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c
git commit -m "fix: clamp CPU idle delta to prevent underflow in read_cpu_pct_x100"
```

---

## Task 3: Relay per-guest CPU/memory through FreeRTOS

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c:39-45,161-175,177-195,270-279`

- [x] **Step 3.1: Add per-sender CPU/mem static state**

Replace (lines 39-45):
```c
static uint32_t arm_count;
static uint32_t riscv_count;
static uint32_t mips_count;
static uint32_t stats_tick;
static TickType_t arm_last_hello_ticks;
static TickType_t riscv_last_hello_ticks;
static TickType_t mips_last_hello_ticks;
```
with:
```c
static uint32_t arm_count;
static uint32_t riscv_count;
static uint32_t mips_count;
static uint32_t arm_cpu_pct, arm_mem_pct;
static uint32_t riscv_cpu_pct, riscv_mem_pct;
static uint32_t mips_cpu_pct, mips_mem_pct;
static uint32_t stats_tick;
static TickType_t arm_last_hello_ticks;
static TickType_t riscv_last_hello_ticks;
static TickType_t mips_last_hello_ticks;
```

These hold each guest's most recently received CPU%/mem% between snapshot writes — same
lifetime and update cadence as the existing `arm_count`/`riscv_count`/`mips_count`.

- [x] **Step 3.2: Extend maybe_service_link to capture cpu/mem from each HELLO**

Replace:
```c
static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count,
                               TickType_t *last_hello_ticks)
{
    struct hsoc_hello_msg hello;
    int64_t ts_sec;
    int64_t ts_nsec;

    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }

    tick_to_timestamp(&ts_sec, &ts_nsec);
    log_uart(HSOC_LOG_VERBOSE, log_message);
    freertos_ivshmem_send_ack(link, hello.seq, ts_sec, ts_nsec);
    (*count)++;
    *last_hello_ticks = xTaskGetTickCount();
}
```
with:
```c
static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count,
                               uint32_t *cpu_pct,
                               uint32_t *mem_pct,
                               TickType_t *last_hello_ticks)
{
    struct hsoc_hello_msg hello;
    int64_t ts_sec;
    int64_t ts_nsec;

    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }

    tick_to_timestamp(&ts_sec, &ts_nsec);
    log_uart(HSOC_LOG_VERBOSE, log_message);
    freertos_ivshmem_send_ack(link, hello.seq, ts_sec, ts_nsec);
    (*count)++;
    *cpu_pct = hello.cpu_pct_x100;
    *mem_pct = hello.mem_used_pct_x100;
    *last_hello_ticks = xTaskGetTickCount();
}
```

- [x] **Step 3.3: Update the three call sites in showcase_task's loop**

Replace:
```c
    for (;;) {
        maybe_service_link(&arm_link,
                           "[freertos] received hello from arm-linux\n",
                           &arm_count, &arm_last_hello_ticks);
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n",
                           &riscv_count, &riscv_last_hello_ticks);
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n",
                           &mips_count, &mips_last_hello_ticks);
```
with:
```c
    for (;;) {
        maybe_service_link(&arm_link,
                           "[freertos] received hello from arm-linux\n",
                           &arm_count, &arm_cpu_pct, &arm_mem_pct, &arm_last_hello_ticks);
        maybe_service_link(&riscv_link,
                           "[freertos] received hello from riscv-linux\n",
                           &riscv_count, &riscv_cpu_pct, &riscv_mem_pct, &riscv_last_hello_ticks);
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n",
                           &mips_count, &mips_cpu_pct, &mips_mem_pct, &mips_last_hello_ticks);
```

- [x] **Step 3.4: Copy the new per-sender values into the stats snapshot**

Replace:
```c
static void write_stats_snapshot(void)
{
    int64_t ts_sec, ts_nsec;

    stats_shmem->arm_count   = arm_count;
    stats_shmem->riscv_count = riscv_count;
    stats_shmem->mips_count  = mips_count;
    tick_to_timestamp(&ts_sec, &ts_nsec);
    stats_shmem->tick_sec  = ts_sec;
    stats_shmem->tick_nsec = ts_nsec;
    __sync_synchronize();
    stats_shmem->generation = stats_shmem->generation + 1;
    __sync_synchronize();
    log_uart(HSOC_LOG_VERBOSE, "[freertos] stats snapshot written\n");
}
```
with:
```c
static void write_stats_snapshot(void)
{
    int64_t ts_sec, ts_nsec;

    stats_shmem->arm_count   = arm_count;
    stats_shmem->riscv_count = riscv_count;
    stats_shmem->mips_count  = mips_count;
    tick_to_timestamp(&ts_sec, &ts_nsec);
    stats_shmem->tick_sec  = ts_sec;
    stats_shmem->tick_nsec = ts_nsec;
    stats_shmem->arm_cpu_pct_x100   = arm_cpu_pct;
    stats_shmem->arm_mem_pct_x100   = arm_mem_pct;
    stats_shmem->riscv_cpu_pct_x100 = riscv_cpu_pct;
    stats_shmem->riscv_mem_pct_x100 = riscv_mem_pct;
    stats_shmem->mips_cpu_pct_x100  = mips_cpu_pct;
    stats_shmem->mips_mem_pct_x100  = mips_mem_pct;
    __sync_synchronize();
    stats_shmem->generation = stats_shmem->generation + 1;
    __sync_synchronize();
    log_uart(HSOC_LOG_VERBOSE, "[freertos] stats snapshot written\n");
}
```

All new fields are written before the `__sync_synchronize()` + `generation` increment —
identical write-protocol discipline to the existing fields, per the struct's documented
write protocol.

- [x] **Step 3.5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "feat: relay per-guest CPU/memory usage through FreeRTOS stats snapshot"
```

---

## Task 4: Print CPU/memory in the cross-domain log

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/linux_stats.c:123-146`

- [x] **Step 4.1: Extend log_snapshot to print the new per-guest fields**

Replace:
```c
static void log_snapshot(FILE *log, const struct hsoc_stats_snapshot *snap)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    struct tm *tm_info = gmtime(&ts.tv_sec);
    char timebuf[32];
    strftime(timebuf, sizeof(timebuf), "%Y-%m-%dT%H:%M:%SZ", tm_info);

    fprintf(log,
            "[%s] gen=%" PRIu32
            " arm=%" PRIu32
            " riscv=%" PRIu32
            " mips=%" PRIu32
            " tick=%" PRId64 ".%09" PRId64 "\n",
            timebuf,
            snap->generation,
            snap->arm_count,
            snap->riscv_count,
            snap->mips_count,
            snap->tick_sec,
            snap->tick_nsec);
    fflush(log);
}
```
with:
```c
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
```

This produces lines like:
```
[2026-06-07T12:34:56Z] gen=42 arm=120 cpu=12.34% mem=45.67% riscv=118 cpu=8.90% mem=23.45% mips=115 cpu=3.21% mem=67.89% tick=12345.678901234
```
`%%` in the format string emits a literal `%` (escaping `printf`'s conversion specifier);
`/ 100` and `% 100` split the `_x100` fixed-point integer back into whole and fractional
parts for `%u.%02u` rendering — the same technique `read_loadavg_fixed` already uses on
the Linux side. No floating point in the log writer.

- [x] **Step 4.2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/linux_stats.c
git commit -m "feat: print per-guest CPU/memory usage in cross-domain log"
```

---

## Task 5: Build and verify end-to-end on the Lima VM

**Files:** none — build and integration verification only.

**Status as of this update:** Tasks 1, 2, 2a, 3, and 4 are committed on `HEAD`
(`35829b2dec` … `765fe5bd38`, plus the README sync in `290a828d56`). This task has no
commit of its own (per Step 5.6's note) and no Lima VM is currently running, so its
live-verification steps below remain unchecked pending a fresh run.

- [x] **Step 5.1: Deploy source to the Lima VM**

Run: `bash scripts/heterogeneous-soc/host-install-lima-host.sh`

- [x] **Step 5.2: Rebuild the FreeRTOS showcase binaries**

Run:
```bash
limactl shell qemu-dev -- bash -lc 'cd ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase && make clean && make'
```
Expected: `syslog-arm-linux`, `syslog-riscv-linux`, `syslog-mips-linux`, `linux-arm-stats`,
and `freertos-riscv-demo.elf` all rebuilt with no errors or warnings about the changed
files.

- [x] **Step 5.3: Run the format self-test against the rebuilt binary**

Run:
```bash
limactl shell qemu-dev -- bash ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh
```
Expected:
```
PASS: sysinfo format correct
  output: [arm-linux] SYSINFO #0 ld=X.XX cpu=X.XX% mem=X.XX% mf=XXXM up=XXXs
```

- [x] **Step 5.4: Launch the full showcase**

Run:
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

- [x] **Step 5.5: Confirm all three guests' new fields appear and update in the cross-domain log**

Wait roughly 60 seconds after the showcase reaches steady state (so several stats
snapshots have been logged), then run:
```bash
limactl shell qemu-dev -- ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost \
  'tail -5 /var/log/chimera-log/chimera-cross-domain.log'
```

> **Note (found during execution of this task):** the `localhost:2222` hostfwd address
> above is stale — the Avahi network migration (`2026-06-06-avahi-network`) replaced QEMU
> usermode hostfwd with TAP-bridge networking, so that address now just gets
> `Connection refused`. The working equivalent is to SSH directly to the ARM guest's
> bridge IP from inside the Lima VM, using the host-injected key (see README → "Guest
> Networking & Avahi Discovery"):
> ```bash
> limactl shell qemu-dev -- ssh -i /Users/yhsung/.ssh/id_ed25519 \
>   -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@172.16.100.10 \
>   'tail -5 /var/log/chimera-log/chimera-cross-domain.log'
> ```

Expected: lines matching
```
[<timestamp>] gen=<N> arm=<N> cpu=<N.NN>% mem=<N.NN>% riscv=<N> cpu=<N.NN>% mem=<N.NN>% mips=<N> cpu=<N.NN>% mem=<N.NN>% tick=<N>.<N>
```
with `cpu=`/`mem=` values present for `riscv` and `mips` (not just `arm`) and changing
across consecutive lines — confirming the relay path through FreeRTOS carries live data
from all three guests, not stale zeros.

- [x] **Step 5.6: Tear down**

Run:
```bash
limactl shell qemu-dev -- bash -lc 'pkill qemu-system; rm -f /tmp/*.sock'
```

No commit for this task — it is verification of the binaries already committed in
Tasks 1–4 (and the Task 2a follow-up fix).
