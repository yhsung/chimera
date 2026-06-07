#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIMERA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

LIMA_NAME="${LIMA_NAME:-qemu-dev}"
LIMA_CPUS="${LIMA_CPUS:-4}"
LIMA_MEMORY="${LIMA_MEMORY:-8}"
LIMA_DISK="${LIMA_DISK:-100}"

default_build_dir() {
    if [[ "${CHIMERA_ROOT}" == /Users/* && -w "${CHIMERA_ROOT}" ]]; then
        printf '%s/build-linux\n' "${CHIMERA_ROOT}"
    else
        printf '%s/chimera-build-linux\n' "${HOME}"
    fi
}

default_vm_source_dir() {
    if [[ "${CHIMERA_ROOT}" == /Users/* && -w "${CHIMERA_ROOT}" ]]; then
        printf '%s\n' "${CHIMERA_ROOT}"
    else
        printf '%s/chimera-src\n' "${HOME}"
    fi
}

BUILD_DIR="${BUILD_DIR:-$(default_build_dir)}"
VM_SOURCE_DIR="${VM_SOURCE_DIR:-$(default_vm_source_dir)}"
ASSET_DIR="${ASSET_DIR:-${HOME}/iso}"
IVSHMEM_DIR="${IVSHMEM_DIR:-/tmp/ivshmem}"
IVSHMEM_SOCKET="${IVSHMEM_SOCKET:-${IVSHMEM_DIR}/sock}"
IVSHMEM_SIZE="${IVSHMEM_SIZE:-67108864}"
IVSHMEM_VECTORS="${IVSHMEM_VECTORS:-4}"

# ── Debian rootfs disk images (created by guest-prepare-debian-rootfs.sh) ──────────
ARM_DEBIAN_DISK="${ARM_DEBIAN_DISK:-${ASSET_DIR}/debian-arm64.qcow2}"
RISCV_DEBIAN_DISK="${RISCV_DEBIAN_DISK:-${ASSET_DIR}/debian-riscv64.qcow2}"
MIPS_DEBIAN_DISK="${MIPS_DEBIAN_DISK:-${ASSET_DIR}/debian-mips.qcow2}"

# ── ARM (aarch64) ────────────────────────────────────────────────────────────
ARM_KERNEL_DEB="${ARM_KERNEL_DEB:-${ASSET_DIR}/linux-image-arm64.deb}"
ARM_BOOT_ASSET_DIR="${ARM_BOOT_ASSET_DIR:-${HOME}/heterogeneous-soc-secure-stack/boot-assets}"
ARM_KERNEL_IMAGE="${ARM_KERNEL_IMAGE:-${ARM_BOOT_ASSET_DIR}/vmlinuz}"
ARM_INITRD_IMAGE="${ARM_INITRD_IMAGE:-${ARM_BOOT_ASSET_DIR}/initrd.img}"
ARM_UEFI_BIOS="${ARM_UEFI_BIOS:-/usr/share/qemu-efi-aarch64/QEMU_EFI.fd}"
ARM_KERNEL_CMDLINE="${ARM_KERNEL_CMDLINE:-console=ttyAMA0 root=/dev/vda rw}"

# ── RISC-V (riscv64) ─────────────────────────────────────────────────────────
RISCV_KERNEL_DEB="${RISCV_KERNEL_DEB:-${ASSET_DIR}/linux-image-riscv64.deb}"
RISCV_OPENSBI_BIOS="${RISCV_OPENSBI_BIOS:-/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin}"
RISCV_BOOT_ASSET_DIR="${RISCV_BOOT_ASSET_DIR:-${ASSET_DIR}/riscv-boot}"
RISCV_KERNEL_IMAGE="${RISCV_KERNEL_IMAGE:-${RISCV_BOOT_ASSET_DIR}/vmlinuz}"
RISCV_INITRD_IMAGE="${RISCV_INITRD_IMAGE:-${RISCV_BOOT_ASSET_DIR}/initrd.img}"
RISCV_KERNEL_CMDLINE="${RISCV_KERNEL_CMDLINE:-console=ttyS0 root=/dev/vda rw}"

# ── MIPS (little-endian mipsel, Debian Bookworm) ─────────────────────────────
MIPS_KERNEL_DEB="${MIPS_KERNEL_DEB:-${ASSET_DIR}/linux-image-4kc-malta.deb}"
MIPS_BOOT_ASSET_DIR="${MIPS_BOOT_ASSET_DIR:-${ASSET_DIR}/mips-boot}"
MIPS_KERNEL_IMAGE="${MIPS_KERNEL_IMAGE:-${MIPS_BOOT_ASSET_DIR}/vmlinuz}"
MIPS_INITRD_IMAGE="${MIPS_INITRD_IMAGE:-${MIPS_BOOT_ASSET_DIR}/initrd.img}"
MIPS_KERNEL_CMDLINE="${MIPS_KERNEL_CMDLINE:-console=ttyS0 root=/dev/sda rw}"

ARM_SSH_PORT="${ARM_SSH_PORT:-2222}"
RISCV_SSH_PORT="${RISCV_SSH_PORT:-2223}"
MIPS_SSH_PORT="${MIPS_SSH_PORT:-2224}"

default_pingpong_dir() {
    if [[ "${CHIMERA_ROOT}" == /Users/* && -w "${CHIMERA_ROOT}" ]]; then
        printf '%s/contrib/heterogeneous-soc\n' "${CHIMERA_ROOT}"
    else
        printf '%s/contrib/heterogeneous-soc\n' "${VM_SOURCE_DIR}"
    fi
}

PINGPONG_DIR="${PINGPONG_DIR:-$(default_pingpong_dir)}"
PING_BINARY="${PING_BINARY:-${PINGPONG_DIR}/ping}"
PONG_BINARY="${PONG_BINARY:-${PINGPONG_DIR}/pong}"
IVSHMEM_ARM_FREERTOS_DIR="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}"
IVSHMEM_ARM_FREERTOS_SOCKET="${IVSHMEM_ARM_FREERTOS_SOCKET:-${IVSHMEM_ARM_FREERTOS_DIR}/sock}"
IVSHMEM_RISCV_FREERTOS_DIR="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}"
IVSHMEM_RISCV_FREERTOS_SOCKET="${IVSHMEM_RISCV_FREERTOS_SOCKET:-${IVSHMEM_RISCV_FREERTOS_DIR}/sock}"
IVSHMEM_MIPS_FREERTOS_DIR="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}"
IVSHMEM_MIPS_FREERTOS_SOCKET="${IVSHMEM_MIPS_FREERTOS_SOCKET:-${IVSHMEM_MIPS_FREERTOS_DIR}/sock}"
IVSHMEM_STATS_FREERTOS_DIR="${IVSHMEM_STATS_FREERTOS_DIR:-/tmp/ivshmem-stats-freertos}"
IVSHMEM_STATS_FREERTOS_SOCKET="${IVSHMEM_STATS_FREERTOS_SOCKET:-${IVSHMEM_STATS_FREERTOS_DIR}/sock}"
FREERTOS_DEPS_ROOT="${FREERTOS_DEPS_ROOT:-${HOME}/heterogeneous-soc-freertos}"
FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR:-${FREERTOS_DEPS_ROOT}/FreeRTOS-Kernel}"
FREERTOS_SHOWCASE_DIR="${FREERTOS_SHOWCASE_DIR:-${PINGPONG_DIR}/freertos-showcase}"
SYSLOG_ARM_BINARY="${SYSLOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/syslog-arm-linux}"
SYSLOG_RISCV_BINARY="${SYSLOG_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/syslog-riscv-linux}"
SYSLOG_MIPS_BINARY="${SYSLOG_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/syslog-mips-linux}"
LINUX_ARM_STATS_BINARY="${LINUX_ARM_STATS_BINARY:-${FREERTOS_SHOWCASE_DIR}/linux-arm-stats}"
FREERTOS_DEMO_ELF="${FREERTOS_DEMO_ELF:-${FREERTOS_SHOWCASE_DIR}/freertos-riscv-demo.elf}"

# ── Boot-log ivshmem channel ──────────────────────────────────────────────────
IVSHMEM_BOOTLOG_DIR="${IVSHMEM_BOOTLOG_DIR:-/tmp/ivshmem-bootlog}"
IVSHMEM_BOOTLOG_SOCKET="${IVSHMEM_BOOTLOG_SOCKET:-${IVSHMEM_BOOTLOG_DIR}/sock}"
IVSHMEM_BOOTLOG_SIZE="${IVSHMEM_BOOTLOG_SIZE:-8388608}"
IVSHMEM_BOOTLOG_VECTORS="${IVSHMEM_BOOTLOG_VECTORS:-4}"
BOOTLOG_ARM_BINARY="${BOOTLOG_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-arm-linux}"
BOOTLOG_RISCV_BINARY="${BOOTLOG_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-riscv-linux}"
BOOTLOG_MIPS_BINARY="${BOOTLOG_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/bootlog-mips-linux}"
BOOT_COLLECTOR_BINARY="${BOOT_COLLECTOR_BINARY:-${FREERTOS_SHOWCASE_DIR}/boot-collector}"

PINGPONG_SHARE_TAG="${PINGPONG_SHARE_TAG:-pingpong}"

ARM_TFA_BL1="${ARM_TFA_BL1:-}"
ARM_TFA_FIP="${ARM_TFA_FIP:-}"
ARM_LINUX_IMAGE="${ARM_LINUX_IMAGE:-}"
RISCV_LINUX_IMAGE="${RISCV_LINUX_IMAGE:-}"

die() {
    echo "error: $*" >&2
    exit 1
}

require_file() {
    local path="$1"
    local label="$2"

    [[ -f "${path}" ]] || die "${label} not found: ${path}"
}

prepare_vm_source_tree() {
    if [[ "${VM_SOURCE_DIR}" == "${CHIMERA_ROOT}" ]]; then
        return 0
    fi

    rm -rf "${VM_SOURCE_DIR}"
    mkdir -p "${VM_SOURCE_DIR}"
    rsync -a \
        --exclude '.git/' \
        --exclude 'build-linux/' \
        --exclude '.DS_Store' \
        "${CHIMERA_ROOT}/" "${VM_SOURCE_DIR}/"
}

find_ivshmem_server() {
    local candidates=(
        "${BUILD_DIR}/ivshmem-server"
        "${BUILD_DIR}/contrib/ivshmem-server/ivshmem-server"
    )
    local candidate

    for candidate in "${candidates[@]}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    die "ivshmem-server binary not found under ${BUILD_DIR}"
}

find_qemu_system_binary() {
    local binary="$1"
    local candidate="${BUILD_DIR}/${binary}"

    if [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    if command -v "${binary}" >/dev/null 2>&1; then
        command -v "${binary}"
        return 0
    fi

    die "${binary} not found in ${BUILD_DIR} or PATH"
}
