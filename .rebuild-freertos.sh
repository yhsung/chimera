#!/usr/bin/env bash
set -euo pipefail
SRC=/Users/yhsung/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
FRT_KERNEL=${HOME}/heterogeneous-soc-freertos/FreeRTOS-Kernel
OUT=/home/yhsung.guest/freertos-riscv-demo.elf
CROSS=riscv64-unknown-elf-

echo "[rebuild] Building freertos-riscv-demo.elf → ${OUT}"

"${CROSS}gcc" -O2 -Wall -Wextra -ffreestanding -fno-omit-frame-pointer \
    -march=rv64gc -mabi=lp64d -mcmodel=medany -msmall-data-limit=0 \
    -ffunction-sections -fdata-sections \
    -I"${SRC}" \
    -I"${FRT_KERNEL}/include" \
    -I"${FRT_KERNEL}/portable/GCC/RISC-V" \
    -I"${FRT_KERNEL}/portable/GCC/RISC-V/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions" \
    "${SRC}/startup.S" \
    "${SRC}/freertos_main.c" \
    "${SRC}/freertos_ivshmem_flat.c" \
    "${SRC}/freertos_libc.c" \
    "${FRT_KERNEL}/tasks.c" \
    "${FRT_KERNEL}/list.c" \
    "${FRT_KERNEL}/queue.c" \
    "${FRT_KERNEL}/portable/MemMang/heap_4.c" \
    "${FRT_KERNEL}/portable/GCC/RISC-V/port.c" \
    "${FRT_KERNEL}/portable/GCC/RISC-V/portASM.S" \
    -nostdlib -static -Wl,--gc-sections \
    -T "${SRC}/linker.ld" \
    -lgcc \
    -o "${OUT}"

echo "[rebuild] Verifying trap handler is present:"
"${CROSS}nm" "${OUT}" | grep -E "freertos_risc_v_trap_handler|_start" | sort
echo ""
echo "[rebuild] Verifying mtvec write exists in binary:"
"${CROSS}objdump" -d "${OUT}" | grep "mtvec" | head -5
echo "[rebuild] DONE: ${OUT} ($(wc -c < ${OUT}) bytes)"
