#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHIMERA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

LIMA_NAME="${LIMA_NAME:-qemu-dev}"
LIMA_CPUS="${LIMA_CPUS:-4}"
LIMA_MEMORY="${LIMA_MEMORY:-8}"
LIMA_DISK="${LIMA_DISK:-40}"

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

ARM_ISO="${ARM_ISO:-${ASSET_DIR}/alpine-virt-3.21.7-aarch64.iso}"
ARM_UEFI_BIOS="${ARM_UEFI_BIOS:-/usr/share/qemu-efi-aarch64/QEMU_EFI.fd}"
ARM_BOOT_ASSET_DIR="${ARM_BOOT_ASSET_DIR:-${HOME}/heterogeneous-soc-secure-stack/boot-assets}"
ARM_KERNEL_IMAGE="${ARM_KERNEL_IMAGE:-${ARM_BOOT_ASSET_DIR}/vmlinuz-virt}"
ARM_INITRAMFS_IMAGE="${ARM_INITRAMFS_IMAGE:-${ARM_BOOT_ASSET_DIR}/initramfs-virt}"
ARM_INITRAMFS_OVERLAY="${ARM_INITRAMFS_OVERLAY:-${ARM_BOOT_ASSET_DIR}/initramfs-overlay.cpio.gz}"
ARM_INITRAMFS_COMBINED="${ARM_INITRAMFS_COMBINED:-${ARM_BOOT_ASSET_DIR}/initramfs-virt-with-overlay}"
ARM_MODLOOP_IMAGE="${ARM_MODLOOP_IMAGE:-${ARM_BOOT_ASSET_DIR}/modloop-virt}"
ARM_KERNEL_CMDLINE="${ARM_KERNEL_CMDLINE:-modules=loop,squashfs,sd-mod,usb-storage,9p,9pnet,9pnet_virtio console=ttyAMA0}"
RISCV_ISO="${RISCV_ISO:-${ASSET_DIR}/alpine-standard-3.23.4-riscv64.iso}"
RISCV_UBOOT_ARCHIVE="${RISCV_UBOOT_ARCHIVE:-${ASSET_DIR}/alpine-uboot-3.23.4-riscv64.tar.gz}"
RISCV_UBOOT_DIR="${RISCV_UBOOT_DIR:-${ASSET_DIR}/alpine-uboot-3.23.4-riscv64}"
RISCV_UBOOT_BIN="${RISCV_UBOOT_BIN:-${RISCV_UBOOT_DIR}/u-boot/qemu-riscv64_smode/u-boot.bin}"
RISCV_DISK="${RISCV_DISK:-${ASSET_DIR}/alpine-riscv64.qcow2}"
RISCV_OPENSBI_BIOS="${RISCV_OPENSBI_BIOS:-/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin}"
RISCV_BOOT_ASSET_DIR="${RISCV_BOOT_ASSET_DIR:-${ASSET_DIR}/riscv-phase3-boot}"
RISCV_KERNEL_IMAGE_COMPRESSED="${RISCV_KERNEL_IMAGE_COMPRESSED:-${RISCV_BOOT_ASSET_DIR}/vmlinuz-lts}"
RISCV_KERNEL_IMAGE="${RISCV_KERNEL_IMAGE:-${RISCV_BOOT_ASSET_DIR}/Image-lts}"
RISCV_INITRAMFS_IMAGE="${RISCV_INITRAMFS_IMAGE:-${RISCV_BOOT_ASSET_DIR}/initramfs-lts}"
RISCV_INITRAMFS_OVERLAY="${RISCV_INITRAMFS_OVERLAY:-${RISCV_BOOT_ASSET_DIR}/initramfs-overlay.cpio.gz}"
RISCV_INITRAMFS_COMBINED="${RISCV_INITRAMFS_COMBINED:-${RISCV_BOOT_ASSET_DIR}/initramfs-lts-with-overlay}"
RISCV_MODLOOP_IMAGE="${RISCV_MODLOOP_IMAGE:-${RISCV_BOOT_ASSET_DIR}/modloop-lts}"
RISCV_KERNEL_CMDLINE="${RISCV_KERNEL_CMDLINE:-modules=loop,squashfs,sd-mod,usb-storage,9p,9pnet,9pnet_virtio console=ttyS0}"

ARM_SSH_PORT="${ARM_SSH_PORT:-2222}"
RISCV_SSH_PORT="${RISCV_SSH_PORT:-2223}"

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
FREERTOS_DEPS_ROOT="${FREERTOS_DEPS_ROOT:-${HOME}/heterogeneous-soc-freertos}"
FREERTOS_KERNEL_DIR="${FREERTOS_KERNEL_DIR:-${FREERTOS_DEPS_ROOT}/FreeRTOS-Kernel}"
FREERTOS_SHOWCASE_DIR="${FREERTOS_SHOWCASE_DIR:-${PINGPONG_DIR}/freertos-showcase}"
HELLO_ARM_BINARY="${HELLO_ARM_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-arm-linux}"
HELLO_RISCV_BINARY="${HELLO_RISCV_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-riscv-linux}"
FREERTOS_DEMO_ELF="${FREERTOS_DEMO_ELF:-${FREERTOS_SHOWCASE_DIR}/freertos-riscv-demo.elf}"
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
