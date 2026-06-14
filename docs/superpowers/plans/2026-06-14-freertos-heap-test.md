# FreeRTOS Heap Leak/Regression Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh` to add a second `sysinfo` call after the existing 7-command sequence, extract `heap_free=N` from both invocations, and add 3 new on-target checks (sane at boot, above 4096 safety margin, stable between samples).

**Architecture:** Reuse the existing harness's command-and-capture flow. Capture the `heap_free=` value with a `mapfile` of `grep -oE` on `${OUTPUT}`. Guard the three new checks against empty `HEAP_BEFORE`/`HEAP_AFTER` (firmware-crash safety) by bailing out with a FAIL before arithmetic. Update the harness's header comment and the final summary count.

**Tech Stack:** Bash 4+ (`mapfile`, arrays), `tmux send-keys`/`capture-pane`, FreeRTOS shell over UART (no firmware changes).

---

## File Structure

| File | Change |
|---|---|
| `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh` | Modify — add 1 `send_cmd "sysinfo"`, 1 `mapfile` extraction block, 3 new checks, 2 comment updates |

No new files. No firmware changes. The harness is run via `limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`.

---

## Task 1: Update the header comment to mention the new heap check

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh:10-13`

- [ ] **Step 1: Replace the "Sends each of the 6 shell commands" comment block**

In `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`, replace lines 10–13 (the block that currently reads "Sends each of the 6 shell commands via `tmux send-keys`...") with this block:

```bash
# Sends the 6 documented shell commands + 1 unrecognized command via
# `tmux send-keys`, then a second `sysinfo` (as the final command) so we
# can compare heap_free=N before/after the 7-command sequence and assert
# the firmware has not leaked heap during shell/showcase activity. Verifies
# the exact output documented in README.md's "Interactive Shell" section:
#   help, stats, sysinfo, links, loglevel, can status
# plus one unrecognized-command check (shell_dispatch's default branch).
```

- [ ] **Step 2: Verify the change is in place**

Run:
```bash
sed -n '8,18p' /Volumes/Samsung970EVOPlus/dev-projects/chimera/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected: lines 8–18 contain the new comment block (mentioning the 6 + 1 + 1 = 8 commands and the heap comparison).

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
git add scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
git commit -m "test(shell-e2e): document second sysinfo call for heap leak check"
```

---

## Task 2: Add the second `sysinfo` call at the end of the command sequence

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh:117-124`

- [ ] **Step 1: Add the second `sysinfo` send_cmd after `frobnicate`**

In `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`, replace the existing block at lines 117–124 (the seven `send_cmd` lines plus the trailing `sleep 1`) with this block:

```bash
send_cmd "help"
send_cmd "stats"
send_cmd "sysinfo"
send_cmd "links"
send_cmd "loglevel"
send_cmd "can status"
send_cmd "frobnicate"
# Second sysinfo: paired with the first (line 119) to detect heap leaks
# that occur during shell/showcase activity. Equal in firmware to the
# first; only the order in the captured output differs.
send_cmd "sysinfo"
sleep 1
```

- [ ] **Step 2: Verify the new send_cmd is present**

Run:
```bash
grep -n 'send_cmd' /Volumes/Samsung970EVOPlus/dev-projects/chimera/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected output:
```
120:send_cmd "help"
121:send_cmd "stats"
122:send_cmd "sysinfo"
123:send_cmd "links"
124:send_cmd "loglevel"
125:send_cmd "can status"
126:send_cmd "frobnicate"
130:send_cmd "sysinfo"
```

(Eight `send_cmd` calls; `sysinfo` appears twice — once early, once at the end.)

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
git add scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
git commit -m "test(shell-e2e): send sysinfo a second time to capture heap baseline + final"
```

---

## Task 3: Add the `HEAP_BEFORE`/`HEAP_AFTER` extraction block and the 3 new checks

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh:165-169` (replace the existing "Checking 'sysinfo' output..." block)

- [ ] **Step 1: Replace the existing sysinfo check block with the new extraction + 3 checks**

In `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`, replace lines 166–169 (the block that currently reads `echo ""; echo "[harness] Checking 'sysinfo' output..."; check_regex "sysinfo: 4 numeric fields" 'heap_free=[0-9]+ uptime_s=[0-9]+ shell_stack_hiwat=[0-9]+ showcase_stack_hiwat=[0-9]+'`) with this block:

```bash
echo ""
echo "[harness] Checking 'sysinfo' output (1st call: 4 numeric fields)..."
check_regex "sysinfo: 4 numeric fields" \
    'heap_free=[0-9]+ uptime_s=[0-9]+ shell_stack_hiwat=[0-9]+ showcase_stack_hiwat=[0-9]+'

# Extract heap_free=N from the 1st (baseline) and 2nd (post-shell-activity)
# sysinfo invocations. heap_4 is one-time-alloc-only at boot, so they MUST
# be equal; a future change that allocates during shell/showcase activity
# will break this. configTOTAL_HEAP_SIZE=65536, safety margin=4096.
echo ""
echo "[harness] Checking heap leak (heap_free before vs after 7 commands)..."
mapfile -t HEAP_VALUES < <(echo "${OUTPUT}" | grep -oE 'heap_free=[0-9]+' | grep -oE '[0-9]+')
HEAP_BEFORE="${HEAP_VALUES[0]:-}"
HEAP_AFTER="${HEAP_VALUES[1]:-}"

if [[ -z "${HEAP_BEFORE}" || -z "${HEAP_AFTER}" ]]; then
    _fail "heap_free value not found in output (expected 2 sysinfo invocations)"
    (( ++FAIL_COUNT ))
else
    if (( HEAP_BEFORE > 0 && HEAP_BEFORE < 65536 )); then
        _ok "heap_free sane at boot (HEAP_BEFORE=${HEAP_BEFORE})"
    else
        _fail "heap_free sane at boot (HEAP_BEFORE=${HEAP_BEFORE}, expected 0 < N < 65536)"
        (( ++FAIL_COUNT ))
    fi

    if (( HEAP_BEFORE > 4096 )); then
        _ok "heap_free above safety margin (HEAP_BEFORE=${HEAP_BEFORE} > 4096)"
    else
        _fail "heap_free above safety margin (HEAP_BEFORE=${HEAP_BEFORE}, expected > 4096)"
        (( ++FAIL_COUNT ))
    fi

    if (( HEAP_AFTER == HEAP_BEFORE )); then
        _ok "heap_free stable (HEAP_AFTER=${HEAP_AFTER} == HEAP_BEFORE=${HEAP_BEFORE})"
    else
        _fail "heap_free stable (HEAP_AFTER=${HEAP_AFTER} != HEAP_BEFORE=${HEAP_BEFORE})"
        (( ++FAIL_COUNT ))
    fi
fi
```

- [ ] **Step 2: Verify the new block is in place**

Run:
```bash
grep -nE 'HEAP_BEFORE|HEAP_AFTER|HEAP_VALUES|heap_free sane|heap_free above safety|heap_free stable' /Volumes/Samsung970EVOPlus/dev-projects/chimera/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected output: 8 matches — one `mapfile` line, two `${HEAP_VALUES[N]:-}` lines, two `HEAP_BEFORE=` lines, two `HEAP_AFTER=` lines, plus one of each `_ok "heap_free ..."` line.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
git add scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
git commit -m "test(shell-e2e): assert heap_free is sane, above margin, and stable"
```

---

## Task 4: Update the final summary count from 16 → 19

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh:192`

- [ ] **Step 1: Update the summary line**

In `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`, replace the line `echo "[harness] PASS — all 16 shell command checks passed"` with:

```bash
    echo "[harness] PASS — all 19 shell command checks passed"
```

- [ ] **Step 2: Verify the new count is present**

Run:
```bash
grep -n 'all 19' /Volumes/Samsung970EVOPlus/dev-projects/chimera/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected: one match (line ~198) with `all 19 shell command checks passed`.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
git add scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
git commit -m "test(shell-e2e): bump pass-summary check count from 16 to 19"
```

---

## Task 5: Run the harness in Lima and confirm all 19 checks PASS

**Files:**
- No source changes — this is a validation step.

- [ ] **Step 1: Deploy the modified harness to the Lima VM (so the change is visible to `limactl shell`)**

The harness lives at `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh` on macOS, which the Lima VM `qemu-dev` mounts read-write at `$HOME/chimera-src/` (per `CLAUDE.md` → "Deploy Path: Worktree → macOS → Lima"). The file edit was made on macOS, so the change is already visible to Lima — no deploy step is needed. Confirm by reading the file from inside Lima:

Run:
```bash
limactl shell qemu-dev -- bash -c "grep -c 'send_cmd' \$HOME/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh"
```

Expected: `8` (eight `send_cmd` lines, per Task 2 Step 2).

- [ ] **Step 2: Run the harness**

Run:
```bash
cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
```

Expected: the script exits 0 and prints `[harness] PASS — all 19 shell command checks passed`. The 3 new checks should each print a green `OK` line with their `HEAP_BEFORE` value, and `HEAP_AFTER` should equal `HEAP_BEFORE` exactly.

- [ ] **Step 3: If the harness fails, diagnose from the output**

If the harness reports FAIL, the most likely causes are:
- Empty `HEAP_BEFORE`/`HEAP_AFTER` → the firmware crashed before one of the `sysinfo` calls. Check that the FreeRTOS QEMU booted and the `chimera>` prompt was detected (already verified by the existing harness flow).
- `HEAP_AFTER != HEAP_BEFORE` → a real regression; check whether the showcase task or shell task allocates heap at runtime. This would be a genuine bug, not a test issue.
- `HEAP_BEFORE <= 4096` → a future regression where kernel objects consume more of the 64 KiB heap. Likely caused by a recent code change (check `git log` since the last green harness run).

If any of the above, the change is doing its job — fix the firmware, do not weaken the check.

- [ ] **Step 4: Verify the working tree is clean**

Run:
```bash
cd /Volumes/Samsung970EVOPlus/dev-projects/chimera
git status
```

Expected: `nothing to commit, working tree clean` (or only the harness change already committed in Tasks 1–4 if not yet pushed).
