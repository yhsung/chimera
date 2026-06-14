# Named Pane Targeting for Chimera Showcase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each of the 9 panes in the `freertos-showcase` tmux session be addressed by a human-readable name (e.g. `freertos`, `arm-linux`) from the Lima command line, for `send-keys`/`capture-pane`, instead of numeric indices (`0.0`–`0.8`).

**Architecture:** `guest-run-phase5-tmux.sh` tags each pane with a tmux title via `select-pane -T <name>` and enables `pane-border-status` so titles are visible when attached. A new helper script, `guest-tmux-pane.sh`, holds a static name→index map (tmux can't target by title in `-t`) and wraps `tmux send-keys`/`tmux capture-pane`. README.md and CLAUDE.md are updated to document both the name table and the new helper.

**Tech Stack:** bash (`set -euo pipefail`), tmux 3.4+ (`select-pane -T`, `pane-border-status`/`pane-border-format`), Lima VM (`qemu-dev`).

---

## Pane name mapping (reference for all tasks)

| Index | Name | Role |
|---|---|---|
| 0.0 | `ivshmem-arm` | ivshmem-server ARM ↔ FreeRTOS |
| 0.1 | `ivshmem-riscv` | ivshmem-server RISCV ↔ FreeRTOS |
| 0.2 | `ivshmem-mips` | ivshmem-server MIPS ↔ FreeRTOS |
| 0.3 | `ivshmem-stats` | ivshmem-server stats → ARM |
| 0.4 | `ivshmem-bootlog` | ivshmem-server boot-log → ARM |
| 0.5 | `freertos` | R52 FreeRTOS firmware (UART/shell) |
| 0.6 | `arm-linux` | ARM-Linux guest |
| 0.7 | `riscv-linux` | RISCV-Linux guest |
| 0.8 | `mips-linux` | MIPS-Linux guest |

Only `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` (invoked by `guest-run-chimera-showcase.sh`) creates a session literally named `freertos-showcase`. The e2e harness scripts create their own short-lived `<name>-${RUN_ID}` sessions with a different layout, so they are unaffected by this change.

---

### Task 1: Tag panes with titles in guest-run-phase5-tmux.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh:66-69`

- [ ] **Step 1: Insert pane-title and border-status calls after the split sequence**

In `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`, the split sequence ends at line 67, immediately followed by the stale-process cleanup comment at line 69:

```bash
tmux split-window -h -t "$SESSION:0.6" -l 67%
tmux split-window -h -t "$SESSION:0.7" -l 50%

# Kill any stale QEMU processes that outlived a previous session.
```

Replace it with:

```bash
tmux split-window -h -t "$SESSION:0.6" -l 67%
tmux split-window -h -t "$SESSION:0.7" -l 50%

# Name each pane for command-line addressing (see guest-tmux-pane.sh).
tmux select-pane -t "$SESSION:0.0" -T "ivshmem-arm"
tmux select-pane -t "$SESSION:0.1" -T "ivshmem-riscv"
tmux select-pane -t "$SESSION:0.2" -T "ivshmem-mips"
tmux select-pane -t "$SESSION:0.3" -T "ivshmem-stats"
tmux select-pane -t "$SESSION:0.4" -T "ivshmem-bootlog"
tmux select-pane -t "$SESSION:0.5" -T "freertos"
tmux select-pane -t "$SESSION:0.6" -T "arm-linux"
tmux select-pane -t "$SESSION:0.7" -T "riscv-linux"
tmux select-pane -t "$SESSION:0.8" -T "mips-linux"
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format "#{pane_index}:#{pane_title}"

# Kill any stale QEMU processes that outlived a previous session.
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
git commit -m "feat(showcase): tag tmux panes with names and enable pane-border-status"
```

---

### Task 2: Add guest-tmux-pane.sh helper script

**Files:**
- Create: `scripts/heterogeneous-soc/guest-tmux-pane.sh`

- [ ] **Step 1: Write the helper script**

Create `scripts/heterogeneous-soc/guest-tmux-pane.sh`:

```bash
#!/usr/bin/env bash
# guest-tmux-pane.sh
#
# Address panes of the "freertos-showcase" tmux session (see
# guest-run-phase5-tmux.sh) by name instead of numeric index.
#
# Usage:
#   guest-tmux-pane.sh list
#   guest-tmux-pane.sh <name> send "<command>"
#   guest-tmux-pane.sh <name> capture [N]
#
# Run this from inside the Lima VM:
#   limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos capture
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

SESSION="${SESSION:-freertos-showcase}"

declare -A PANES=(
    [ivshmem-arm]="0.0"
    [ivshmem-riscv]="0.1"
    [ivshmem-mips]="0.2"
    [ivshmem-stats]="0.3"
    [ivshmem-bootlog]="0.4"
    [freertos]="0.5"
    [arm-linux]="0.6"
    [riscv-linux]="0.7"
    [mips-linux]="0.8"
)

PANE_ORDER=(ivshmem-arm ivshmem-riscv ivshmem-mips ivshmem-stats ivshmem-bootlog freertos arm-linux riscv-linux mips-linux)

usage() {
    cat <<'EOF'
Usage:
  guest-tmux-pane.sh list
  guest-tmux-pane.sh <name> send "<command>"
  guest-tmux-pane.sh <name> capture [N]

Names: ivshmem-arm ivshmem-riscv ivshmem-mips ivshmem-stats ivshmem-bootlog
       freertos arm-linux riscv-linux mips-linux
EOF
}

if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "$1" == "list" ]]; then
    printf '%-15s %s\n' "NAME" "PANE"
    for name in "${PANE_ORDER[@]}"; do
        printf '%-15s %s\n' "${name}" "${PANES[${name}]}"
    done
    exit 0
fi

NAME="$1"
ACTION="${2:-}"

[[ -n "${PANES[${NAME}]+x}" ]] || die "unknown pane name '${NAME}'. Valid names: ${PANE_ORDER[*]}"

TARGET="${SESSION}:${PANES[${NAME}]}"

tmux has-session -t "${SESSION}" 2>/dev/null || die "tmux session '${SESSION}' not running. Launch it with guest-run-chimera-showcase.sh"

case "${ACTION}" in
    send)
        CMD="${3:-}"
        [[ -n "${CMD}" ]] || die "usage: guest-tmux-pane.sh ${NAME} send \"<command>\""
        tmux send-keys -t "${TARGET}" "${CMD}" Enter
        ;;
    capture)
        LINES="${3:-}"
        if [[ -n "${LINES}" ]]; then
            tmux capture-pane -p -t "${TARGET}" | tail -n "${LINES}"
        else
            tmux capture-pane -p -t "${TARGET}"
        fi
        ;;
    *)
        usage
        exit 1
        ;;
esac
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/heterogeneous-soc/guest-tmux-pane.sh`

- [ ] **Step 3: Syntax-check the script**

Run: `bash -n scripts/heterogeneous-soc/guest-tmux-pane.sh`
Expected: no output (exit 0).

- [ ] **Step 4: Verify `list` output (runs locally, no tmux session needed)**

Run: `bash scripts/heterogeneous-soc/guest-tmux-pane.sh list`
Expected output:
```
NAME            PANE
ivshmem-arm     0.0
ivshmem-riscv   0.1
ivshmem-mips    0.2
ivshmem-stats   0.3
ivshmem-bootlog 0.4
freertos        0.5
arm-linux       0.6
riscv-linux     0.7
mips-linux      0.8
```

- [ ] **Step 5: Verify unknown-name error path (runs locally)**

Run: `bash scripts/heterogeneous-soc/guest-tmux-pane.sh bogus send x; echo "exit=$?"`
Expected: stderr line `error: unknown pane name 'bogus'. Valid names: ivshmem-arm ivshmem-riscv ivshmem-mips ivshmem-stats ivshmem-bootlog freertos arm-linux riscv-linux mips-linux` and `exit=1`.

- [ ] **Step 6: Commit**

```bash
git add scripts/heterogeneous-soc/guest-tmux-pane.sh
git commit -m "feat(showcase): add guest-tmux-pane.sh for name-based pane access"
```

---

### Task 3: Document pane names in README.md

**Files:**
- Modify: `README.md:351-385`

- [ ] **Step 1: Add a Name column to the Tmux Pane Layout table**

Replace the table at README.md lines 351-361:

```markdown
| Pane | Contents |
|---|---|
| 0 | `ivshmem-server` — ARM ↔ FreeRTOS |
| 1 | `ivshmem-server` — RISCV ↔ FreeRTOS |
| 2 | `ivshmem-server` — MIPS ↔ FreeRTOS |
| 3 | `ivshmem-server` — stats → ARM |
| 4 | `ivshmem-server` — boot-log → ARM |
| 5 | R52 FreeRTOS (HELLO/ACK on all channels; stats snapshot every 5 s; CAN RX → IVSHMEM5; boot-log monitor) |
| 6 | ARM-Linux: `linux-arm-stats` (bg), `syslog-arm-linux`, `bootlog-arm-linux`, brings up `can0` + `can-log-arm-linux`, `boot-collector` |
| 7 | RISCV-Linux: `syslog-riscv-linux`, `bootlog-riscv-linux` |
| 8 | MIPS-Linux: `syslog-mips-linux`, `bootlog-mips-linux` |
```

with:

```markdown
| Pane | Name | Contents |
|---|---|---|
| 0 | `ivshmem-arm` | `ivshmem-server` — ARM ↔ FreeRTOS |
| 1 | `ivshmem-riscv` | `ivshmem-server` — RISCV ↔ FreeRTOS |
| 2 | `ivshmem-mips` | `ivshmem-server` — MIPS ↔ FreeRTOS |
| 3 | `ivshmem-stats` | `ivshmem-server` — stats → ARM |
| 4 | `ivshmem-bootlog` | `ivshmem-server` — boot-log → ARM |
| 5 | `freertos` | R52 FreeRTOS (HELLO/ACK on all channels; stats snapshot every 5 s; CAN RX → IVSHMEM5; boot-log monitor) |
| 6 | `arm-linux` | ARM-Linux: `linux-arm-stats` (bg), `syslog-arm-linux`, `bootlog-arm-linux`, brings up `can0` + `can-log-arm-linux`, `boot-collector` |
| 7 | `riscv-linux` | RISCV-Linux: `syslog-riscv-linux`, `bootlog-riscv-linux` |
| 8 | `mips-linux` | MIPS-Linux: `syslog-mips-linux`, `bootlog-mips-linux` |
```

- [ ] **Step 2: Add a "Targeting panes by name" subsection**

Immediately after the "Navigate with **Ctrl-b**..." paragraph (README.md line 365) and before the `---` separator (line 367), insert:

```markdown

### Targeting panes by name

Each pane carries a tmux title (visible via `pane-border-status`) and can be addressed by name with `guest-tmux-pane.sh` instead of the numeric index:

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh list
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos send "stats"
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos capture 20
```
```

(Keep the existing `---` separator and "## Interactive Shell" heading that follow.)

- [ ] **Step 3: Add named-form examples to the Interactive Shell section**

The Interactive Shell section currently shows (README.md lines 382-385):

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "help" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -20
```

Append two lines after it (same code block):

```bash
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.5 "help" Enter
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.5 | tail -20

# or, by name:
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos send "help"
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos capture 20
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document named tmux pane access for the showcase session"
```

---

### Task 4: Document guest-tmux-pane.sh in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md:294-301`

- [ ] **Step 1: Replace the "Accessing guest tmux panes" section**

Replace CLAUDE.md lines 294-301:

```markdown
### Accessing guest tmux panes
```bash
# Capture a tmux pane (pane numbering: 0.0–0.5 = top 5 ivshmem servers + FreeRTOS, 0.6 = ARM, 0.7 = RISCV, 0.8 = MIPS)
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.6 | tail -50

# Send a command to a running guest pane
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.6 "ls /var/log/chimera-log/boot-log/" Enter
```
```

with:

```markdown
### Accessing guest tmux panes

Panes are named (`ivshmem-arm`, `ivshmem-riscv`, `ivshmem-mips`, `ivshmem-stats`, `ivshmem-bootlog`, `freertos`, `arm-linux`, `riscv-linux`, `mips-linux` — pane indices 0.0–0.8 in that order) and addressable via `guest-tmux-pane.sh`:

```bash
# Capture a pane by name
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh arm-linux capture | tail -50

# Send a command to a running guest pane by name
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh arm-linux send "ls /var/log/chimera-log/boot-log/"

# Equivalent raw-index form (pane numbering: 0.0–0.5 = top 5 ivshmem servers + FreeRTOS, 0.6 = ARM, 0.7 = RISCV, 0.8 = MIPS)
limactl shell qemu-dev -- tmux capture-pane -p -t freertos-showcase:0.6 | tail -50
limactl shell qemu-dev -- tmux send-keys -t freertos-showcase:0.6 "ls /var/log/chimera-log/boot-log/" Enter
```
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document guest-tmux-pane.sh in Direct Lima Access"
```

---

### Task 5: End-to-end verification in Lima

**Files:** none (verification only)

- [ ] **Step 1: Deploy the updated worktree to Lima**

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
```

- [ ] **Step 2: Relaunch the showcase so the new pane titles take effect**

Pane titles are set at session-creation time, so an already-running session must be relaunched. If a `freertos-showcase` session is already running with built artifacts, this is fast (`SKIP_BUILD=1`):

```bash
limactl shell qemu-dev -- tmux kill-session -t freertos-showcase 2>/dev/null || true
limactl shell qemu-dev -- bash -c 'cd ~/chimera-src && SKIP_BUILD=1 bash scripts/heterogeneous-soc/guest-run-chimera-showcase.sh' &
```

Wait ~30s for ivshmem servers + FreeRTOS to come up before proceeding.

- [ ] **Step 3: Verify pane titles**

```bash
limactl shell qemu-dev -- tmux list-panes -t freertos-showcase -F '#{pane_index}: #{pane_title}'
```

Expected (order may vary, all 9 must be present):
```
0: ivshmem-arm
1: ivshmem-riscv
2: ivshmem-mips
3: ivshmem-stats
4: ivshmem-bootlog
5: freertos
6: arm-linux
7: riscv-linux
8: mips-linux
```

- [ ] **Step 4: Round-trip send + capture against the FreeRTOS shell**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos send "help"
sleep 1
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh freertos capture 20
```

Expected: the captured output includes the FreeRTOS shell command-list (`help`, `stats`, `sysinfo`, `links`, `loglevel`, `can status`, etc., per README.md's "Interactive Shell" table).

- [ ] **Step 5: Capture a Linux guest pane by name**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-tmux-pane.sh arm-linux capture 10
```

Expected: recent ARM-Linux console output (shell prompt / syslog-arm-linux activity), no error.

- [ ] **Step 6: Confirm CI harnesses still pass (sanity check — they use separate sessions)**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-shell-harness.sh
```

Expected: exit 0 / PASS, confirming the change to `guest-run-phase5-tmux.sh` did not affect the unrelated harness sessions.
