#!/usr/bin/env bash
# guest-run-chimera-showcase.sh
#
# Full-stack launcher for the four-channel Chimera heterogeneous-SoC demo.
# Handles all prerequisites, builds every binary, then opens the 8-pane tmux
# showcase (ARM-Linux + RISCV-Linux + MIPS-Linux ↔ FreeRTOS over ivshmem,
# plus a stats channel where FreeRTOS pushes message-count snapshots to ARM).
#
# Usage:
#   bash guest-run-chimera-showcase.sh [OPTIONS]
#
# Options:
#   --help, -h     Show this help and exit
#   --dry-run      Print what would be done without doing it
#
# Run this from inside the Lima VM:
#   limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
#
# Key environment overrides (all have sensible defaults via common.sh):
#   BUILD_DIR        QEMU build output  (default: ~/chimera-build-linux)
#   VM_SOURCE_DIR    Chimera source     (default: ~/chimera-src)
#   ASSET_DIR        ISO / disk cache   (default: ~/iso)
#   SKIP_PREREQS     non-empty → skip apt install and ISO fetch
#   SKIP_BUILD       non-empty → skip binary rebuild (use cached artefacts)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ── Option parsing ───────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case "${arg}" in
        --help|-h)
            sed -n '/^# /{ s/^# //; /^!/q; p; }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            echo "error: unknown option '${arg}'; use --help" >&2
            exit 1
            ;;
    esac
done

# Redirect actual work behind dry-run.
if "${DRY_RUN}"; then
    _exec() { printf '  [dry-run] %s\n' "$*"; }
else
    _exec() { "$@"; }
fi

_step()  { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }
_ok()    { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_skip()  { printf '\033[0;33m  ↷ skip: %s\033[0m\n' "$*"; }
_info()  { printf '  %s\n' "$*"; }

# ── Pre-flight checks ────────────────────────────────────────────────────────

# tmux is required by the final launch step.
if ! command -v tmux &>/dev/null; then
    die "tmux is required but not installed; 'sudo apt-get install -y tmux' and re-run"
fi

# Validate that all downstream launch scripts exist before spending time on builds.
LAUNCH_SCRIPTS=(
    "${SCRIPT_DIR}/guest-run-phase5-tmux.sh"
    "${SCRIPT_DIR}/guest-start-ivshmem-server-arm-freertos.sh"
    "${SCRIPT_DIR}/guest-start-ivshmem-server-riscv-freertos.sh"
    "${SCRIPT_DIR}/guest-start-ivshmem-server-mips-freertos.sh"
    "${SCRIPT_DIR}/guest-start-ivshmem-server-stats.sh"
    "${SCRIPT_DIR}/guest-build-freertos-showcase.sh"
    "${SCRIPT_DIR}/guest-install-syslog-to-guests.sh"
)
for script in "${LAUNCH_SCRIPTS[@]}"; do
    [[ -f "${script}" ]] || die "required script not found: ${script}"
done

# Kill any stale QEMU/ivshmem-server processes from a prior run that might
# hold file locks or leave stale sockets behind.
_info "Cleaning up stale processes from prior runs..."
_exec pkill -f "qemu-system-riscv64.*freertos-riscv-demo" 2>/dev/null || true
_exec pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
_exec pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
_exec pkill -f "qemu-system-mipsel.*run-chimera"           2>/dev/null || true
_exec pkill -x "ivshmem-server"                            2>/dev/null || true
sleep 0.3
_ok "stale processes cleaned"

# ── Step 0.5: Network bridge ──────────────────────────────────────────────────

_step "Setting up network bridge"
_exec bash "${SCRIPT_DIR}/guest-setup-network-bridge.sh"
_ok "Bridge chbr0 and TAP devices ready"

# ── Step 1: apt prerequisites ─────────────────────────────────────────────────

if [[ -z "${SKIP_PREREQS:-}" ]]; then
    _step "Checking apt packages"

    NEED_PKGS=()
    _pkg_check() { dpkg -s "$1" &>/dev/null || NEED_PKGS+=("$1"); }
    _pkg_check build-essential
    _pkg_check bison
    _pkg_check flex
    _pkg_check git
    _pkg_check ninja-build
    _pkg_check pkg-config
    _pkg_check gcc-aarch64-linux-gnu
    _pkg_check gcc-riscv64-linux-gnu
    _pkg_check gcc-riscv64-unknown-elf
    _pkg_check binutils-riscv64-unknown-elf
    _pkg_check gcc-mipsel-linux-gnu
    _pkg_check debootstrap
    _pkg_check libarchive-tools
    _pkg_check qemu-efi-aarch64
    _pkg_check libglib2.0-dev
    _pkg_check libpixman-1-dev
    _pkg_check libssl-dev
    _pkg_check lld
    _pkg_check opensbi
    _pkg_check pciutils
    _pkg_check python3-pip
    _pkg_check qemu-system-misc
    _pkg_check qemu-user-static
    _pkg_check qemu-utils
    _pkg_check rsync
    _pkg_check tmux
    _pkg_check zlib1g-dev

    if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
        _info "Installing: ${NEED_PKGS[*]}"
        _exec sudo apt-get update -qq
        _exec sudo apt-get install -y "${NEED_PKGS[@]}"
        _ok "packages installed"
    else
        _skip "all packages already present"
    fi

    # ── Step 2: Fetch Debian kernel packages ──────────────────────────────────

    _step "Fetching Debian kernel packages"
    _exec bash "${SCRIPT_DIR}/guest-fetch-images.sh"
    _ok "Debian kernel packages fetched"

fi

# ── Step 3: Build ivshmem server (and full QEMU) ─────────────────────────────

_step "Building ivshmem server / QEMU"
_has_qemu_build() {
    find_ivshmem_server &>/dev/null || return 1
    local qemu_riscv="${BUILD_DIR}/qemu-system-riscv64"
    [[ -x "${qemu_riscv}" ]] || return 1
    [[ -x "${BUILD_DIR}/qemu-system-aarch64" ]] || return 1
    [[ -x "${BUILD_DIR}/qemu-system-mipsel" ]] || return 1
    # Verify the QEMU binary is up-to-date by checking for the most recently
    # added machine property. A stale binary (built from an older commit) would
    # report "Property not found" at runtime, so we catch it here instead.
    "${qemu_riscv}" -M chimera-riscv-freertos-demo,help 2>&1 | \
        grep -q "ivshmem-stats-freertos" || return 1
}

if _has_qemu_build; then
    _skip "QEMU and ivshmem-server already built in ${BUILD_DIR}"
else
    _exec bash "${SCRIPT_DIR}/guest-build-ivshmem-tools.sh"
    _ok "QEMU and ivshmem-server built"
fi

# ── Step 4: Fetch FreeRTOS kernel source ─────────────────────────────────────

_step "FreeRTOS kernel source"
if [[ -d "${FREERTOS_KERNEL_DIR}/.git" ]]; then
    _skip "FreeRTOS-Kernel already cloned at ${FREERTOS_KERNEL_DIR}"
else
    _exec bash "${SCRIPT_DIR}/guest-fetch-freertos-kernel.sh"
    _ok "FreeRTOS-Kernel at ${FREERTOS_KERNEL_DIR}"
fi

# ── Step 5: Build showcase binaries ──────────────────────────────────────────

if [[ -n "${SKIP_BUILD:-}" ]]; then
    _step "Showcase build"
    _skip "SKIP_BUILD set — using cached artefacts"
    require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
else
    _step "Building FreeRTOS showcase"
    _exec bash "${SCRIPT_DIR}/guest-build-freertos-showcase.sh"
    _ok "freertos-riscv-demo.elf built ($(du -sh "${FREERTOS_DEMO_ELF}" | cut -f1))"

    for bin in "${SYSLOG_ARM_BINARY}" "${SYSLOG_RISCV_BINARY}" "${SYSLOG_MIPS_BINARY}" "${LINUX_ARM_STATS_BINARY}"; do
        if [[ -f "${bin}" ]]; then
            _ok "$(basename "${bin}") built ($(du -sh "${bin}" | cut -f1))"
        else
            _info "$(basename "${bin}") not built (cross-compiler absent — will be skipped in demo)"
        fi
    done

    if [[ ! -f "${SYSLOG_MIPS_BINARY}" ]]; then
        printf '\n\033[1;33mWARNING:\033[0m syslog-mips-linux was not built.\n'
        printf '  The MIPS guest will boot but the syslog daemon will not be present.\n'
        printf '  Install gcc-mipsel-linux-gnu and re-run to fix.\n\n'
    fi
fi

# ── Step 6: Debian rootfs disk images ───────────────────────────────────────────
# guest-prepare-debian-rootfs.sh creates minimal Debian qcow2 disks via debootstrap.
# These are created once and reused; the script skips existing images.

_step "Debian rootfs images"
_exec bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh"

# Detect disk images built before Avahi support was added.
_avahi_present_in_image() {
    local disk="$1"
    [[ -f "${disk}" ]] || return 0   # not yet built — will be created fresh
    local nbd_dev="/dev/nbd0" mnt result=0
    mnt="$(mktemp -d)"
    sudo modprobe nbd max_part=0 2>/dev/null || true
    if ! sudo qemu-nbd --connect="${nbd_dev}" "${disk}" 2>/dev/null; then
        rmdir "${mnt}"; return 0     # can't mount → allow through
    fi
    sleep 0.3
    if ! sudo mount "${nbd_dev}" "${mnt}" 2>/dev/null; then
        sudo qemu-nbd --disconnect "${nbd_dev}" 2>/dev/null || true
        rmdir "${mnt}"; return 0
    fi
    [[ -f "${mnt}/usr/sbin/avahi-daemon" ]] || result=1
    sudo umount "${mnt}" 2>/dev/null || true
    sudo qemu-nbd --disconnect "${nbd_dev}" 2>/dev/null || true
    rmdir "${mnt}" 2>/dev/null || true
    return "${result}"
}

if ! _avahi_present_in_image "${ARM_DEBIAN_DISK}"; then
    _info "Disk images predate Avahi support. Auto-removing and rebuilding..."
    rm -f "${ARM_DEBIAN_DISK}" "${RISCV_DEBIAN_DISK}" "${MIPS_DEBIAN_DISK}"
    _exec bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh"
fi
_ok "Debian rootfs disks ready"

# ── Step 6.5: Install syslog daemons into guest disk images ──────────────────
# Injects syslog-{arm,riscv,mips}-linux into /usr/local/bin/ of each qcow2 so
# guests can run the daemon directly from their own filesystem.
# Idempotent — safe to re-run after every binary rebuild.

_step "Installing syslog daemons into guest images"
_exec bash "${SCRIPT_DIR}/guest-install-syslog-to-guests.sh"
_ok "Syslog daemons installed"

# ── Step 7: Extract kernel + initrd from .deb packages ─────────────────────────

_step "Kernel extraction"
_exec bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"
_ok "Kernels and initrds extracted"

# ── Step 8: Launch ────────────────────────────────────────────────────────────

_step "Launching Chimera showcase"
printf '  Session:  freertos-showcase\n'
printf '  Layout:   4 ivshmem servers | FreeRTOS | ARM / RISCV / MIPS Debian\n'
printf '  Navigate: Ctrl-b + arrow keys\n\n'

if "${DRY_RUN}"; then
    printf '  [dry-run] would exec: SKIP_BUILD=1 bash %s\n' \
        "${SCRIPT_DIR}/guest-run-phase5-tmux.sh"
    exit 0
fi

# Pass SKIP_BUILD=1 so guest-run-phase5-tmux.sh goes straight to the tmux launch
# without running guest-build-freertos-showcase.sh a second time.
exec env SKIP_BUILD=1 bash "${SCRIPT_DIR}/guest-run-phase5-tmux.sh"
