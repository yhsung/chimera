# FreeRTOS Heap Leak/Regression Check Design

**Date:** 2026-06-14
**Status:** Draft

## Goal

Add an on-target check that the FreeRTOS firmware's heap usage
(`xPortGetFreeHeapSize()`, already exposed via the shell's `sysinfo` command)
is sane at boot and stable across shell/showcase activity, to guard against
future heap exhaustion or leaks.

## Background

- `FreeRTOSConfig.h` sets `configTOTAL_HEAP_SIZE` to `64 * 1024` (65536) bytes
  and uses `heap_4` (`configSUPPORT_DYNAMIC_ALLOCATION 1`,
  `configSUPPORT_STATIC_ALLOCATION 0`).
- All heap usage today is one-time kernel-object creation at boot (idle task,
  showcase task, shell task, `uart_rx_queue`, etc.) — no application code
  calls `pvPortMalloc`/`malloc` after `vTaskStartScheduler()`.
- `sysinfo` already prints `heap_free=<bytes> uptime_s=<n>
  shell_stack_hiwat=<words> showcase_stack_hiwat=<words>` (`shell.c`,
  `cmd_sysinfo`).
- `guest-run-shell-e2e-harness.sh` already boots FreeRTOS headless (no Linux
  guests, CAN ivshmem attached for deterministic `can status`), drives 7
  shell commands via `tmux send-keys`, captures the pane, and checks output
  with `check_contains`/`check_regex` helpers. It currently reports "all 16
  shell command checks passed".

## Approach

No new harness, no new QEMU/Linux guests, no new ivshmem servers. Extend
`guest-run-shell-e2e-harness.sh`:

1. Add one new `send_cmd "sysinfo"` as the **last** command, after the
   existing `send_cmd "frobnicate"`. The existing `sysinfo` call (3rd
   command, after `help`/`stats`) becomes the "before" sample; the new call
   becomes the "after" sample.
2. After capturing `OUTPUT`, extract both `heap_free=N` values:
   ```bash
   mapfile -t HEAP_VALUES < <(echo "${OUTPUT}" | grep -oE 'heap_free=[0-9]+' | grep -oE '[0-9]+')
   HEAP_BEFORE="${HEAP_VALUES[0]:-}"
   HEAP_AFTER="${HEAP_VALUES[1]:-}"
   ```
3. Add three checks to the existing "sysinfo" check block:
   - **`sysinfo: heap_free sane at boot`** — `0 < HEAP_BEFORE < 65536`
     (65536 = `configTOTAL_HEAP_SIZE`). Catches corruption/overflow of the
     reported value or a heap that's already exhausted at boot.
   - **`sysinfo: heap_free above safety margin`** — `HEAP_BEFORE > 4096`.
     Catches a future regression where a task stack, queue, or buffer grows
     large enough to nearly exhaust the 64 KiB heap.
   - **`sysinfo: heap_free stable (no leak)`** — `HEAP_AFTER == HEAP_BEFORE`
     (exact equality). Since no application code allocates heap after boot,
     any drift between the two samples indicates a future change leaked
     heap during shell/showcase activity.
4. Guard all three numeric checks with `[[ -n "$HEAP_BEFORE" && -n
   "$HEAP_AFTER" ]]` before doing arithmetic comparisons — if either is
   empty (e.g. the firmware crashed before the second `sysinfo`), fail with
   a clear message instead of a bash arithmetic error (`((  ))` on an empty
   string).
5. Update the final summary line from "all 16 shell command checks passed"
   to "all 19 shell command checks passed" (16 existing + 3 new).
6. Update the harness's header comment to mention the new heap check.

## Error Handling

- Empty `HEAP_BEFORE`/`HEAP_AFTER` (grep found 0 or 1 matches instead of 2):
  each of the three new checks reports FAIL with a message like "heap_free
  value not found in output" rather than crashing the script on `(( ))`
  with an empty operand.
- All other existing checks/flows (boot-prompt wait, ivshmem server startup,
  cleanup trap) are unchanged.

## Testing

This change only modifies a test harness; the firmware itself (`sysinfo` /
`xPortGetFreeHeapSize()`) is unchanged. Validate by running the harness in
Lima:

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected: all 19 checks PASS, with `HEAP_BEFORE == HEAP_AFTER` (no leak from
shell command processing) and `HEAP_BEFORE` comfortably between 4096 and
65536 bytes.
