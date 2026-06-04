#!/usr/bin/env bash
# run-chimera-showcase.sh
#
# Full-stack launcher for the three-channel Chimera heterogeneous-SoC demo.
# Handles all prerequisites, builds every binary, then opens the 7-pane tmux
# showcase (ARM-Linux + RISCV-Linux + MIPS-Linux ↔ FreeRTOS over ivshmem).
#
# Run this from inside the Lima VM:
#   limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/run-chimera-showcase.sh
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

_step()  { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }
_ok()    { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_skip()  { printf '\033[0;33m  ↷ skip: %s\033[0m\n' "$*"; }
_info()  { printf '  %s\n' "$*"; }

# ── Step 1: apt prerequisites ─────────────────────────────────────────────────

if [[ -z "${SKIP_PREREQS:-}" ]]; then
    _step "Checking apt packages"

    NEED_PKGS=()
    _pkg_check() {
        dpkg -s "$1" &>/dev/null || NEED_PKGS+=("$1")
    }
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
    _pkg_check gcc-mips-linux-gnu
    _pkg_check debootstrap
    _pkg_check libarchive-tools
    _pkg_check libglib2.0-dev
    _pkg_check libpixman-1-dev
    _pkg_check libssl-dev
    _pkg_check lld
    _pkg_check opensbi
    _pkg_check pciutils
    _pkg_check python3-pip
    _pkg_check qemu-system-misc
    _pkg_check qemu-user-static
    _pkg_check rsync
    _pkg_check zlib1g-dev

    if [[ ${#NEED_PKGS[@]} -gt 0 ]]; then
        _info "Installing: ${NEED_PKGS[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${NEED_PKGS[@]}"
        _ok "packages installed"
    else
        _skip "all packages already present"
    fi

    # ── Step 2: Fetch Debian kernel packages ──────────────────────────────────

    _step "Fetching Debian kernel packages"
    mkdir -p "${ASSET_DIR}"

    _fetch() {
        local dst="$1" url="$2" label="$3"
        if [[ -f "${dst}" ]]; then
            _skip "${label} already present ($(du -sh "${dst}" | cut -f1))"
        else
            _info "Downloading ${label}..."
            wget -q --show-progress -O "${dst}" "${url}"
            _ok "${label} fetched"
        fi
    }

    _fetch "${ARM_KERNEL_DEB}" \
        "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-arm64_6.1.124-1_arm64.deb" \
        "Debian arm64 kernel"
    _fetch "${RISCV_KERNEL_DEB}" \
        "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-riscv64_6.1.124-1_riscv64.deb" \
        "Debian riscv64 kernel"
    _fetch "${MIPS_KERNEL_DEB}" \
        "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-4kc-malta_6.1.124-1_mips.deb" \
        "Debian mips 4kc-malta kernel"

fi

# ── Step 3: Build ivshmem server (and full QEMU) ─────────────────────────────

_step "Building ivshmem server / QEMU"
_has_ivshmem() {
    [[ -x "${BUILD_DIR}/ivshmem-server" ]] || \
    [[ -x "${BUILD_DIR}/contrib/ivshmem-server/ivshmem-server" ]]
}

if _has_ivshmem && [[ -x "${BUILD_DIR}/qemu-system-riscv64" ]] && \
                   [[ -x "${BUILD_DIR}/qemu-system-aarch64" ]]; then
    _skip "QEMU and ivshmem-server already built in ${BUILD_DIR}"
else
    bash "${SCRIPT_DIR}/build-ivshmem-tools.sh"
    _ok "QEMU and ivshmem-server built"
fi

# ── Step 4: Fetch FreeRTOS kernel source ─────────────────────────────────────

_step "FreeRTOS kernel source"
bash "${SCRIPT_DIR}/fetch-freertos-kernel.sh"
_ok "FreeRTOS-Kernel at ${FREERTOS_KERNEL_DIR}"

# ── Step 5: Build showcase binaries ──────────────────────────────────────────

if [[ -n "${SKIP_BUILD:-}" ]]; then
    _step "Showcase build"
    _skip "SKIP_BUILD set — using cached artefacts"
    require_file "${FREERTOS_DEMO_ELF}" "FreeRTOS demo ELF"
else
    _step "Building FreeRTOS showcase"
    bash "${SCRIPT_DIR}/build-freertos-showcase.sh"
    _ok "freertos-riscv-demo.elf built ($(du -sh "${FREERTOS_DEMO_ELF}" | cut -f1))"

    for bin in "${HELLO_ARM_BINARY}" "${HELLO_RISCV_BINARY}" "${HELLO_MIPS_BINARY}"; do
        if [[ -f "${bin}" ]]; then
            _ok "$(basename "${bin}") built ($(du -sh "${bin}" | cut -f1))"
        else
            _info "$(basename "${bin}") not built (cross-compiler absent — will be skipped in demo)"
        fi
    done

    if [[ ! -f "${HELLO_MIPS_BINARY}" ]]; then
        printf '\n\033[1;33mWARNING:\033[0m hello-mips-linux was not built.\n'
        printf '  The MIPS guest will boot but the hello binary will not be present.\n'
        printf '  Install gcc-mips-linux-gnu and re-run to fix.\n\n'
    fi
fi

# ── Step 6: Debian rootfs disk images ───────────────────────────────────────────
# prepare-debian-rootfs.sh creates minimal Debian qcow2 disks via debootstrap.
# These are created once and reused; the script skips existing images.

_step "Debian rootfs images"
bash "${SCRIPT_DIR}/prepare-debian-rootfs.sh"
_ok "Debian rootfs disks ready"

# ── Step 7: Extract kernel + initrd from .deb packages ─────────────────────────

_step "Kernel extraction"
bash "${SCRIPT_DIR}/prepare-debian-boot-assets.sh"
_ok "Kernels and initrds extracted"

# ── Step 8: Launch ────────────────────────────────────────────────────────────

_step "Launching Chimera showcase"
printf '  Session:  freertos-showcase\n'
printf '  Layout:   3 ivshmem servers | FreeRTOS | ARM / RISCV / MIPS Debian\n'
printf '  Navigate: Ctrl-b + arrow keys\n\n'

# Pass SKIP_BUILD=1 so run-phase5-tmux.sh goes straight to the tmux launch
# without running build-freertos-showcase.sh a second time.
exec env SKIP_BUILD=1 bash "${SCRIPT_DIR}/run-phase5-tmux.sh"
