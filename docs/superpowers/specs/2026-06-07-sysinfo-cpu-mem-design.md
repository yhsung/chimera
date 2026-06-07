# Richer Per-Guest Sysinfo: CPU Load and Memory Usage in the Cross-Domain Log

**Date:** 2026-06-07
**Status:** Approved

## Goal

Extend the sysinfo each Linux guest (`syslog-{arm,riscv,mips}-linux`) collects to include
aggregate CPU utilization and memory-used percentage — alongside the existing load average,
free memory, and uptime — and relay those two new metrics through FreeRTOS into the
cross-domain log written by `linux_stats.c` (`/var/log/chimera-log/chimera-cross-domain.log`),
so a single log shows CPU and memory pressure across all three heterogeneous guests
(ARM/RISCV: 4 cores, MIPS: 1 core) side by side.

## Architecture

```
Guest (ARM/RISCV/MIPS)         FreeRTOS                      ARM-Linux
linux_syslog samples       maybe_service_link()          linux_stats polls
/proc/stat + /proc/meminfo  stores latest cpu%/mem%        stats snapshot,
   |                        per sender_id                  log_snapshot()
   v                              |                         writes everything
HELLO{cpu_pct_x100,               v                         to chimera-cross-
      mem_used_pct_x100,    write_stats_snapshot()         domain.log
      ...existing fields}   copies into extended
                            hsoc_stats_snapshot
```

**Data flow:** the existing HELLO/ACK channel carries two new binary fields per message.
FreeRTOS — which already counts HELLOs per sender in `maybe_service_link` — additionally
stashes the latest `cpu_pct_x100`/`mem_used_pct_x100` per sender into static state, then
copies all six values (2 metrics × 3 guests) into the existing periodic stats-snapshot
write. `linux_stats.c` (already polling that snapshot for message counts) prints the new
fields in `log_snapshot`.

No new ivshmem channels, no new shared-memory regions, no new daemons — purely additive
fields on the two existing wire protocols (`hello_proto.h`, `stats_proto.h`).

## Files Changed

| File | Change |
|---|---|
| `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h` | Bump `HSOC_PROTO_VERSION` to 2; add `cpu_pct_x100`/`mem_used_pct_x100` to `hsoc_hello_msg` |
| `contrib/heterogeneous-soc/freertos-showcase/stats_proto.h` | Add 6 per-guest `*_cpu_pct_x100`/`*_mem_pct_x100` fields to `hsoc_stats_snapshot` |
| `contrib/heterogeneous-soc/freertos-showcase/linux_syslog.c` | Sample `/proc/stat` + `/proc/meminfo`; populate new wire fields; extend local SYSINFO text |
| `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Stash per-sender cpu%/mem% in `maybe_service_link`; copy into snapshot in `write_stats_snapshot` |
| `contrib/heterogeneous-soc/freertos-showcase/linux_stats.c` | Extend `log_snapshot` to print the new per-guest fields |
| `contrib/heterogeneous-soc/freertos-showcase/test-syslog-format.sh` | Update regex to require `cpu=`/`mem=` in the SYSINFO line |

## Section 1 — Wire Protocol Changes

### `hello_proto.h`

Bump `HSOC_PROTO_VERSION` from `1` to `2`. Both `linux_syslog` and FreeRTOS firmware are
built from this shared header and FreeRTOS already rejects `msg->version != HSOC_PROTO_VERSION`
in `freertos_ivshmem_poll_hello` — so the bump is a clean simultaneous cut-over with no
migration logic needed.

Insert two `uint32_t` fields between the timestamp and the free-text field — this keeps
every field naturally aligned (no padding shuffles: the struct ends at offset 32 after
`ts_nsec`, adding 8 bytes of `uint32_t` keeps `text` starting at offset 40) and groups
structured numeric fields ahead of the free-form text, matching the existing convention:

```c
#define HSOC_PROTO_VERSION 2U

struct hsoc_hello_msg {
    uint32_t magic;
    uint16_t version;
    uint16_t msg_type;
    uint32_t seq;
    uint32_t sender_id;
    int64_t  ts_sec;
    int64_t  ts_nsec;
    uint32_t cpu_pct_x100;       /* aggregate CPU busy %, x100 fixed-point (1234 = 12.34%) */
    uint32_t mem_used_pct_x100;  /* used-memory %, x100 fixed-point */
    char     text[HSOC_TEXT_LEN];
};
```

Values are `x100`-scaled integers rather than floats — no FPU assumptions cross the wire,
and two decimal digits of precision is plenty for this demo.

### `stats_proto.h`

Add six flat per-guest fields to `hsoc_stats_snapshot`, mirroring the existing flat
`arm_count`/`riscv_count`/`mips_count` style (FreeRTOS firmware deals in plain field
reads/writes, not nested structs):

```c
struct hsoc_stats_snapshot {
    uint32_t          magic;
    volatile uint32_t generation;
    uint32_t          arm_count;
    uint32_t          riscv_count;
    uint32_t          mips_count;
    uint32_t          pad;
    int64_t           tick_sec;
    int64_t           tick_nsec;
    uint32_t          arm_cpu_pct_x100,   arm_mem_pct_x100;    /* NEW */
    uint32_t          riscv_cpu_pct_x100, riscv_mem_pct_x100;  /* NEW */
    uint32_t          mips_cpu_pct_x100,  mips_mem_pct_x100;   /* NEW */
};
```

The existing write/read protocol documented in the struct's header comment is unchanged —
new fields are written via the same volatile-byte-loop discipline before the
`__sync_synchronize()` + `generation` increment.

## Section 2 — Linux-Side Collection (`linux_syslog.c`)

### Aggregate CPU utilization

CPU busy % is a *rate*: it requires two `/proc/stat` samples with a time delta between
them. Rather than adding an extra `sleep()` (which would slow the HELLO cadence), the
daemon samples the aggregate `cpu` line once per loop iteration and keeps the previous
sample in `static` state — the existing `interval`-second loop (default 5s,
`SYSLOG_INTERVAL_SEC`-overridable) is naturally a reasonable sampling window:

```c
static bool have_prev_cpu;
static unsigned long long prev_idle, prev_total;

static uint32_t read_cpu_pct_x100(void)
{
    /* Parse the aggregate "cpu  user nice system idle iowait irq softirq steal" line.
     * total = sum of all fields; idle = idle + iowait. */
    ...
    if (!have_prev_cpu) {
        have_prev_cpu = true;
        prev_idle = idle;
        prev_total = total;
        return 0;  /* no baseline yet — same warm-up behavior loadavg already has */
    }
    unsigned long long delta_total = total - prev_total;
    unsigned long long delta_idle  = idle  - prev_idle;
    uint32_t pct_x100 = delta_total
        ? (uint32_t)(10000ULL * (delta_total - delta_idle) / delta_total)
        : 0;
    prev_idle = idle;
    prev_total = total;
    return pct_x100;
}
```

### Memory usage

`read_mem_used_pct_x100`: read `MemTotal` and `MemAvailable` from `/proc/meminfo`
(`MemAvailable` accounts for reclaimable caches, giving a more accurate "used" picture
than the existing `MemFree`-based reading) and compute:

```c
pct_x100 = (uint32_t)(10000ULL * (mem_total_kb - mem_avail_kb) / mem_total_kb);
```

### Local SYSINFO text

Extend `build_sysinfo_text` so the existing human-readable summary line (printed every 5
sends, captured in tmux/serial logs) shows the new numbers too:

```
ld=0.25 cpu=12.34% mem=56.78% mf=512M up=1234s
```

(46 characters plus terminator — comfortably inside the 64-byte `text` field, with
headroom for larger uptime values.)

Both `cpu_pct_x100`/`mem_used_pct_x100` wire fields are populated with the computed
values in `main_loop` alongside the existing `msg.text` population.

## Section 3 — FreeRTOS Relay (`freertos_main.c`)

`maybe_service_link` already receives the full `hello` struct and increments a per-sender
counter; it gains two more out-parameters mirroring the existing `count` pattern:

```c
static void maybe_service_link(struct freertos_ivshmem_link *link,
                               const char *log_message,
                               uint32_t *count, uint32_t *cpu_pct, uint32_t *mem_pct,
                               TickType_t *last_hello_ticks)
{
    ...
    if (!freertos_ivshmem_poll_hello(link, &hello)) {
        return;
    }
    ...
    *cpu_pct = hello.cpu_pct_x100;
    *mem_pct = hello.mem_used_pct_x100;
    (*count)++;
    *last_hello_ticks = xTaskGetTickCount();
}
```

New per-sender `static` state (`arm_cpu_pct`, `arm_mem_pct`, `riscv_cpu_pct`,
`riscv_mem_pct`, `mips_cpu_pct`, `mips_mem_pct`) holds the latest values between snapshot
writes — same lifetime and update cadence as the existing `arm_count`/`riscv_count`/
`mips_count`.

`write_stats_snapshot` copies all six statics into the extended snapshot fields alongside
the existing counts and tick timestamp, using the same volatile-write +
`__sync_synchronize()` + `generation` increment discipline already in place. No change to
that write protocol.

## Section 4 — Cross-Domain Log Format (`linux_stats.c` → `log_snapshot`)

Current line:
```
[2026-06-07T12:34:56Z] gen=42 arm=120 riscv=118 mips=115 tick=12345.678901234
```

Extended — `cpu=`/`mem=` grouped immediately after each guest's count, keeping
per-guest data visually clustered for scanning three guests side by side:
```
[2026-06-07T12:34:56Z] gen=42 arm=120 cpu=12.34% mem=45.67% riscv=118 cpu=8.90% mem=23.45% mips=115 cpu=3.21% mem=67.89% tick=12345.678901234
```

`log_snapshot` formats each `_x100` integer back to `%u.%02u%%` (integer part /
fractional part via `/ 100` and `% 100`) — the same fixed-point-printing technique
`read_loadavg_fixed` already uses on the Linux side. No floating point in the log writer.

## Section 5 — Testing & Verification

- **`test-syslog-format.sh`**: extend the regex to require the new fields in the SYSINFO
  line:
  ```
  SYSINFO #0 ld=[0-9]+\.[0-9]+ cpu=[0-9]+\.[0-9]+% mem=[0-9]+\.[0-9]+% mf=[0-9]+M up=[0-9]+s
  ```
- **End-to-end check**: after building and running the showcase, tail
  `/var/log/chimera-log/chimera-cross-domain.log` on the ARM guest and confirm all three
  guests' `cpu=`/`mem=` fields appear and update across generations.
- No changes needed to `guest-run-debian-harness.sh` / `guest-run-freertos-harness.sh` —
  their pass conditions are about boot success and HELLO/ACK reception, not cross-domain
  log content.

## Out of Scope

- Per-core CPU breakdowns (rejected in favor of a single aggregate utilization % that's
  meaningful across guests with different core counts — ARM/RISCV at 4 cores, MIPS at 1).
- Raw `MemTotal`/`MemAvailable` figures alongside the percentage (kept to a single
  normalized used-% number for readability and wire-format compactness).
- Any change to the existing message-count (`arm_count`/`riscv_count`/`mips_count`)
  or tick-timestamp fields, or to the ivshmem channel topology.
