#!/usr/bin/env bash
set -euo pipefail
BUILD_DIR=/home/yhsung.guest/chimera-build-linux
source /Users/yhsung/dev-projects/chimera/scripts/heterogeneous-soc/common.sh

pkill -f "ivshmem-server" 2>/dev/null || true
rm -f "${IVSHMEM_ARM_FREERTOS_SOCKET}" "${IVSHMEM_RISCV_FREERTOS_SOCKET}" 2>/dev/null || true
mkdir -p "${IVSHMEM_ARM_FREERTOS_DIR}" "${IVSHMEM_RISCV_FREERTOS_DIR}"

"${BUILD_DIR}/contrib/ivshmem-server/ivshmem-server" \
    -F -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"  -l 67108864 -n 4 &>/dev/null &
"${BUILD_DIR}/contrib/ivshmem-server/ivshmem-server" \
    -F -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" -l 67108864 -n 4 &>/dev/null &
sleep 1

echo "[diag] Running FreeRTOS QEMU for 6s with -d int ..."
"${BUILD_DIR}/qemu-system-riscv64" \
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -bios /Users/yhsung/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf \
    -nographic \
    -d int,guest_errors \
    < /dev/null \
    > /home/yhsung.guest/freertos-uart.log 2>/home/yhsung.guest/freertos-int.log &
QEMU_PID=$!

sleep 6
kill "${QEMU_PID}" 2>/dev/null || true
wait "${QEMU_PID}" 2>/dev/null || true

echo "=== UART output ==="
cat /home/yhsung.guest/freertos-uart.log 2>/dev/null || echo "(empty)"
echo ""
echo "=== Interrupt trace (first 80 lines) ==="
head -80 /home/yhsung.guest/freertos-int.log 2>/dev/null || echo "(empty)"
echo "=== Total interrupt trace lines: $(wc -l < /home/yhsung.guest/freertos-int.log 2>/dev/null || echo 0) ==="
