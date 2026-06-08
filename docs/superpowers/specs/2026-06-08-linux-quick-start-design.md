# Linux Quick Start — Design

## Problem

The documented Quick Start (`README.md` → "Running the Demo") is macOS-only:
Step 1 (`host-install-lima-host.sh`) requires Homebrew and creates a Lima VM
(Apple's `vz` backend); Step 2 runs `guest-run-chimera-showcase.sh` *inside*
that VM. A Linux user has no documented path — and if they try running the
showcase script directly from their checkout, it breaks, because `common.sh`
mis-detects them as "inside a deployed Lima copy."

Linux already has KVM and native Debian/Ubuntu toolchains, so the nested-VM
layer is unnecessary there: the goal is to let `guest-run-chimera-showcase.sh`
run **directly on a Debian/Ubuntu Linux host**, from the checkout in place,
with no Lima VM at all.

## Scope

- **In scope**: making the documented two-command Quick Start runnable as a
  single command on a native Debian/Ubuntu Linux host.
- **Out of scope**:
  - Other Linux distro families (Fedora, Arch, openSUSE, …) — the existing
    prereq installer is apt-based and the Lima VM itself runs Ubuntu, so
    native support is scoped to apt-based hosts. Other distros remain
    supported via the existing Lima-VM path (Lima itself runs on Linux too).
  - Porting macOS/Lima-specific convenience scripts (`host-chimera-ssh.sh`,
    `host-chimera-keyinject.sh`, `host-ghostty-demo.sh`,
    `host-open-phase5-iterm.sh`) — these stay macOS/Lima-specific.
  - Making `host-install-lima-host.sh` actually provision Lima *on* Linux
    (a "Linux host → Lima VM → guest" path for parity/isolation/other
    concerns). That's an additive, separate piece of future work; this
    design only adds a redirect guard so the script doesn't fail confusingly
    if a Linux user runs it.

## Root cause

Three functions in `common.sh` — `default_build_dir`, `default_vm_source_dir`,
`default_pingpong_dir` — decide between two path schemes:

- **Canonical checkout**: run in place — `BUILD_DIR=<repo>/build-linux`,
  `VM_SOURCE_DIR=<repo>`, `PINGPONG_DIR=<repo>/contrib/heterogeneous-soc`
- **Deployed copy** (rsync'd into a Lima VM by `host-install-lima-host.sh`):
  use home-relative paths — `BUILD_DIR=~/chimera-build-linux`,
  `VM_SOURCE_DIR=~/chimera-src`, `PINGPONG_DIR=~/chimera-src/contrib/...`

They currently choose based on `CHIMERA_ROOT == /Users/* && -w "${CHIMERA_ROOT}"`
— i.e. "looks like a writable macOS home directory." That heuristic conflates
*host OS* with *canonical checkout*, so on Linux it always picks the
"deployed copy" branch — even when running directly from an actual git clone
— and the scripts go looking for a `~/chimera-src` that was never created.

## Fix: detect canonical checkout via `.git` presence

`host-install-lima-host.sh` deploys copies with `rsync --exclude '.git/'`, so
**"`CHIMERA_ROOT` contains a `.git` directory" reliably means "this is the
canonical checkout — run in place,"** regardless of host OS. Replace the
`/Users/*` heuristic with this check:

```bash
# True when CHIMERA_ROOT is the canonical checkout (has .git) rather than a
# copy deployed into a Lima VM (host-install-lima-host.sh rsyncs with
# --exclude '.git/', so deployed copies never have one).
is_canonical_checkout() {
    [[ -d "${CHIMERA_ROOT}/.git" && -w "${CHIMERA_ROOT}" ]]
}

default_build_dir() {
    if is_canonical_checkout; then
        printf '%s/build-linux\n' "${CHIMERA_ROOT}"
    else
        printf '%s/chimera-build-linux\n' "${HOME}"
    fi
}

default_vm_source_dir() {
    if is_canonical_checkout; then
        printf '%s\n' "${CHIMERA_ROOT}"
    else
        printf '%s/chimera-src\n' "${HOME}"
    fi
}
```

Once `default_vm_source_dir` is correct, `default_pingpong_dir`'s two branches
become identical (`${VM_SOURCE_DIR}/contrib/heterogeneous-soc` either way), so
it collapses to:

```bash
default_pingpong_dir() {
    printf '%s/contrib/heterogeneous-soc\n' "${VM_SOURCE_DIR}"
}
```

This single change makes `BUILD_DIR`/`VM_SOURCE_DIR`/`PINGPONG_DIR` resolve
correctly in all three real scenarios: macOS-canonical, Linux-canonical
(new), and deployed-Lima-copy — with no OS-specific branching needed anywhere
else in `common.sh`.

## Quick Start restructuring

With the path-detection fix in place, `guest-run-chimera-showcase.sh` is
already self-sufficient: it does its own idempotent `dpkg -s` / `apt-get`
prereq check (it doesn't even call `guest-install-lima-guest.sh`), fetches
images, builds every binary, and launches the tmux showcase — all relative to
`VM_SOURCE_DIR`/`BUILD_DIR`, which now resolve in place. So on Linux, the
entire two-step macOS flow collapses to one command run directly from the
checkout:

```bash
bash scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

Changes:

1. **Redirect guard in `host-install-lima-host.sh`**: in `_main`, detect
   `uname -s == Linux` before the `command -v brew` check, print a short
   message pointing at the one-line Linux Quick Start, and `exit 0`. This
   means a Linux user who copy-pastes Step 1 out of habit gets a helpful
   redirect instead of "Homebrew is required on the macOS host."
2. **README "Running the Demo" → Quick Start**: branch by host OS —
   - macOS: keep the existing two-step Lima flow unchanged.
   - Linux (Debian/Ubuntu host): single command, run directly from the
     checkout; note the Debian/Ubuntu requirement and that `apt`/`sudo`/KVM
     access are needed.
3. **Architecture / Components table**: mark the "Lima VM (`qemu-dev`)" row
   as macOS-specific, and add a note that on a native Linux host the same
   QEMU guests, ivshmem servers, and toolchains run directly with KVM
   acceleration — no VM layer.

## SSH access on native Linux

On macOS, the guest bridge (`172.16.100.0/24`) lives *inside* the Lima VM, so
macOS needs `chimera-ssh` — a `ProxyCommand` wrapper through Lima's dynamic
SSH port — to reach it. On native Linux, `guest-setup-network-bridge.sh`
creates that same bridge **on the host itself** (it already just shells out to
`ip`/`sudo` and already gates on `uname -s == Linux`, so it needs no logic
changes to run directly). That means guests are reachable straight from the
host:

```bash
ssh root@172.16.100.10   # ARM-Linux  (or root@debian-arm64.local via mDNS)
ssh root@172.16.100.11   # RISC-V-Linux
ssh root@172.16.100.12   # MIPS-Linux
```

No jump host, no wrapper script needed. Document this directly in the
README's networking section as the native-Linux path; leave `chimera-ssh` /
`chimera-scp` / `chimera-keyinject` / `host-ghostty-demo.sh` /
`host-open-phase5-iterm.sh` as the macOS/Lima-specific convenience tools they
already are — porting them is out of scope (see Scope).

## Wording-only generalizations

A few comments and error strings hard-code "Lima guest" / "inside the Lima
VM" language that's no longer accurate once the script can run directly on a
Linux host. Generalize to "Linux build host (Lima VM or native Linux)" with
no logic changes, in:

- `guest-build-ivshmem-tools.sh` (die message)
- `guest-install-syslog-to-guests.sh` (header comment)
- `guest-setup-network-bridge.sh` (die message)
- `guest-run-chimera-showcase.sh` (header "Run this from inside the Lima VM" note)

## Cleanups that fall out of this work

- **`.gitignore`**: add `/build-linux/`. It's currently missing — harmless
  today because `BUILD_DIR` always resolves outside the repo on the
  documented macOS+Lima path — but the `.git`-presence fix means a canonical
  checkout (now including native Linux, and even macOS if run outside Lima)
  puts build output at `<repo>/build-linux/`, which would otherwise appear as
  untracked cruft.

## Verification plan

There's no bare-metal Linux host available in this environment — only the
Lima VM (which itself runs Ubuntu Linux). Since the only things changing are
path resolution, a redirect message, doc text, and wording, and the actual
showcase logic is already OS-generic Linux bash that runs fine inside Lima,
verification will be:

1. **Path-detection smoke test**: `git clone` the repo to a fresh directory
   inside the Lima VM (so it has `.git`, simulating "canonical checkout on a
   Linux host"), then run `guest-run-chimera-showcase.sh --dry-run` from
   there and confirm `BUILD_DIR`/`VM_SOURCE_DIR`/`PINGPONG_DIR` resolve to
   in-place paths under that clone (not `~/chimera-src` /
   `~/chimera-build-linux`).
2. **Deployed-copy regression check**: re-run the same `--dry-run` from the
   existing `~/chimera-src` deployed copy (no `.git`) and confirm it still
   resolves to `~/chimera-src` / `~/chimera-build-linux` — i.e. the macOS+Lima
   path is unaffected.
3. **Redirect guard check**: run `host-install-lima-host.sh` inside the Lima
   VM (which is Linux) and confirm it prints the redirect message and exits 0
   instead of failing on the `brew` check.
4. **Bridge setup**: confirm `guest-setup-network-bridge.sh` still runs
   cleanly (it already requires Linux + sudo + `ip`, unchanged).

A full end-to-end showcase launch on bare-metal Linux is left for the user to
confirm on their own hardware, since it requires real KVM access and takes
significant time to build/boot all three guests.
