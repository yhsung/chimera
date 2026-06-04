#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-mips)"

require_file "${MIPS_ISO}" "MIPS installer ISO"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/prepare-mips-boot-assets.sh"
bash "${SCRIPT_DIR}/prepare-demo-guest-overlays.sh"

require_file "${MIPS_KERNEL_IMAGE}"       "MIPS kernel image"
require_file "${MIPS_INITRAMFS_COMBINED}" "MIPS combined initramfs image"

exec "${qemu_bin}" \
    -machine malta \
    -cpu MIPS32R2-generic \
    -m 256M \
    -kernel "${MIPS_KERNEL_IMAGE}" \
    -initrd "${MIPS_INITRAMFS_COMBINED}" \
    -append "${MIPS_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -drive file="${MIPS_ISO}",media=cdrom \
    -nographic
