# RISCV Hello/ACK, Stats E2E, and FreeRTOS Shell Harnesses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three new headless pass/fail harness scripts that close the three highest-priority test-coverage gaps: (1) the RISCV-Linux ↔ FreeRTOS HELLO/ACK handshake over IVSHMEM1, (2) ARM-Linux-side consumption of the FreeRTOS stats snapshot channel (IVSHMEM3) into `chimera-cross-domain.log`, and (3) the FreeRTOS interactive UART shell's six commands driven over real serial RX.

**Architecture:** Each harness follows the existing `guest-run-can-e2e-harness.sh` pattern — background `ivshmem-server` processes for the required channels, a `tmux` session (`remain-on-exit on`) hosting QEMU guest(s) with `-nographic`, `tmux send-keys`/`capture-pane` for guest I/O, and a polling loop that exits 0 on PASS / 1 on FAIL with a tail-dump on timeout.

**Tech Stack:** bash, tmux 3.4+, `qemu-system-arm` (FreeRTOS Cortex-R52), `qemu-system-riscv64`, `qemu-system-aarch64`, existing `scripts/heterogeneous-soc/common.sh` helpers, and the cross-compiled showcase binaries `syslog-riscv-linux` / `linux-arm-stats` (built by `guest-build-freertos-showcase.sh`).

---

## Design Decisions

### 1. Harness 1 (RISCV hello/ack) PASS condition

`linux_syslog.c`'s `main_loop()` prints a summary line only every 5th successful HELLO/ACK round trip (`hello_count % 5 == 0`):

```c
printf("[%s] ACK   #%" PRIu32 " freertos_tick=%lld.%09lld  [hello=%" PRIu32 " ack=%" PRIu32 "]\n",
       HSOC_SENDER_LABEL, ack.seq, ...);
```

With `SYSLOG_INTERVAL_SEC=1` (env override read at `linux_syslog.c:605-607`), 5 round trips take ~5s once the binary starts. The PASS regex is therefore `\[riscv-linux\] ACK` — code-grounded, fast, and proves both the HELLO send (IVSHMEM1 SHMEM write + doorbell) and the ACK receive (FreeRTOS ISR `freertos_ivshmem_send_ack()` + doorbell back) round-trip correctly. Combined with FreeRTOS UART printing `"[freertos] showcase task started"` (proves `gic_enable_ivshmem_spi()` ran for all three hello channels), this is a complete IVSHMEM1 IRQ-path test.

The stale string `"received hello from riscv-linux"` referenced by `guest-run-freertos-harness.sh` and `guest-run-debian-harness.sh` does **not** exist anywhere in current FreeRTOS source — it is a pre-existing bug in those harnesses, out of scope here, and **not** reproduced in this new harness.

### 2. Harness 2 (Stats E2E) minimal ivshmem attachment + timeout sizing

`stats_shmem->magic = HSOC_STATS_MAGIC; stats_shmem->generation = 0;` is set by `showcase_task()` at FreeRTOS boot, independent of any Linux HELLO channel. `find_stats_shm()` (`linux_stats.c:52-121`) scans **all** PCI ivshmem devices (vendor `0x1af4`) for `magic==HSOC_STATS_MAGIC`, so the ARM-Linux guest needs **only** the stats ivshmem-doorbell device attached — the ARM hello channel (IVSHMEM0) device is not required and is omitted for minimalism.

`write_stats_snapshot()` fires every 5000 main-loop iterations × `vTaskDelay(pdMS_TO_TICKS(10))` ≈ **50s of FreeRTOS uptime** before `generation` first goes 0→1. FreeRTOS boots in seconds, but ARM-Linux Debian boot typically takes 1-2 minutes, so by the time `linux-arm-stats` starts and polls (every 2s), `generation` is very likely already ≥1. The harness still uses a generous default timeout (`STATS_E2E_TIMEOUT=240`) to cover a cold ARM-Linux boot plus the 50s FreeRTOS-side delay in the worst case (FreeRTOS started after ARM-Linux somehow).

This is **complementary**, not duplicative, with `docs/superpowers/plans/2026-06-13-stats-bootlog-unit-harness.md`, which only checks the **FreeRTOS-side** UART line `"[freertos] stats snapshot written"` via `guest-run-freertos-harness.sh`. Harness 2 here is the missing **ARM-side consumption** test: it runs the real `linux-arm-stats` binary inside the ARM-Linux guest, verifies it finds the BAR2 via sysfs PCI scan, and verifies it writes a correctly-formatted line to `chimera-cross-domain.log`.

### 3. Harness 3 (Shell E2E) requires the CAN ivshmem channel for a deterministic `can status`

`can_driver.c`'s `can_init()` unconditionally writes `can_ivshmem->magic = CAN_IVSHMEM_MAGIC; can_ivshmem->generation = 0;` to `IVSHMEM5_SHMEM`, and `can_get_status()` later reads `out->rx_frames = can_ivshmem->generation`. If no `ivshmem-can-freertos=canft` chardev is attached, `IVSHMEM5_SHMEM` is unmapped MMIO: the write data-abort-skips (`startup.S`'s `subs pc, lr, #4`), and the *read* in `can_get_status()` also data-abort-skips, leaving the destination register's value **UNPREDICTABLE** — `rx_frames` could print as any value, not reliably `0`.

Attaching a 4th ivshmem-server as `ivshmem-can-freertos=canft` (using `IVSHMEM_CAN_FREERTOS_SOCKET` / `IVSHMEM_CAN_FREERTOS_SIZE=65536`, **without** `canbus=`/`-object can-bus`/socketcan — no sudo or `vcan0` needed) maps `IVSHMEM5_SHMEM` as real zero-initialized shared memory. `can_init()`'s write then "sticks", and `can status` deterministically prints `rx_frames=0`. `CAN_REG_SR` (read from the separate, still-unmapped `CAN_MMIO=0x50000000`) remains unpredictable, so the `sr=` check uses a `0x[0-9a-f]{8}` regex (any 8 hex digits — `shell_utoa_hex` always emits exactly 8).

Harness 3 therefore needs **4 ivshmem servers**: ARM, RISCV, MIPS (all mandatory per `chimera_r52_require_chardev()`) + CAN (`canft`, for the reason above). The stats and bootlog channels are not exercised by any of the 6 shell commands and are omitted (YAGNI) — this is a deliberate simplification from the existing `guest-run-freertos-shell-harness.sh`'s 5-server (incl. stats+bootlog) layout.

### 4. Interactive RX requires `-nographic` in a tmux pane (not `-serial file:`)

`guest-run-freertos-shell-harness.sh` uses `-serial file:"${FREERTOS_LOG}" -nographic`, which is write-only — there is no way to `tmux send-keys` into it. Harness 3 instead runs FreeRTOS with bare `-nographic` inside a tmux pane (as `guest-run-can-e2e-harness.sh` does for its FreeRTOS pane), so `tmux send-keys` reaches the QEMU console (PL011 UART0) and `uart_rx_isr()` → `uart_rx_queue` → `shell_task()`, exactly as documented in `README.md`'s "Interactive Shell" section.

### 5. Relationship to other in-flight plans

- `docs/superpowers/plans/2026-06-13-stats-bootlog-unit-harness.md` — FreeRTOS-side-only stats/bootlog UART checks. Complementary to Harness 2 (see Decision 2).
- `docs/superpowers/plans/2026-06-12-doorbell-irq-riscv-mips-plan.md` — implements the IVSHMEM1/IVSHMEM2 IRQ-driven doorbell path that Harness 1 exercises. If that plan is not yet executed, Harness 1 still passes via `hybrid_wait_ack()`'s poll fallback (slower but functional); if it *is* executed, Harness 1 additionally validates the new IRQ path with no script changes needed.

Each of the three harnesses below is independently runnable and independently committable.

---

## File Structure

### New Files

| File | Purpose |
|---|---|
| `scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh` | Harness 1: RISCV-Linux ↔ FreeRTOS HELLO/ACK over IVSHMEM1 |
| `scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh` | Harness 2: ARM-side stats channel consumption (IVSHMEM3 → `chimera-cross-domain.log`) |
| `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh` | Harness 3: FreeRTOS interactive shell, all 6 commands over real UART RX |

### Modified Files

| File | Change |
|---|---|
| `CLAUDE.md` | Document the three new harnesses under "CI / Headless Testing", matching the existing entries for `guest-run-can-e2e-harness.sh` etc. |

---

## Task 1: RISCV-Linux ↔ FreeRTOS HELLO/ACK Harness (IVSHMEM1)

**Files:**
- Create: `scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh`

- [ ] **Step 1: Create the harness script**

```bash
#!/usr/bin/env bash
# guest-run-riscv-hello-harness.sh — headless pass/fail test for the
# RISCV-Linux <-> FreeRTOS HELLO/ACK handshake over IVSHMEM1.
#
# Launches FreeRTOS (with the 3 mandatory ivshmem channels: ARM/RISCV/MIPS)
# and a RISC-V Linux guest running syslog-riscv-linux with
# SYSLOG_INTERVAL_SEC=1 for fast round trips. Verifies:
#   1. FreeRTOS boots and IVSHMEM1 IRQ wiring is initialised
#      ("[freertos] showcase task started")
#   2. RISCV-Linux completes >=5 HELLO/ACK round trips over IVSHMEM1
#      ("[riscv-linux] ACK   #...")
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   RISCV_HELLO_TIMEOUT  seconds to wait for both pass conditions (default 240)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${RISCV_HELLO_TIMEOUT:-240}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="riscv-hello-${RUN_ID}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

# ---- Prerequisites check ----
MISSING=""
for f in "${FREERTOS_DEMO_ELF}" "${RISCV_KERNEL_IMAGE}" "${RISCV_INITRD_IMAGE}" \
         "${RISCV_DEBIAN_DISK}" "${RISCV_OPENSBI_BIOS}" \
         "${FREERTOS_SHOWCASE_DIR}/syslog-riscv-linux"; do
    if [[ ! -f "$f" ]]; then
        MISSING+="  MISSING: ${f}\n"
    fi
done
if [[ -n "${MISSING}" ]]; then
    _fail "Missing required artifacts:"
    printf "%b" "${MISSING}"
    _fail "Build the showcase first via guest-build-freertos-showcase.sh"
    exit 1
fi

FREERTOS_QEMU="$(find_qemu_system_binary qemu-system-arm)"
RISCV_QEMU="$(find_qemu_system_binary qemu-system-riscv64)"

# ---- tmux session (2-pane layout) ----
#   pane 0.0: FreeRTOS QEMU
#   pane 0.1: RISC-V Linux QEMU
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on
tmux split-window -v -t "${SESSION}:0.0" -l 50%

# ---- ivshmem servers (background) ----
# FreeRTOS requires the ARM, RISCV, and MIPS ivshmem chardevs to be present
# even though only the RISCV channel is exercised by this harness.
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"  -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" -M ivshmem-riscv-ft -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  -M ivshmem-mips-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 3 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.0) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${FREERTOS_QEMU}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter

# ---- RISC-V Linux QEMU (pane 0.1, no networking required) ----
_info "Starting RISC-V Linux QEMU..."
tmux send-keys -t "${SESSION}:0.1" \
    "exec '${RISCV_QEMU}' \
    -rtc base=localtime \
    -machine virt,aclint=on \
    -cpu rv64,h=true,v=true \
    -m 512M -smp 2 \
    -bios '${RISCV_OPENSBI_BIOS}' \
    -kernel '${RISCV_KERNEL_IMAGE}' \
    -initrd '${RISCV_INITRD_IMAGE}' \
    -append '${RISCV_KERNEL_CMDLINE}' \
    -chardev socket,id=ivshmem,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem,vectors=${IVSHMEM_VECTORS} \
    -drive file='${RISCV_DEBIAN_DISK}',format=qcow2,if=virtio \
    -virtfs local,path='${PINGPONG_DIR}',mount_tag=${PINGPONG_SHARE_TAG},security_model=none,id=${PINGPONG_SHARE_TAG} \
    -nographic" Enter

# ---- Auto-login and launch syslog-riscv-linux ----
auto_login_and_run() {
    local pane="$1"
    shift
    local cmds=("$@")
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"
        if echo "${content}" | grep -q "login:"; then
            tmux send-keys -t "${pane}" "root" Enter
            sleep 3
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        fi
        sleep 3
        (( ++elapsed ))
    done
    echo "[harness] WARNING: timed out waiting for shell prompt in pane ${pane}" >&2
    return 1
}

auto_login_and_run "${SESSION}:0.1" \
    "mount /mnt/${PINGPONG_SHARE_TAG}" \
    "cp /mnt/${PINGPONG_SHARE_TAG}/freertos-showcase/syslog-riscv-linux /tmp/" \
    "SYSLOG_INTERVAL_SEC=1 /tmp/syslog-riscv-linux &" &

# ---- Monitor loop ----
elapsed=0
FREERTOS_SEEN=0
RISCV_ACK_SEEN=0

while (( elapsed < TIMEOUT )); do
    if [[ "${FREERTOS_SEEN}" -eq 0 ]]; then
        ft_content="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"
        if echo "${ft_content}" | grep -q "showcase task started"; then
            FREERTOS_SEEN=1
            _ok "FreeRTOS showcase task started (IVSHMEM1 IRQ wiring initialised)"
        fi
    fi

    if [[ "${RISCV_ACK_SEEN}" -eq 0 ]]; then
        riscv_content="$(tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null)"
        if echo "${riscv_content}" | grep -q '\[riscv-linux\] ACK'; then
            RISCV_ACK_SEEN=1
            _ok "RISCV-Linux completed >=5 HELLO/ACK round trips over IVSHMEM1"
        fi
    fi

    if [[ "${FREERTOS_SEEN}" -eq 1 ]] && [[ "${RISCV_ACK_SEEN}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — both conditions met"
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[harness] t=%3ds  FreeRTOS=%d  RISCV_ACK=%d\n" \
            "${elapsed}" "${FREERTOS_SEEN}" "${RISCV_ACK_SEEN}"
    fi

    sleep 2
    (( ++elapsed ))
done

# FAIL
echo ""
_fail "FAIL: timeout after ${TIMEOUT}s"
if [[ "${FREERTOS_SEEN}" -eq 0 ]]; then
    _fail "  FreeRTOS showcase task started: NOT SEEN"
    echo "  === FreeRTOS pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null | tail -20 || true
fi
if [[ "${RISCV_ACK_SEEN}" -eq 0 ]]; then
    _fail "  [riscv-linux] ACK: NOT SEEN"
    echo "  === RISC-V Linux pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null | tail -20 || true
fi
exit 1
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh
```

- [ ] **Step 3: Run it inside Lima to verify PASS**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh
```

Expected (after RISC-V Debian boot, ~1-2 min):
```
  ✓ FreeRTOS showcase task started (IVSHMEM1 IRQ wiring initialised)
  ✓ RISCV-Linux completed >=5 HELLO/ACK round trips over IVSHMEM1

[harness] PASS after <N>s — both conditions met
```
Exit code 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh
git commit -m "test(harness): add RISCV-Linux <-> FreeRTOS HELLO/ACK e2e harness (IVSHMEM1)"
```

---

## Task 2: Stats Channel ARM-Side Consumption Harness (IVSHMEM3)

**Files:**
- Create: `scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh`

- [ ] **Step 1: Create the harness script**

```bash
#!/usr/bin/env bash
# guest-run-stats-e2e-harness.sh — headless pass/fail test for ARM-Linux-side
# consumption of the FreeRTOS stats snapshot channel (IVSHMEM3).
#
# Launches FreeRTOS (with the 3 mandatory ivshmem channels: ARM/RISCV/MIPS,
# plus the stats channel) and an ARM Linux guest running linux-arm-stats.
# Verifies:
#   1. FreeRTOS boots and publishes the stats snapshot magic
#      ("[freertos] showcase task started")
#   2. linux-arm-stats finds the stats BAR2 via sysfs PCI scan
#      ("[stats] logging to ...")
#   3. linux-arm-stats observes a generation change and logs it
#      ("[stats] gen=<N> logged", N>=1)
#   4. chimera-cross-domain.log contains a correctly-formatted snapshot line
#      ("gen=<N> arm=...")
#
# Exit 0 = PASS, Exit 1 = FAIL.
#
# Environment overrides:
#   STATS_E2E_TIMEOUT  seconds to wait for all pass conditions (default 240)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIMEOUT="${STATS_E2E_TIMEOUT:-240}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="stats-e2e-${RUN_ID}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

# ---- Prerequisites check ----
MISSING=""
for f in "${FREERTOS_DEMO_ELF}" "${ARM_KERNEL_IMAGE}" "${ARM_INITRD_IMAGE}" \
         "${ARM_DEBIAN_DISK}" "${ARM_UEFI_BIOS}" \
         "${FREERTOS_SHOWCASE_DIR}/linux-arm-stats"; do
    if [[ ! -f "$f" ]]; then
        MISSING+="  MISSING: ${f}\n"
    fi
done
if [[ -n "${MISSING}" ]]; then
    _fail "Missing required artifacts:"
    printf "%b" "${MISSING}"
    _fail "Build the showcase first via guest-build-freertos-showcase.sh"
    exit 1
fi

FREERTOS_QEMU="$(find_qemu_system_binary qemu-system-arm)"
ARM_QEMU="$(find_qemu_system_binary qemu-system-aarch64)"

# ---- tmux session (2-pane layout) ----
#   pane 0.0: FreeRTOS QEMU
#   pane 0.1: ARM Linux QEMU
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on
tmux split-window -v -t "${SESSION}:0.0" -l 50%

# ---- ivshmem servers (background) ----
# FreeRTOS requires the ARM, RISCV, and MIPS ivshmem chardevs to be present;
# the stats channel is the one this harness actually exercises.
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_STATS_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_STATS_FREERTOS_SOCKET}"  -M ivshmem-stats-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_STATS_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 4 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.0) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${FREERTOS_QEMU}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-stats-freertos=statsft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -chardev socket,id=statsft,path='${IVSHMEM_STATS_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter

# ---- ARM Linux QEMU (pane 0.1, stats ivshmem-doorbell only) ----
_info "Starting ARM Linux QEMU..."
tmux send-keys -t "${SESSION}:0.1" \
    "exec '${ARM_QEMU}' \
    -machine virt,gic-version=3 \
    -cpu cortex-a53 -m 512M -smp 2 \
    -bios '${ARM_UEFI_BIOS}' \
    -kernel '${ARM_KERNEL_IMAGE}' \
    -initrd '${ARM_INITRD_IMAGE}' \
    -append 'console=ttyAMA0 root=/dev/vda rw' \
    -chardev socket,id=ivshmem_stats,path='${IVSHMEM_STATS_FREERTOS_SOCKET}' \
    -device ivshmem-doorbell,chardev=ivshmem_stats,vectors=${IVSHMEM_VECTORS} \
    -drive file='${ARM_DEBIAN_DISK}',format=qcow2,if=virtio \
    -virtfs local,path='${PINGPONG_DIR}',mount_tag=${PINGPONG_SHARE_TAG},security_model=none,id=${PINGPONG_SHARE_TAG} \
    -nographic" Enter

# ---- Auto-login and launch linux-arm-stats ----
auto_login_and_run() {
    local pane="$1"
    shift
    local cmds=("$@")
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"
        if echo "${content}" | grep -q "login:"; then
            tmux send-keys -t "${pane}" "root" Enter
            sleep 3
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            for cmd in "${cmds[@]}"; do
                tmux send-keys -t "${pane}" "${cmd}" Enter
                sleep 1
            done
            return 0
        fi
        sleep 3
        (( ++elapsed ))
    done
    echo "[harness] WARNING: timed out waiting for shell prompt in pane ${pane}" >&2
    return 1
}

auto_login_and_run "${SESSION}:0.1" \
    "mount /mnt/${PINGPONG_SHARE_TAG}" \
    "cp /mnt/${PINGPONG_SHARE_TAG}/freertos-showcase/linux-arm-stats /tmp/" \
    "/tmp/linux-arm-stats &" \
    "sleep 1 && tail -F /var/log/chimera-log/chimera-cross-domain.log &" &

# ---- Monitor loop ----
elapsed=0
FREERTOS_SEEN=0
STATS_STARTED=0
STATS_GEN_LOGGED=0
STATS_FILE_LINE=0

while (( elapsed < TIMEOUT )); do
    if [[ "${FREERTOS_SEEN}" -eq 0 ]]; then
        ft_content="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"
        if echo "${ft_content}" | grep -q "showcase task started"; then
            FREERTOS_SEEN=1
            _ok "FreeRTOS showcase task started (stats magic published)"
        fi
    fi

    arm_content="$(tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null)"

    if [[ "${STATS_STARTED}" -eq 0 ]] && echo "${arm_content}" | grep -q '\[stats\] logging to'; then
        STATS_STARTED=1
        _ok "linux-arm-stats found the stats BAR2 and opened the log file"
    fi

    if [[ "${STATS_GEN_LOGGED}" -eq 0 ]] && echo "${arm_content}" | grep -Eq '\[stats\] gen=[1-9][0-9]* logged'; then
        STATS_GEN_LOGGED=1
        _ok "linux-arm-stats observed a generation change and logged it"
    fi

    if [[ "${STATS_FILE_LINE}" -eq 0 ]] && echo "${arm_content}" | grep -Eq 'gen=[1-9][0-9]* arm='; then
        STATS_FILE_LINE=1
        _ok "chimera-cross-domain.log contains a correctly-formatted snapshot line"
    fi

    if [[ "${FREERTOS_SEEN}" -eq 1 ]] && [[ "${STATS_STARTED}" -eq 1 ]] && \
       [[ "${STATS_GEN_LOGGED}" -eq 1 ]] && [[ "${STATS_FILE_LINE}" -eq 1 ]]; then
        echo ""
        echo "[harness] PASS after ${elapsed}s — all four conditions met"
        exit 0
    fi

    if (( elapsed > 0 && elapsed % 30 == 0 )); then
        printf "[harness] t=%3ds  FreeRTOS=%d  StatsStarted=%d  GenLogged=%d  FileLine=%d\n" \
            "${elapsed}" "${FREERTOS_SEEN}" "${STATS_STARTED}" "${STATS_GEN_LOGGED}" "${STATS_FILE_LINE}"
    fi

    sleep 2
    (( ++elapsed ))
done

# FAIL
echo ""
_fail "FAIL: timeout after ${TIMEOUT}s"
[[ "${FREERTOS_SEEN}"    -eq 0 ]] && _fail "  FreeRTOS showcase task started: NOT SEEN"
[[ "${STATS_STARTED}"    -eq 0 ]] && _fail "  [stats] logging to ...: NOT SEEN"
[[ "${STATS_GEN_LOGGED}" -eq 0 ]] && _fail "  [stats] gen=<N> logged (N>=1): NOT SEEN"
[[ "${STATS_FILE_LINE}"  -eq 0 ]] && _fail "  chimera-cross-domain.log snapshot line: NOT SEEN"
echo "=== FreeRTOS pane tail ==="
tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null | tail -20 || true
echo "=== ARM Linux pane tail ==="
tmux capture-pane -p -t "${SESSION}:0.1" -S -50000 2>/dev/null | tail -20 || true
exit 1
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh
```

- [ ] **Step 3: Run it inside Lima to verify PASS**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh
```

Expected (after ARM Debian boot, ~1-2 min):
```
  ✓ FreeRTOS showcase task started (stats magic published)
  ✓ linux-arm-stats found the stats BAR2 and opened the log file
  ✓ linux-arm-stats observed a generation change and logged it
  ✓ chimera-cross-domain.log contains a correctly-formatted snapshot line

[harness] PASS after <N>s — all four conditions met
```
Exit code 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh
git commit -m "test(harness): add ARM-side stats channel consumption e2e harness (IVSHMEM3)"
```

---

## Task 3: FreeRTOS Interactive Shell Command Harness

**Files:**
- Create: `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`

- [ ] **Step 1: Create the harness script**

```bash
#!/usr/bin/env bash
# guest-run-shell-e2e-harness.sh — headless pass/fail test for the FreeRTOS
# interactive UART shell, driven over real serial RX.
#
# Launches FreeRTOS with the 3 mandatory ivshmem channels (ARM/RISCV/MIPS)
# plus the CAN ivshmem channel (so `can status` reads a deterministic
# rx_frames=0 from zero-initialized IVSHMEM5 shared memory -- see the plan's
# Design Decisions for why this is required). No Linux guests are started.
#
# Sends each of the 6 shell commands via `tmux send-keys` and verifies the
# exact output documented in README.md's "Interactive Shell" section:
#   help, stats, sysinfo, links, loglevel, can status
# plus one unrecognized-command check (shell_dispatch's default branch).
#
# Exit 0 = ALL PASS, Exit 1 = any FAIL.
#
# Environment overrides:
#   SHELL_E2E_TIMEOUT  seconds to wait for the shell prompt at boot (default 60)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BOOT_TIMEOUT="${SHELL_E2E_TIMEOUT:-60}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
SESSION="shell-e2e-${RUN_ID}"

_ok()   { printf '\033[0;32m  \342\234\223 %s\033[0m\n' "$*"; }
_fail() { printf '\033[0;31m  \342\234\227 %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

cleanup() {
    tmux kill-session -t "${SESSION}" 2>/dev/null || true
    pkill ivshmem-server 2>/dev/null || true
    rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
          "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
cleanup

require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
qemu_bin="$(find_qemu_system_binary qemu-system-arm)"

# ---- tmux session (single pane) ----
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux set-option -t "${SESSION}" history-limit 50000
tmux set-option -t "${SESSION}" remain-on-exit on

# ---- ivshmem servers (background) ----
# ARM/RISCV/MIPS are mandatory chardevs for chimera-r52-freertos-demo. CAN is
# attached (without a canbus object, no sudo/vcan0 needed) so IVSHMEM5 is
# real zero-init shared memory and `can status` reports a deterministic
# rx_frames=0 -- see this plan's Design Decisions, item 3.
IVSHMEM_BIN="$(find_ivshmem_server)"
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}" \
         "${IVSHMEM_MIPS_FREERTOS_DIR}" "${IVSHMEM_CAN_FREERTOS_DIR}"

"${IVSHMEM_BIN}" -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"   -M ivshmem-arm-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}"  -M ivshmem-riscv-ft  -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"   -M ivshmem-mips-ft   -l "${IVSHMEM_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &
"${IVSHMEM_BIN}" -F -S "${IVSHMEM_CAN_FREERTOS_SOCKET}"    -M ivshmem-can-ft    -l "${IVSHMEM_CAN_FREERTOS_SIZE}" -n "${IVSHMEM_VECTORS}" >/dev/null 2>&1 &

for _i in $(seq 1 60); do
    all_up=1
    for _sock in "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
                 "${IVSHMEM_MIPS_FREERTOS_SOCKET}" "${IVSHMEM_CAN_FREERTOS_SOCKET}"; do
        if [[ ! -S "${_sock}" ]] || ! ss -xl 2>/dev/null | grep -Fq "${_sock}"; then
            all_up=0
            break
        fi
    done
    [[ ${all_up} -eq 1 ]] && break
    sleep 0.5
done
_info "All 4 ivshmem servers ready"

# ---- FreeRTOS QEMU (pane 0.0, interactive -nographic) ----
_info "Starting FreeRTOS QEMU..."
tmux send-keys -t "${SESSION}:0.0" \
    "exec '${qemu_bin}' \
    -machine 'chimera-r52-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft,ivshmem-can-freertos=canft' \
    -chardev socket,id=armft,path='${IVSHMEM_ARM_FREERTOS_SOCKET}' \
    -chardev socket,id=riscvft,path='${IVSHMEM_RISCV_FREERTOS_SOCKET}' \
    -chardev socket,id=mipsft,path='${IVSHMEM_MIPS_FREERTOS_SOCKET}' \
    -chardev socket,id=canft,path='${IVSHMEM_CAN_FREERTOS_SOCKET}' \
    -kernel '${FREERTOS_DEMO_ELF}' \
    -nographic" Enter

# ---- Wait for shell prompt ----
_info "Waiting for shell prompt (timeout ${BOOT_TIMEOUT}s)..."
elapsed=0
PROMPT_SEEN=0
while (( elapsed < BOOT_TIMEOUT )); do
    content="$(tmux capture-pane -p -t "${SESSION}:0.0" 2>/dev/null)"
    if echo "${content}" | grep -q "chimera>"; then
        PROMPT_SEEN=1
        break
    fi
    sleep 1
    (( ++elapsed ))
done

if [[ "${PROMPT_SEEN}" -eq 0 ]]; then
    _fail "FAIL: shell prompt did not appear within ${BOOT_TIMEOUT}s"
    echo "=== pane tail ==="
    tmux capture-pane -p -t "${SESSION}:0.0" 2>/dev/null | tail -30 || true
    exit 1
fi
_ok "Shell prompt detected"

# ---- Send commands ----
send_cmd() {
    tmux send-keys -t "${SESSION}:0.0" "$1" Enter
    sleep 1
}

send_cmd "help"
send_cmd "stats"
send_cmd "sysinfo"
send_cmd "links"
send_cmd "loglevel"
send_cmd "can status"
send_cmd "frobnicate"
sleep 1

OUTPUT="$(tmux capture-pane -p -t "${SESSION}:0.0" -S -50000 2>/dev/null)"

# ---- Checks ----
FAIL_COUNT=0

check_contains() {
    local label="$1" needle="$2"
    if echo "${OUTPUT}" | grep -qF -- "${needle}"; then
        _ok "${label}"
    else
        _fail "${label}  (expected literal: ${needle})"
        (( ++FAIL_COUNT ))
    fi
}

check_regex() {
    local label="$1" pattern="$2"
    if echo "${OUTPUT}" | grep -Eq -- "${pattern}"; then
        _ok "${label}"
    else
        _fail "${label}  (expected pattern: ${pattern})"
        (( ++FAIL_COUNT ))
    fi
}

echo ""
echo "[harness] Checking 'help' output (6 commands)..."
check_contains "help: help"     "help - list available commands"
check_contains "help: stats"    "stats - per-guest HELLO count, cpu%, mem%"
check_contains "help: sysinfo"  "sysinfo - heap free, uptime, stack high-water marks"
check_contains "help: links"    "links - per-channel IVPOSITION, flags, time since last HELLO"
check_contains "help: loglevel" "loglevel - get/set runtime log verbosity (0=VERBOSE..3=ERROR)"
check_contains "help: can"      "can - 'can status' - CAN controller status register, frames forwarded"

echo ""
echo "[harness] Checking 'stats' output (no Linux guests -> all zero)..."
check_contains "stats: arm-linux"   "arm-linux: hello=0 cpu=0.00% mem=0.00%"
check_contains "stats: riscv-linux" "riscv-linux: hello=0 cpu=0.00% mem=0.00%"
check_contains "stats: mips-linux"  "mips-linux: hello=0 cpu=0.00% mem=0.00%"

echo ""
echo "[harness] Checking 'sysinfo' output..."
check_regex "sysinfo: 4 numeric fields" \
    'heap_free=[0-9]+ uptime_s=[0-9]+ shell_stack_hiwat=[0-9]+ showcase_stack_hiwat=[0-9]+'

echo ""
echo "[harness] Checking 'links' output (no Linux guests -> flags=0)..."
check_regex "links: arm-linux"   'arm-linux: ivpos=0x[0-9a-f]{8} l2f_flag=0 f2l_flag=0 since_hello=[0-9]+ms'
check_regex "links: riscv-linux" 'riscv-linux: ivpos=0x[0-9a-f]{8} l2f_flag=0 f2l_flag=0 since_hello=[0-9]+ms'
check_regex "links: mips-linux"  'mips-linux: ivpos=0x[0-9a-f]{8} l2f_flag=0 f2l_flag=0 since_hello=[0-9]+ms'

echo ""
echo "[harness] Checking 'loglevel' (default level)..."
check_contains "loglevel: default INFO" "loglevel=1 (INFO)"

echo ""
echo "[harness] Checking 'can status' (canft attached -> rx_frames=0)..."
check_regex "can status: sr+rx_frames" 'sr=0x[0-9a-f]{8} rx_frames=0'

echo ""
echo "[harness] Checking unrecognized command..."
check_contains "unknown command" "unknown command: frobnicate (try 'help')"

# ---- Result ----
echo ""
if (( FAIL_COUNT == 0 )); then
    echo "[harness] PASS — all 16 shell command checks passed"
    exit 0
fi

echo "[harness] FAIL — ${FAIL_COUNT} check(s) failed"
echo "=== Full pane output ==="
echo "${OUTPUT}"
exit 1
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

- [ ] **Step 3: Run it inside Lima to verify PASS**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected (FreeRTOS boots in a few seconds, no Linux guest boot wait):
```
  ✓ Shell prompt detected

[harness] Checking 'help' output (6 commands)...
  ✓ help: help
  ✓ help: stats
  ✓ help: sysinfo
  ✓ help: links
  ✓ help: loglevel
  ✓ help: can

[harness] Checking 'stats' output (no Linux guests -> all zero)...
  ✓ stats: arm-linux
  ✓ stats: riscv-linux
  ✓ stats: mips-linux

[harness] Checking 'sysinfo' output...
  ✓ sysinfo: 4 numeric fields

[harness] Checking 'links' output (no Linux guests -> flags=0)...
  ✓ links: arm-linux
  ✓ links: riscv-linux
  ✓ links: mips-linux

[harness] Checking 'loglevel' (default level)...
  ✓ loglevel: default INFO

[harness] Checking 'can status' (canft attached -> rx_frames=0)...
  ✓ can status: sr+rx_frames

[harness] Checking unrecognized command...
  ✓ unknown command

[harness] PASS — all 16 shell command checks passed
```
Exit code 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
git commit -m "test(harness): add FreeRTOS interactive shell command e2e harness"
```

---

## Task 4: Document the Three New Harnesses in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (CI / Headless Testing section)

- [ ] **Step 1: Insert documentation for the three new harnesses**

In `CLAUDE.md`, find this exact text (the end of the `guest-run-can-e2e-harness.sh` entry, immediately before the `### Harness implementation notes` heading):

```markdown
**Environment overrides:** `CAN_E2E_TIMEOUT` (default 180), `CAN_TEST_ID` (default `123`), `CAN_TEST_DATA` (default `DEADBEEF`).

### Harness implementation notes
```

Replace it with:

```markdown
**Environment overrides:** `CAN_E2E_TIMEOUT` (default 180), `CAN_TEST_ID` (default `123`), `CAN_TEST_DATA` (default `DEADBEEF`).

### `guest-run-riscv-hello-harness.sh` (full-stack, ~1-2 min)

End-to-end RISCV-Linux ↔ FreeRTOS HELLO/ACK verification over IVSHMEM1:
launches FreeRTOS (3 mandatory ivshmem channels: ARM/RISCV/MIPS) and a
RISC-V Linux guest running `syslog-riscv-linux` with
`SYSLOG_INTERVAL_SEC=1` for fast round trips. Verifies:
1. FreeRTOS boots and the IVSHMEM1 IRQ path is initialised
   (`showcase task started`)
2. RISCV-Linux completes >=5 HELLO/ACK round trips
   (`[riscv-linux] ACK`)

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh
```

**Environment overrides:** `RISCV_HELLO_TIMEOUT` (default 240).

### `guest-run-stats-e2e-harness.sh` (full-stack, ~1-2 min)

End-to-end ARM-side consumption of the stats snapshot channel (IVSHMEM3):
launches FreeRTOS (3 mandatory ivshmem channels + stats) and an ARM Linux
guest running `linux-arm-stats`. Verifies:
1. FreeRTOS publishes the stats magic (`showcase task started`)
2. `linux-arm-stats` finds the BAR2 via sysfs (`[stats] logging to ...`)
3. A generation change is logged (`[stats] gen=<N> logged`, N>=1)
4. `chimera-cross-domain.log` gets a correctly-formatted snapshot line
   (`gen=<N> arm=...`)

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh
```

**Environment overrides:** `STATS_E2E_TIMEOUT` (default 240).

### `guest-run-shell-e2e-harness.sh` (lightweight, ~15 s)

FreeRTOS-only interactive shell test: launches FreeRTOS with the 3
mandatory ivshmem channels plus the CAN ivshmem channel (`canft`, no
`canbus` object — makes `can status`'s `rx_frames` deterministic), then
drives all 6 shell commands (`help`, `stats`, `sysinfo`, `links`,
`loglevel`, `can status`) plus one unrecognized command over real UART RX
via `tmux send-keys`, checking each command's output against
`README.md`'s "Interactive Shell" table.

**Quick run:**
```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

**Environment overrides:** `SHELL_E2E_TIMEOUT` (default 60).

### Harness implementation notes
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document riscv-hello, stats-e2e, and shell-e2e harnesses in CLAUDE.md"
```

---

## Self-Review

**1. Spec coverage** — the task asked for harnesses covering: "Stats channel ARM-side consumption" (Task 2), "RISCV-Linux ↔ FreeRTOS HELLO/ACK (IVSHMEM1)" (Task 1), and "FreeRTOS shell command" (Task 3). All three are covered by independently-runnable, independently-committable scripts, each producing a real pass/fail signal grounded in current source (`linux_syslog.c`, `linux_stats.c`, `shell.c`, `can_driver.c`). Documentation is added in Task 4.

**2. Placeholder scan** — every script in Tasks 1-3 is complete and runnable as written: full tmux setup, ivshmem server invocations, QEMU command lines, auto-login helpers, monitor/check loops, and FAIL-path diagnostics. No `TODO`/`TBD`/"similar to Task N" placeholders. All PASS-condition strings and regexes are taken verbatim from current source (`linux_syslog.c:572`, `linux_stats.c:133-152` & `209-227`, `shell.c`'s `shell_cmd_table`/`cmd_*` functions, `can_driver.c:71-72,163-164`).

**3. Type/name consistency** — environment variable names (`RISCV_HELLO_TIMEOUT`, `STATS_E2E_TIMEOUT`, `SHELL_E2E_TIMEOUT`), session name prefixes, and `common.sh` variable references (`IVSHMEM_*_FREERTOS_SOCKET`, `IVSHMEM_CAN_FREERTOS_SIZE`, `PINGPONG_SHARE_TAG`, `RISCV_KERNEL_CMDLINE`, etc.) are used consistently across each script and match `common.sh`'s actual definitions (verified by reading `common.sh` in full). The `_ok`/`_fail`/`_info`/`cleanup`/`auto_login_and_run` helper patterns match `guest-run-can-e2e-harness.sh` exactly.

No gaps found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-13-riscv-stats-shell-harnesses.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
