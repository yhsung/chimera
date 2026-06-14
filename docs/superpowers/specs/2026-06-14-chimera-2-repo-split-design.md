# Chimera-2 Repo Split Design — Extracting the Apache-2.0 Demo into a New Repo

## Context

Phase 1 (already committed and pushed to `chimera` master) classified
`contrib/heterogeneous-soc/` and `scripts/heterogeneous-soc/` as
independent of QEMU's GPL codebase and relicensed them under Apache-2.0:
SPDX headers on 106 files, per-directory `LICENSE`/`NOTICE` files
(commits `cbe46808a6`, `72707ab08a`, `5fca536c55`, `4995b504e1`).

This spec covers the next step: moving those two directories into a new,
fully independent repository, `https://github.com/yhsung/chimera-2`, and
re-establishing the relationship between chimera-2 (the demo, Apache-2.0)
and chimera (the QEMU fork, GPL-2.0-or-later) via a git submodule.

## Goals

- `chimera-2` becomes the primary, independent home for the heterogeneous
  SoC demo: `contrib/heterogeneous-soc/` and `scripts/heterogeneous-soc/`
  at its root, plus root-level `LICENSE` (Apache-2.0) and `NOTICE`.
- `chimera` no longer contains these two directories at all.
- `chimera-2` includes `chimera` as a git submodule (`qemu/`), pinned to
  a specific commit, so `git clone --recurse-submodules` yields a
  complete, runnable workspace.
- The ~274 commits of history for the two directories are preserved in
  `chimera-2` via `git filter-repo`, run on a throwaway clone (chimera's
  published history is not rewritten).
- `chimera`'s README/CLAUDE.md/AGENTS.md are trimmed to QEMU-fork-only
  content with a pointer to chimera-2; chimera-2 gets new top-level docs
  adapted from chimera's current demo-focused content.

## Non-Goals

- Splitting or duplicating `docs/superpowers/plans/` and
  `docs/superpowers/specs/` (~30 files). These stay in `chimera` as a
  historical record; chimera-2's new docs link back to them for design
  rationale.
- Rewriting or force-pushing chimera's existing history.
- Automatic submodule version tracking (`git submodule update --remote`).
  Submodule bumps are manual, deliberate commits.
- CI/CD setup for chimera-2 (a prior spec,
  `2026-06-14-github-ci-cd-design.md`, designed CI for chimera but it has
  not been implemented yet; adapting it for the split repo layout is a
  separate future effort).

---

## Architecture: End-State Repo Layouts

### `chimera-2` (new repo, Apache-2.0, root of the project going forward)

```
chimera-2/
├── LICENSE                      (NEW — Apache-2.0 full text at root, so
│                                  GitHub shows the Apache-2.0 badge)
├── NOTICE                        (NEW — consolidates the two existing
│                                  per-directory NOTICE files: FreeRTOS
│                                  Kernel MIT attribution + third-party
│                                  tools note for QEMU/Lima/tmux)
├── README.md                    (NEW — adapted from chimera's current
│                                  README: overview, Architecture, Wire
│                                  Protocol, Tmux Pane Layout, Interactive
│                                  Shell, Guest Networking & Avahi,
│                                  Running the Demo, Licensing)
├── CLAUDE.md                     (NEW — adapted from chimera's current
│                                  CLAUDE.md: Quick Start, Workflow, Debug
│                                  Loop, harness docs, Git/Worktree/Shell
│                                  conventions, Lima access, env-var table)
├── AGENTS.md                     (NEW — same adaptation as CLAUDE.md)
├── contrib/heterogeneous-soc/   (moved, history preserved via filter-repo)
│   ├── LICENSE, NOTICE          (existing per-dir copies, kept — harmless
│   │                              redundancy alongside the new root copies)
│   └── freertos-showcase/, ping.c, pong.c, ivshmem_proto.h, ...
├── scripts/heterogeneous-soc/   (moved, history preserved via filter-repo)
│   ├── LICENSE, NOTICE          (kept, same rationale)
│   └── common.sh, guest-*.sh, host-*.sh, ...
└── qemu/                         (git submodule → github.com/yhsung/chimera,
                                    pinned to a commit; GPL-2.0-or-later,
                                    license stays self-contained inside the
                                    submodule)
```

### `chimera` (existing repo, GPL-2.0-or-later QEMU fork — trimmed)

```
chimera/
├── LICENSE, COPYING, COPYING.LIB   (unchanged — stock QEMU licensing)
├── README.rst                      (unchanged — stock upstream QEMU readme)
├── README.md                       (trimmed — new "Chimera Fork
│                                     Additions" section: machine-model +
│                                     ivshmem-flat table rows, ivshmem
│                                     Device Types, FreeRTOS DRAM
│                                     Configuration, Licensing note,
│                                     pointer to chimera-2)
├── CLAUDE.md                       (trimmed — "What This Repo Is"
│                                     rewritten for QEMU-fork scope,
│                                     Building QEMU, general Git
│                                     Conventions, short shared-constraint
│                                     sections, pointer to chimera-2)
├── AGENTS.md                       (same trim as CLAUDE.md)
├── docs/superpowers/plans/         (UNCHANGED — historical record)
├── docs/superpowers/specs/         (UNCHANGED — historical record,
│                                     including this spec)
├── hw/arm/chimera_r52_freertos_demo.c, include/hw/arm/...h
├── hw/misc/ivshmem-flat.c, include/hw/misc/ivshmem-flat.h
└── (contrib/heterogeneous-soc/ and scripts/heterogeneous-soc/ REMOVED)
```

Both end states keep their respective licensing self-contained: chimera-2
is wholly Apache-2.0 (root `LICENSE`/`NOTICE` cover `contrib/` and
`scripts/`); the `qemu/` submodule is a separate GPL-2.0-or-later repo
with its own `LICENSE`/`COPYING`, and submodules do not inherit or affect
the parent repo's license classification.

---

## Submodule Wiring & Pinning Workflow

Ordering matters: chimera's cleanup commit (removing the two directories)
must land **before** chimera-2 pins its submodule, so the submodule
checkout never contains stale copies of directories that now live at
chimera-2's root.

`.gitmodules` in chimera-2:
```ini
[submodule "qemu"]
    path = qemu
    url = https://github.com/yhsung/chimera
```

**Cloning chimera-2:**
```bash
git clone --recurse-submodules https://github.com/yhsung/chimera-2
# or, after a plain clone:
git submodule update --init --recursive
```

**Future submodule bumps** (manual, deliberate — no `--remote` tracking):
```bash
cd chimera-2/qemu
git fetch && git checkout <new-sha>
cd ..
git add qemu
git commit -m "build: bump qemu submodule to <new-sha> (<why>)"
```

---

## Path & Environment Variable Changes

Most of `scripts/heterogeneous-soc/common.sh`'s path logic is derived
relative to the script's own location:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIMERA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
```

Once `scripts/heterogeneous-soc/` physically lives at chimera-2's root,
`CHIMERA_ROOT` automatically becomes chimera-2's root, and everything
derived from it — `PINGPONG_DIR="${CHIMERA_ROOT}/contrib/heterogeneous-soc"`,
`BUILD_DIR` defaulting to `${CHIMERA_ROOT}/build-linux`, `VM_SOURCE_DIR`
defaulting to `${CHIMERA_ROOT}` — needs **no code change**.

The one place that breaks: today `CHIMERA_ROOT`/`VM_SOURCE_DIR` also
implicitly mean "the QEMU source tree", because today the chimera repo
root *is* the QEMU source tree.
`scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh:18` calls
`"${VM_SOURCE_DIR}/configure"` directly. After the split, the QEMU source
tree is the `qemu/` submodule, one level down.

**Concrete changes:**

1. New variable in `common.sh`:
   ```bash
   QEMU_SRC_DIR="${QEMU_SRC_DIR:-${CHIMERA_ROOT}/qemu}"
   ```
2. `guest-build-ivshmem-tools.sh:18`: `"${VM_SOURCE_DIR}/configure"` →
   `"${QEMU_SRC_DIR}/configure"`.
3. Add a guard (e.g. `require_file "${QEMU_SRC_DIR}/configure"`) with a
   hint to run `git submodule update --init --recursive` if the submodule
   wasn't initialized.
4. `BUILD_DIR` stays `${CHIMERA_ROOT}/build-linux` — a sibling of `qemu/`,
   not inside it, so the submodule's working tree never accumulates
   untracked build artifacts.
5. `host-install-lima-host.sh`'s rsync source remains `${CHIMERA_ROOT}`
   (now chimera-2's root, including the checked-out `qemu/` submodule
   files on disk). The existing `--exclude '.git/'` pattern already
   matches `qemu/.git` too (rsync exclude patterns without a leading `/`
   match at any depth) — verified explicitly in the verification plan
   below, no script change needed.

Everything else (`IVSHMEM_*_DIR`, `FREERTOS_KERNEL_DIR`, `ASSET_DIR`, SSH
ports, etc.) is unaffected.

---

## Documentation Split

`README.rst` (stock upstream QEMU readme) is untouched either way — out
of scope. The split applies to `README.md` (922 lines, entirely
chimera-authored) and `CLAUDE.md`/`AGENTS.md` (336/143 lines).

**`chimera-2/README.md`** (new — most of the current 922 lines, moved
as-is):
- Top overview paragraph; "Architecture" (diagram, Components table,
  ivshmem Device Types, FreeRTOS DRAM Configuration); "Wire Protocol";
  "Tmux Pane Layout"; "Interactive Shell"; "Guest Networking & Avahi
  Discovery"; "Running the Demo" — all move verbatim.
- File-path references into the QEMU machine model (e.g.
  `hw/arm/chimera_r52_freertos_demo.c:320`) get a `qemu/` prefix since
  that source now lives in the submodule.
- "Chimera-Specific Code" table is split: the `contrib/heterogeneous-soc/`
  and `scripts/heterogeneous-soc/` rows move here (now local paths); the
  machine-model/`ivshmem-flat` rows move to chimera's README.
- New "Licensing" section: chimera-2 itself is Apache-2.0 (root
  `LICENSE`/`NOTICE`); the `qemu/` submodule is a separate
  GPL-2.0-or-later repo with its own `LICENSE`/`COPYING`.
- New pointer to chimera's `docs/superpowers/plans/` and
  `docs/superpowers/specs/` for design-rationale history.

**`chimera/README.md`** (trimmed to a short "fork addendum"):
- New "## Chimera Fork Additions" section containing only the
  machine-model/`ivshmem-flat` table rows, "ivshmem Device Types", and
  "FreeRTOS DRAM Configuration" — these describe files living in this
  repo.
- Short Licensing note (GPL-2.0-or-later) + pointer to chimera-2 for the
  full demo, noting this repo is consumed as chimera-2's `qemu/`
  submodule.

**`CLAUDE.md` / `AGENTS.md`** (same split pattern for both files):
- **Move to chimera-2** (full): Quick Start, QEMU/FreeRTOS Workflow,
  Autonomous Debug Loop, all CI harness docs, Git Worktree Usage, Shell
  Scripting/tmux conventions, Deploy Path, Direct Lima Access, Key
  Environment Variables (updated with `QEMU_SRC_DIR`).
- **Stay in chimera** (trimmed): "What This Repo Is" (rewritten as
  QEMU-fork scope), "Building QEMU", general "Git Conventions", pointer to
  chimera-2.
- **Duplicated in both** (short, stable, rarely changes — kept in sync
  manually): the Wire Protocol "critical implementation constraints"
  (volatile byte loops + memory barriers — binds both the firmware client
  and the `ivshmem-flat` device), the "FreeRTOS Exception Handlers"
  MMIO-mapping obligation (short form in chimera pointing at the full
  handler explanation in chimera-2), and the `mipsel`/`r52` naming
  conventions (short form in chimera, full in chimera-2).

---

## Migration Steps

**Step 1 — Extract history** (must happen before Step 2, while the
directories still exist at chimera's HEAD):
```bash
git clone https://github.com/yhsung/chimera /tmp/chimera-2-extract
cd /tmp/chimera-2-extract
git filter-repo --path contrib/heterogeneous-soc --path scripts/heterogeneous-soc
```
Create `yhsung/chimera-2` on GitHub and push this filtered history as its
initial commits on `main`.

**Step 2 — Clean up chimera** (on the real working repo, `master`):
```bash
git rm -r contrib/heterogeneous-soc scripts/heterogeneous-soc
# + trim README.md / CLAUDE.md / AGENTS.md per the Documentation Split above
git commit -m "chore: move heterogeneous-soc demo to chimera-2"
git push origin master
```
Note the resulting SHA as `<qemu-pin-sha>`.

**Step 3 — Assemble chimera-2** (on top of Step 1's pushed history):
```bash
git submodule add https://github.com/yhsung/chimera qemu
(cd qemu && git checkout <qemu-pin-sha>)
git add qemu .gitmodules
git commit -m "build: add chimera (QEMU fork) as submodule, pinned to <sha>"
```
Then, in one or more follow-up commits: add root `LICENSE` (Apache-2.0)
and consolidated `NOTICE` (merging the two existing per-directory NOTICE
files' content), apply the `common.sh` / `guest-build-ivshmem-tools.sh`
changes above, and add the new top-level `README.md` / `CLAUDE.md` /
`AGENTS.md`. Push to `main`.

**Step 4 — One-time Lima deploy reset:** `host-install-lima-host.sh`
rsyncs `CHIMERA_ROOT/` → `$HOME/chimera-src/` without `--delete`. If
chimera-2's root is rsynced on top of the old chimera tree already in
`$HOME/chimera-src` (which has QEMU source like `hw/`, `include/`,
`meson.build` at its root from before), the result is a stale mixed tree.
Before first deploying chimera-2, wipe `$HOME/chimera-src` (`rm -rf
$HOME/chimera-src/*` on macOS) so the rsync starts clean.

---

## Verification Plan

1. `git clone --recurse-submodules https://github.com/yhsung/chimera-2
   <macos-path>` — confirm layout matches the Architecture section above.
2. Run `host-install-lima-host.sh` from chimera-2 → confirm
   `$HOME/chimera-src` (and its Lima virtiofs view) gets the clean tree,
   including `qemu/` with submodule contents but *not* `qemu/.git`.
3. Run `guest-build-ivshmem-tools.sh` in Lima → confirm
   `QEMU_SRC_DIR/configure` resolves to `$HOME/chimera-src/qemu/configure`
   and the build succeeds.
4. Run `guest-run-freertos-shell-harness.sh` (lightweight, ~10s) end to
   end → PASS.
5. Run `guest-run-freertos-harness.sh` (~30s) for a fuller smoke test →
   PASS.
6. Spot-check preserved history:
   `git log --oneline -- contrib/heterogeneous-soc/freertos-showcase/ |
   wc -l` in chimera-2 shows the full commit count.

---

## Key Design Decisions

1. **chimera-2 is a fully independent repo**, not a fork or mirror —
   chimera becomes a dependency (submodule) of chimera-2, not the other
   way around. This matches the user's intent: chimera-2 is the
   forward-looking, commercially-licensable home for the demo.
2. **Manual submodule pinning**, not `--remote` tracking — chimera-2
   always points at a known-good chimera commit; bumps are explicit,
   reviewable commits.
3. **`git filter-repo` on a throwaway clone**, not a history rewrite of
   the published chimera repo — preserves chimera's history exactly as
   published while giving chimera-2 a complete, path-scoped history.
4. **`git rm` (no force-push) for chimera's cleanup** — fully revertible
   via `git revert` if needed, consistent with the project's git
   conventions (never amend, new commits for fixes).
5. **Root-level LICENSE/NOTICE added to chimera-2** while the existing
   per-directory copies are kept as harmless redundancy — minimizes
   additional churn during migration while giving chimera-2 a
   GitHub-recognized license badge.
6. **`docs/superpowers/plans/` and `docs/superpowers/specs/` stay in
   chimera** — they discuss QEMU-side and demo-side work intertwined and
   are treated as historical record; chimera-2's new docs link back to
   them rather than splitting/duplicating ~30 files.

---

## Spec Self-Review

- **Placeholder scan:** No TBD/TODO placeholders. `<qemu-pin-sha>` and
  `<new-sha>` are intentional migration-time values, not omissions.
- **Internal consistency:** Step ordering (filter-repo before chimera's
  cleanup commit, cleanup commit before submodule pin) is consistent
  across the Submodule Wiring and Migration Steps sections. The
  `QEMU_SRC_DIR` introduced in Path & Environment Variable Changes is
  referenced consistently in Migration Step 3 and the Verification Plan.
- **Scope check:** Focused on the repo split itself. CI/CD adaptation and
  any future submodule-bump automation are explicitly out of scope
  (Non-Goals).
- **Ambiguity check:** "chimera-2's root directory location on macOS" is
  left unspecified (implementation detail — a sibling directory to
  chimera's working copy is the natural choice, but any location works
  since `CHIMERA_ROOT` is self-deriving). chimera-2's default branch name
  is assumed to be `main`; if a different convention is preferred, this
  should be called out during plan review.
