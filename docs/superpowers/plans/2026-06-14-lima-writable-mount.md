# Lima Writable Mount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Lima `qemu-dev` VM's `~` virtiofs mount read-write so `/Users/yhsung/chimera-src` is directly writable from inside Lima, eliminating the second Lima-local source copy at `/home/yhsung.guest/chimera-src`.

**Architecture:** `limactl edit --mount-writable` flips the existing `mounts: - location: "~"` entry in `~/.lima/qemu-dev/lima.yaml` to `writable: true`, requiring a VM stop/start cycle to take effect. `scripts/heterogeneous-soc/common.sh` already has the logic to use a writable `/Users/*` `CHIMERA_ROOT` directly (`default_vm_source_dir`, `default_build_dir`, `default_pingpong_dir` all branch on `-w "${CHIMERA_ROOT}"`), so no script changes are needed — only verification and a documentation update to `CLAUDE.md`.

**Tech Stack:** Lima 2.1.2 (vz/virtiofs), bash, macOS host + Ubuntu 24.04 guest.

---

### Task 1: Make the Lima `qemu-dev` mount writable

**Files:**
- Modify (via `limactl edit`, not direct edit): `~/.lima/qemu-dev/lima.yaml`

- [ ] **Step 1: Confirm nothing is running inside the VM before restarting it**

Run:
```bash
limactl shell qemu-dev -- bash -c 'pgrep -fl qemu-system || echo "no qemu running"; tmux ls 2>/dev/null || echo "no tmux sessions"'
```
Expected:
```
no qemu running
no tmux sessions
```
If this shows a running QEMU/tmux session instead, STOP — do not proceed until the user confirms it's safe to restart the VM (restart will kill it).

- [ ] **Step 2: Stop the Lima VM**

Run:
```bash
limactl stop qemu-dev
```
Expected: command exits 0 and `limactl list` shows `qemu-dev` with `STATUS Stopped`.

- [ ] **Step 3: Flip the mount to writable**

Run:
```bash
limactl edit qemu-dev --mount-writable -y
```
Expected: command exits 0 with no error output.

- [ ] **Step 4: Verify the YAML change**

Run:
```bash
grep -A2 "^mounts:" ~/.lima/qemu-dev/lima.yaml
```
Expected:
```
mounts:
- location: "~"
  writable: true
```

- [ ] **Step 5: Start the Lima VM**

Run:
```bash
limactl start qemu-dev
```
Expected: command exits 0 and `limactl list` shows `qemu-dev` with `STATUS Running`.

- [ ] **Step 6: Verify the mount is now read-write inside Lima**

Run:
```bash
limactl shell qemu-dev -- mount | grep "/Users/yhsung "
```
Expected: output contains `rw,relatime` (previously `ro,relatime`), e.g.:
```
lima-a6cf7a4d5dbfce60 on /Users/yhsung type virtiofs (rw,relatime)
```

- [ ] **Step 7: Functional write test — write from Lima, read from macOS, clean up**

Run:
```bash
limactl shell qemu-dev -- bash -c 'echo "written from lima $(date)" > /Users/yhsung/chimera-src/.lima-writable-test'
cat /Users/yhsung/chimera-src/.lima-writable-test
rm /Users/yhsung/chimera-src/.lima-writable-test
limactl shell qemu-dev -- bash -c '[[ -e /Users/yhsung/chimera-src/.lima-writable-test ]] && echo "STILL THERE" || echo "CLEANED UP"'
```
Expected:
- `cat` on macOS prints the `written from lima ...` line.
- Final check prints `CLEANED UP`.

---

### Task 2: Verify `common.sh` resolves to the unified writable tree

No source files change in this task — it's verification that the existing conditional logic in `scripts/heterogeneous-soc/common.sh:12-26,68-74,133-145` now takes the "writable `/Users/*`" branch.

**Files:**
- Read only: `scripts/heterogeneous-soc/common.sh`

- [ ] **Step 1: Print resolved path variables from inside Lima**

Run:
```bash
limactl shell qemu-dev -- bash -c 'cd /Users/yhsung/chimera-src/scripts/heterogeneous-soc && source common.sh && echo "CHIMERA_ROOT=$CHIMERA_ROOT" && echo "VM_SOURCE_DIR=$VM_SOURCE_DIR" && echo "BUILD_DIR=$BUILD_DIR" && echo "PINGPONG_DIR=$PINGPONG_DIR"'
```
Expected:
```
CHIMERA_ROOT=/Users/yhsung/chimera-src
VM_SOURCE_DIR=/Users/yhsung/chimera-src
BUILD_DIR=/Users/yhsung/chimera-src/build-linux
PINGPONG_DIR=/Users/yhsung/chimera-src/contrib/heterogeneous-soc
```

- [ ] **Step 2: Confirm `prepare_vm_source_tree` is now a no-op**

Run:
```bash
limactl shell qemu-dev -- bash -c 'cd /Users/yhsung/chimera-src/scripts/heterogeneous-soc && source common.sh && [[ "$VM_SOURCE_DIR" == "$CHIMERA_ROOT" ]] && echo "NOOP: prepare_vm_source_tree will skip rsync" || echo "WILL RSYNC"'
```
Expected:
```
NOOP: prepare_vm_source_tree will skip rsync
```

If either step's output doesn't match, STOP and report the actual output — it means the writable-mount detection in `common.sh` isn't taking effect and the doc update in Task 3 should not proceed yet.

---

### Task 3: Update `CLAUDE.md` deploy-path documentation

**Files:**
- Modify: `CLAUDE.md` (Quick Start step 2, and the "Deploy Path" section)

- [ ] **Step 1: Update Quick Start step 2 to use the writable macOS-mounted path**

In `CLAUDE.md`, find:
```markdown
**Step 2 — Launch the full showcase** (from macOS host; re-run any time):

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```
```

Replace with:
```markdown
**Step 2 — Launch the full showcase** (from macOS host; re-run any time):

```bash
limactl shell qemu-dev -- bash /Users/yhsung/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```
```

- [ ] **Step 2: Replace the "Deploy Path" section**

In `CLAUDE.md`, find the section starting with `## Deploy Path: Worktree → macOS → Lima-local` and ending right before the next `##` heading (`## FreeRTOS Exception Handlers`):

```markdown
## Deploy Path: Worktree → macOS → Lima-local

`host-install-lima-host.sh` deploys the worktree to `/Users/yhsung/chimera-src` on macOS.  Inside the Lima VM, `$HOME` resolves to `/home/yhsung.guest` and `~` expansion from the **local** shell (macOS) resolves to `/Users/yhsung`.  This creates two different source trees:

| Path | Populated by | Used by |
|---|---|---|
| `/Users/yhsung/chimera-src` | `host-install-lima-host.sh` | reference / diff |
| `/home/yhsung.guest/chimera-src` | manual deploy or `cp` from `/Users/…` | `guest-build-freertos-showcase.sh` |

**After editing source in the worktree, you must deploy to the Lima-local path:**
```bash
# Option A: Run host-install, then copy inside Lima
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- cp /Users/yhsung/chimera-src/path/to/file $HOME/chimera-src/path/to/file

# Option B: Transfer directly via base64 (avoids quoting issues)
base64 -i <worktree-file> | limactl shell qemu-dev -- bash -c 'base64 -d > /home/yhsung.guest/chimera-src/path/to/file'
```
```

Replace the entire block with:

```markdown
## Deploy Path: Worktree → macOS → Lima (writable mount)

`host-install-lima-host.sh` deploys the worktree to `/Users/yhsung/chimera-src` on macOS via `rsync`. The Lima VM `qemu-dev` mounts the macOS home directory (`~`) **read-write** via virtiofs at the same path, so `/Users/yhsung/chimera-src` is directly writable from inside Lima — no second copy is required.

`scripts/heterogeneous-soc/common.sh` detects this automatically: when `CHIMERA_ROOT` (derived from the running script's own path) is under `/Users/` and writable, `VM_SOURCE_DIR`, `BUILD_DIR`, and `PINGPONG_DIR` all resolve under `/Users/yhsung/chimera-src` directly, and `prepare_vm_source_tree` becomes a no-op.

**After editing source in the worktree, re-run host-install and build in place — no copy step:**
```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
limactl shell qemu-dev -- bash /Users/yhsung/chimera-src/scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
```

A pre-existing Lima-local copy at `/home/yhsung.guest/chimera-src` (Lima `$HOME`) may still be present from before this mount was made writable. It is no longer required by any script that sources `common.sh` and can be left in place or removed.
```

---

### Task 4: Commit the documentation update

**Files:**
- `CLAUDE.md`

- [ ] **Step 1: Review the diff**

Run:
```bash
git diff CLAUDE.md
```
Expected: shows only the two edits from Task 3 (Quick Start step 2 command + Deploy Path section replacement).

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document writable Lima mount, drop Lima-local copy step"
```
Expected: commit succeeds; `git log --oneline -1` shows the new commit on `master`.

---

## Notes / Out of Scope

- This plan does not touch scripts that hardcode `/home/yhsung.guest/chimera-src` (e.g. `host-open-phase5-iterm.sh`, `guest-run-phase5-tmux.sh`'s `VM_SOURCE_DIR="$HOME/chimera-src"` override) — those continue to work unchanged against the old Lima-local copy if the user still uses that workflow. Migrating them is a separate, optional follow-up.
- No code in `scripts/heterogeneous-soc/*.sh` changes — `common.sh`'s existing `-w "${CHIMERA_ROOT}"` branches already do the right thing once the mount is writable.
