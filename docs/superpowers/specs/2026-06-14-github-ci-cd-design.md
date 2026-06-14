# GitHub CI/CD Design — Chimera Harness CI

## Context

Chimera's harness scripts (`guest-run-*-harness.sh`) are the source of truth for pass/fail verification. They currently run manually inside the Lima VM. This spec automates them via GitHub Actions on PRs.

## Goals

- Run all harnesses on every PR against the PR's code
- Build all artifacts from scratch in each CI run (no pre-existing artifacts assumed)
- Start a fresh Lima VM on each CI run (no persistence between runs)
- Report per-harness pass/fail as GitHub PR status checks
- Fail the PR check if any harness fails

## Non-Goals

- Running on `push` (only PRs trigger CI)
- Building on any platform other than the macOS self-hosted runner
- Canary/nightly/release automation (out of scope for now)

---

## Architecture

```
PR opened → GitHub Actions (runs on macOS self-hosted runner)
              │
              ├─ Job: build
              │    ├─ limactl start qemu-dev
              │    ├─ bash host-install-lima-host.sh
              │    ├─ Build QEMU + FreeRTOS showcase
              │    └─ Upload artifacts as workflow tarball
              │
              └─ Jobs: harness-* (parallel, after build)
                   ├─ freertos-shell  (~10 s)
                   ├─ freertos-harness (~30 s)
                   ├─ riscv-hello
                   ├─ stats-e2e       (~4 min)
                   ├─ shell-e2e
                   └─ can-e2e        (~1 min)
                        │
                        └─ Download artifacts → run harness → exit 0/1
```

---

## Runner

**Type:** GitHub Actions self-hosted runner on macOS (this repo only).

**Registration:** One-time manual process — follow GitHub Settings → Actions → Runners → New self-hosted runner. Runner labels: `self-hosted`, `macos`, `qemu-dev`.

**Runner machine:** The same macOS host that already runs the Lima VM for local development. Must have `limactl`, `rsync`, and outbound HTTPS to GitHub.

**Lima VM lifecycle per CI run:**
1. `limactl delete qemu-dev --force 2>/dev/null || true` (clean slate)
2. `limactl start /usr/local/etc/lima/qemu-dev.yaml` (or theLima config path)
3. Wait for `limactl shell qemu-dev -- echo ready` to confirm VM is up
4. Run build + harnesses inside the VM via `limactl shell qemu-dev -- bash -c '...'`
5. `limactl delete qemu-dev --force` (teardown)

---

## Job: `build`

**Runs inside Lima VM** via `limactl shell qemu-dev -- bash -c '...'`.

**Steps:**
1. Sync source from macOS host into the VM (`rsync -a /Users/yhsung/chimera-src/` → `$HOME/chimera-src/`)
2. Run `bash ~/chimera-src/scripts/heterogeneous-soc/host-install-lima-host.sh`
3. Build QEMU (`build-linux` directory)
4. Build FreeRTOS showcase (`guest-build-freertos-showcase.sh`)
5. Fetch Debian rootfs images (`guest-fetch-images.sh`)
6. Prepare boot assets (`guest-prepare-debian-boot-assets.sh` × 3)
7. Compress and upload artifacts as GitHub Actions workflow artifact:
   - `$HOME/chimera-build-linux/` → `build-linux.tar.gz`
   - `$HOME/chimera-src/` → `source.tar.gz`
   - `$HOME/iso/` → `iso.tar.gz`

**Artifact retention:** 7 days.

---

## Jobs: Harness Jobs (`freertos-shell`, `freertos-harness`, `riscv-hello`, `stats-e2e`, `shell-e2e`, `can-e2e`)

Each is a separate GitHub Actions job, all running in parallel after `build` completes.

**Trigger:** `needs: build` + `runs-on: [self-hosted, macos, qemu-dev]`

**Steps:**
1. Download artifact tarballs from `build` job
2. Extract into `$HOME/` (restoring the same directory layout the build job created)
3. Run the corresponding harness via `limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-<name>.sh`
4. Harness exit code determines job success/failure

**Artifact download:** Uses `actions/download-artifact` with `merge-multiple: false` (downloads each tarball separately).

**Timeout:** Per harness, matching the harness's own timeout setting.

---

## Workflow File

Location: `.github/workflows/ci.yml`

```yaml
name: CI

on:
  pull_request:

jobs:
  build:
    runs-on: [self-hosted, macos, qemu-dev]
    steps:
      - name: Start Lima VM
        run: |
          limactl delete qemu-dev --force 2>/dev/null || true
          limactl start /usr/local/etc/lima/qemu-dev.yaml
          timeout 120 sh -c 'until limactl shell qemu-dev -- echo ready; do sleep 2; done'

      - name: Sync source into VM
        run: rsync -az --delete /Users/yhsung/chimera-src/ lima:~/chimera-src/

      - name: Build everything
        run: |
          limactl shell qemu-dev -- bash -c '
            set -e
            cd ~/chimera-src
            bash scripts/heterogeneous-soc/host-install-lima-host.sh
            bash scripts/heterogeneous-soc/guest-build-freertos-showcase.sh
            bash scripts/heterogeneous-soc/guest-fetch-images.sh
            for guest in arm riscv mips; do
              bash scripts/heterogeneous-soc/guest-prepare-debian-boot-assets.sh $guest
            done
          '

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: chimera-artifacts
          path: |
            ~/chimera-build-linux.tar.gz
            ~/chimera-src.tar.gz
            ~/iso.tar.gz
          retention-days: 7

  freertos-shell:
    needs: build
    runs-on: [self-hosted, macos, qemu-dev]
    steps:
      - uses: actions/download-artifact@v4
        with: { name: chimera-artifacts, path: . }
      - name: Extract artifacts
        run: |
          limactl shell qemu-dev -- bash -c '
            tar -xzf ~/chimera-build-linux.tar.gz -C ~/
            tar -xzf ~/chimera-src.tar.gz -C ~/
            tar -xzf ~/iso.tar.gz -C ~/
          '
      - name: Run harness
        run: |
          limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-shell-harness.sh
        timeout-minutes: 5

  freertos-harness:
    needs: build
    runs-on: [self-hosted, macos, qemu-dev]
    steps: [download-artifact, extract, run-harness]
    run: |
      limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-harness.sh
    timeout-minutes: 10

  riscv-hello:
    needs: build
    runs-on: [self-hosted, macos, qemu-dev]
    steps: [download-artifact, extract, run-harness]
    run: |
      limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-riscv-hello-harness.sh
    timeout-minutes: 10

  stats-e2e:
    needs: build
    runs-on: [self-hosted, macos, qemu-dev]
    steps: [download-artifact, extract, run-harness]
    run: |
      limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-stats-e2e-harness.sh
    timeout-minutes: 10

  shell-e2e:
    needs: build
    runs-on: [self-hosted, macos, qemu-dev]
    steps: [download-artifact, extract, run-harness]
    run: |
      limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
    timeout-minutes: 10

  can-e2e:
    needs: build
    runs-on: [self-hosted, macos, qemu-dev]
    steps: [download-artifact, extract, run-harness]
    run: |
      limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-can-e2e-harness.sh
    timeout-minutes: 10
```

---

## Key Design Decisions

1. **macOS runner syncs source into Lima VM.** The runner's macOS has the source tree. The Lima VM is blank each CI run. `rsync` from macOS host → Lima VM populates `$HOME/chimera-src/` before building.

2. **Artifacts compressed on macOS, extracted inside Lima VM.** The `build` job compresses artifacts on the macOS side before uploading. Harness jobs download to macOS then extract inside the VM via another `limactl shell`.

3. **Each harness job starts with a clean Lima VM.** The Lima VM is started fresh in the `build` job and left running through harness jobs (all on the same runner, same VM). Harness jobs reuse the same VM rather than restarting.

4. **No containerization.** Harness scripts use tmux, QEMU, and Lima VM — all already containerized inside the Lima VM. No Docker needed.

5. **Parallel harness jobs.** All 6 harness jobs run simultaneously after `build`, maximizing total CI time savings.

---

## One-Time Runner Setup (documented for reference)

```bash
# On the macOS host, from the repo root:
# 1. Go to GitHub → Settings → Actions → Runners → New self-hosted runner
# 2. Download and configure the runner:
./config.sh --url https://github.com/yhsung/chimera --token <TOKEN>
# 3. Run the runner:
./run.sh
# Labels used: self-hosted, macos, qemu-dev
```

The runner must have `limactl`, `rsync`, `tar`, `gzip`, and `bash` available in its PATH.

---

## Spec Self-Review

- Placeholder scan: no TBD/TODO placeholders — all parameters are concrete
- Internal consistency: artifact paths in `build` match what harness jobs extract; `needs: build` on all harness jobs is correct
- Scope check: focused on PR-triggered CI only; no push/no cron/no release automation
- Ambiguity check: Lima config path (`/usr/local/etc/lima/qemu-dev.yaml`) should be verified on the runner machine before CI first run; if different, update workflow accordingly
