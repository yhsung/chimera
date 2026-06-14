#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

SECURE_STACK_ROOT="${SECURE_STACK_ROOT:-${HOME}/heterogeneous-soc-secure-stack}"
TFA_DIR="${TFA_DIR:-${SECURE_STACK_ROOT}/trusted-firmware-a}"
HAFNIUM_DIR="${HAFNIUM_DIR:-${SECURE_STACK_ROOT}/hafnium}"
OPTEE_DIR="${OPTEE_DIR:-${SECURE_STACK_ROOT}/optee_os}"
HAFNIUM_PLATFORM="${HAFNIUM_PLATFORM:-secure_qemu_aarch64}"
HAFNIUM_TOOLCHAIN_BIN="${HAFNIUM_TOOLCHAIN_BIN:-}"
LLVM_TOOLCHAIN_BIN="${LLVM_TOOLCHAIN_BIN:-/usr/lib/llvm-18/bin}"
TFA_BUILD_ROOT="${TFA_BUILD_ROOT:-${SECURE_STACK_ROOT}/build-tfa}"
OPTEE_BUILD_DIR="${OPTEE_BUILD_DIR:-${SECURE_STACK_ROOT}/build-optee}"
OPTEE_PLATFORM="${OPTEE_PLATFORM:-vexpress-qemu_armv8a}"
OPTEE_CFG_ARM_GICV3="${OPTEE_CFG_ARM_GICV3:-y}"
OPTEE_CORE_LOG_LEVEL="${OPTEE_CORE_LOG_LEVEL:-2}"
OPTEE_USE_SEMIHOSTING_CONSOLE="${OPTEE_USE_SEMIHOSTING_CONSOLE:-0}"
OPTEE_SEMIHOSTING_CONSOLE_FILE="${OPTEE_SEMIHOSTING_CONSOLE_FILE:-NULL}"
ARMVIRT_QEMU_KERNEL_FD_DEFAULT="${HOME}/edk2/Build/ArmVirtQemuKernel-AArch64/DEBUG_GCCNOLTO/FV/QEMU_EFI.fd"
if [[ -z "${ARM_BL33_IMAGE:-}" ]]; then
    if [[ -f "${ARMVIRT_QEMU_KERNEL_FD_DEFAULT}" ]]; then
        ARM_BL33_IMAGE="${ARMVIRT_QEMU_KERNEL_FD_DEFAULT}"
    else
        ARM_BL33_IMAGE="/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
    fi
fi
ARM_SPMC_SP_LAYOUT="${ARM_SPMC_SP_LAYOUT:-${SECURE_STACK_ROOT}/generated/qemu_sp_layout.json}"
ARM_SPMC_TB_FW_CONFIG_DTS="${ARM_SPMC_TB_FW_CONFIG_DTS:-${SECURE_STACK_ROOT}/generated/qemu_tb_fw_config.dts}"
ARM_SPMC_TOS_FW_CONFIG_DTS="${ARM_SPMC_TOS_FW_CONFIG_DTS:-${SECURE_STACK_ROOT}/generated/qemu_tos_fw_config.dts}"
ARM_SPMC_OPTEE_MANIFEST_DTS="${ARM_SPMC_OPTEE_MANIFEST_DTS:-${SECURE_STACK_ROOT}/generated/qemu_optee_sp_manifest.dts}"
PYTHON_VENV_DIR="${PYTHON_VENV_DIR:-${SECURE_STACK_ROOT}/.venv}"
TFA_DEBUG="${TFA_DEBUG:-0}"
TFA_LOG_LEVEL="${TFA_LOG_LEVEL:-}"
INCLUDE_OPTEE_BL32_EXTRAS="${INCLUDE_OPTEE_BL32_EXTRAS:-0}"
HAFNIUM_LOAD_ADDRESS="${HAFNIUM_LOAD_ADDRESS:-0x0e100000}"
OPTEE_LOAD_ADDRESS="${OPTEE_LOAD_ADDRESS:-0x0e300000}"
OPTEE_MEM_SIZE="${OPTEE_MEM_SIZE:-0x00d00000}"
OPTEE_ENTRY_OFFSET="${OPTEE_ENTRY_OFFSET:-0x00004000}"
OPTEE_UUID_STRING="${OPTEE_UUID_STRING:-486178e0-e7f8-11e3-bc5e-0002a5d5c51b}"
SPMC_ID="${SPMC_ID:-0x8000}"
SPMC_VERSION_MAJOR="${SPMC_VERSION_MAJOR:-0x1}"
SPMC_VERSION_MINOR="${SPMC_VERSION_MINOR:-0x1}"
SPMC_VCPU_COUNT="${SPMC_VCPU_COUNT:-4}"
TFA_QEMU_GIC_DRIVER="${TFA_QEMU_GIC_DRIVER:-QEMU_GICV3}"
HAFNIUM_BRANCH_PROTECTION="${HAFNIUM_BRANCH_PROTECTION:-none}"
HAFNIUM_ENABLE_MTE="${HAFNIUM_ENABLE_MTE:-0}"
HAFNIUM_SKIP_HOST_TIMER="${HAFNIUM_SKIP_HOST_TIMER:-0}"
QEMU_SEC_DRAM_BASE="${QEMU_SEC_DRAM_BASE:-0x0e100000}"
QEMU_SEC_DRAM_SIZE="${QEMU_SEC_DRAM_SIZE:-0x00f00000}"
QEMU_NS_DRAM_BASE="${QEMU_NS_DRAM_BASE:-0x40000000}"
QEMU_NS_DRAM_SIZE="${QEMU_NS_DRAM_SIZE:-0xc0000000}"
QEMU_DEVICE0_BASE="${QEMU_DEVICE0_BASE:-0x08000000}"
QEMU_DEVICE0_SIZE="${QEMU_DEVICE0_SIZE:-0x01000000}"
QEMU_DEVICE1_BASE="${QEMU_DEVICE1_BASE:-0x09000000}"
QEMU_DEVICE1_SIZE="${QEMU_DEVICE1_SIZE:-0x00c00000}"
QEMU_SECURE_GPIO_BASE="${QEMU_SECURE_GPIO_BASE:-0x090b0000}"
QEMU_SECURE_GPIO_SIZE="${QEMU_SECURE_GPIO_SIZE:-0x00001000}"
OPTEE_UART_BASE="${OPTEE_UART_BASE:-0x09000000}"
OPTEE_UART_ATTRIBUTES="${OPTEE_UART_ATTRIBUTES:-0x0b}"
OPTEE_UART_INTERRUPT="${OPTEE_UART_INTERRUPT:-0x28 0xb01}"
OPTEE_INCLUDE_UART_DEVICE_REGION="${OPTEE_INCLUDE_UART_DEVICE_REGION:-0}"
OPTEE_DEBUG_CONSOLE_BASE="${OPTEE_DEBUG_CONSOLE_BASE:-}"
OPTEE_DEBUG_CONSOLE_MEM_AREA="${OPTEE_DEBUG_CONSOLE_MEM_AREA:-MEM_AREA_IO_SEC}"

if [[ "${TFA_DEBUG}" == "1" ]]; then
    TFA_BUILD_VARIANT="debug"
else
    TFA_BUILD_VARIANT="release"
fi

[[ -d "${TFA_DIR}" ]] || die "Trusted Firmware-A source tree not found: ${TFA_DIR}"
[[ -d "${HAFNIUM_DIR}" ]] || die "Hafnium source tree not found: ${HAFNIUM_DIR}"
[[ -d "${OPTEE_DIR}" ]] || die "OP-TEE source tree not found: ${OPTEE_DIR}"
require_file "${ARM_BL33_IMAGE}" "ARM BL33 image"

patch_tfa_qemu_sp_pkg_uuid_spec() {
    local qemu_io_storage="${TFA_DIR}/plat/qemu/common/qemu_io_storage.c"

    require_file "${qemu_io_storage}" "TF-A QEMU IO storage source"

    if grep -q 'read_uuid((uint8_t *)&pkg->uuid_spec.uuid, (char *)uuid)' "${qemu_io_storage}"; then
        return 0
    fi

    perl -0pi -e 's/uint8_t uuid\[UUID_BYTES_LENGTH\];/io_uuid_spec_t uuid_spec;/g' "${qemu_io_storage}"
    perl -0pi -e 's/read_uuid\(pkg->uuid, \(char \*\)uuid\)/read_uuid((uint8_t *)\&pkg->uuid_spec.uuid, (char *)uuid)/g' "${qemu_io_storage}"
    perl -0pi -e 's/read_uuid\(pkg->uuid_spec.uuid, \(char \*\)uuid\)/read_uuid((uint8_t *)\&pkg->uuid_spec.uuid, (char *)uuid)/g' "${qemu_io_storage}"
    perl -0pi -e 's/policy.image_spec = \(uintptr_t\)&pkg->uuid;/policy.image_spec = (uintptr_t)\&pkg->uuid_spec;/g' "${qemu_io_storage}"
}

patch_tfa_qemu_sp_pkg_uuid_spec

patch_hafnium_spmc_init_trace() {
    local hafnium_init="${HAFNIUM_DIR}/src/init.c"

    require_file "${hafnium_init}" "Hafnium init source"

    if grep -q 'TRACE: before manifest_init' "${hafnium_init}"; then
        return 0
    fi

    perl -0pi -e 's/manifest_ret = manifest_init/dlog_info("TRACE: before manifest_init\\n");\n\tmanifest_ret = manifest_init/g' "${hafnium_init}"
    perl -0pi -e 's/ffa_init_set_tee_enabled\(manifest->ffa_tee_enabled\);/\tdlog_info("TRACE: after manifest_init\\n");\n\n\tffa_init_set_tee_enabled(manifest->ffa_tee_enabled);/g' "${hafnium_init}"
    perl -0pi -e 's/if \(!plat_iommu_init\(&fdt, mm_stage1_locked\)\) {/\tdlog_info("TRACE: before plat_iommu_init\\n");\n\tif (!plat_iommu_init(&fdt, mm_stage1_locked)) {/g' "${hafnium_init}"
    perl -0pi -e 's/cpu_module_init\(params->cpu_ids, params->cpu_count\);/\tdlog_info("TRACE: after plat_iommu_init\\n");\n\n\tcpu_module_init(params->cpu_ids, params->cpu_count);\n\tdlog_info("TRACE: after cpu_module_init\\n");/g' "${hafnium_init}"
    perl -0pi -e 's/if \(!plat_interrupts_controller_driver_init\(&fdt, mm_stage1_locked\)\) {/\tdlog_info("TRACE: before plat_interrupts_controller_driver_init\\n");\n\tif (!plat_interrupts_controller_driver_init(&fdt, mm_stage1_locked)) {/g' "${hafnium_init}"
    perl -0pi -e 's/if \(!fdt_unmap\(&fdt, mm_stage1_locked\)\) {/\tdlog_info("TRACE: after plat_interrupts_controller_driver_init\\n");\n\n\tif (!fdt_unmap(&fdt, mm_stage1_locked)) {/g' "${hafnium_init}"
    perl -0pi -e 's/if \(!load_vms\(mm_stage1_locked, manifest, &cpio, params, &update\)\) {/\tdlog_info("TRACE: before load_vms\\n");\n\tif (!load_vms(mm_stage1_locked, manifest, &cpio, params, &update)) {/g' "${hafnium_init}"
    perl -0pi -e 's/if \(!boot_flow_update\(mm_stage1_locked, manifest, &update, &cpio\)\) {/\tdlog_info("TRACE: after load_vms\\n");\n\n\tif (!boot_flow_update(mm_stage1_locked, manifest, &update, &cpio)) {/g' "${hafnium_init}"
    perl -0pi -e 's/\/\* Perform platform specfic FF-A initialization\. \*\/\n\tffa_init\(\);/\/* Perform platform specfic FF-A initialization. *\/\n\tdlog_info("TRACE: before ffa_init\\n");\n\tffa_init();\n\tdlog_info("TRACE: after ffa_init\\n");/g' "${hafnium_init}"
}

patch_hafnium_spmc_init_trace

patch_hafnium_one_time_entry_trace() {
    local hafnium_init="${HAFNIUM_DIR}/src/init.c"

    require_file "${hafnium_init}" "Hafnium init source"

    if grep -q 'TRACE: entered one_time_init' "${hafnium_init}"; then
        return 0
    fi

    perl -0pi -e 's/arch_one_time_init\(\);/\tdlog_info("TRACE: entered one_time_init\\n");\n\tarch_one_time_init();\n\tdlog_info("TRACE: after arch_one_time_init\\n");/g' "${hafnium_init}"
    perl -0pi -e 's/dlog_enable_lock\(\);/\tdlog_info("TRACE: before dlog_enable_lock\\n");\n\tdlog_enable_lock();\n\tdlog_info("TRACE: after dlog_enable_lock\\n");/g' "${hafnium_init}"
    perl -0pi -e 's/mpool_enable_locks\(\);/\tdlog_info("TRACE: before mpool_enable_locks\\n");\n\tmpool_enable_locks();\n\tdlog_info("TRACE: after mpool_enable_locks\\n");/g' "${hafnium_init}"
    perl -0pi -e 's/mm_stage1_locked = mm_lock_stage1\(\);/\tdlog_info("TRACE: before mm_lock_stage1\\n");\n\tmm_stage1_locked = mm_lock_stage1();\n\tdlog_info("TRACE: after mm_lock_stage1\\n");/g' "${hafnium_init}"
    perl -0pi -e 's/if \(!fdt_map\(&fdt, mm_stage1_locked, plat_boot_flow_get_fdt_addr\(\)\)\) {/\tdlog_info("TRACE: before fdt_map\\n");\n\tif (!fdt_map(&fdt, mm_stage1_locked, plat_boot_flow_get_fdt_addr())) {/g' "${hafnium_init}"
    perl -0pi -e 's/params = memory_alloc\(sizeof\(struct boot_params\)\);/\tdlog_info("TRACE: after fdt_map\\n");\n\n\tparams = memory_alloc(sizeof(struct boot_params));\n\tdlog_info("TRACE: after memory_alloc boot_params\\n");/g' "${hafnium_init}"
}

patch_hafnium_one_time_entry_trace

patch_hafnium_qemu_feature_profile() {
    local hafnium_reference_build="${HAFNIUM_DIR}/project/reference/BUILD.gn"

    require_file "${hafnium_reference_build}" "Hafnium reference build configuration"

    perl -0pi -e 's/(aarch64_toolchains\("secure_qemu_aarch64"\) \{.*?branch_protection = )"[^"]+"/${1}"'"${HAFNIUM_BRANCH_PROTECTION}"'"/s' "${hafnium_reference_build}"
    perl -0pi -e 's/(aarch64_toolchains\("secure_qemu_aarch64"\) \{.*?enable_mte = )"[^"]+"/${1}"'"${HAFNIUM_ENABLE_MTE}"'"/s' "${hafnium_reference_build}"
}

patch_hafnium_qemu_feature_profile

patch_hafnium_qemu_host_timer_workaround() {
    local hafnium_cpu="${HAFNIUM_DIR}/src/arch/aarch64/hypervisor/cpu.c"
    local hafnium_host_timer="${HAFNIUM_DIR}/src/arch/aarch64/hypervisor/host_timer.c"
    local hafnium_el1_timer="${HAFNIUM_DIR}/src/arch/aarch64/hypervisor/el1_physical_timer.c"

    require_file "${hafnium_cpu}" "Hafnium AArch64 hypervisor CPU source"
    require_file "${hafnium_host_timer}" "Hafnium host timer source"
    require_file "${hafnium_el1_timer}" "Hafnium EL1 physical timer source"

    if [[ "${HAFNIUM_SKIP_HOST_TIMER}" != "1" ]]; then
        return 0
    fi

    if ! grep -q 'TRACE: host_timer_init skipped for QEMU workaround' "${hafnium_cpu}"; then
        perl -0pi -e 's/\n\t\/\*\n\t \* Initialize the interrupt associated with S-EL2 physical timer for\n\t \* running core\.\n\t \*\/\n\thost_timer_init\(\);\n/\n\t\/\* QEMU S-EL2 timer workaround: skip host timer init. *\/\n\tdlog_info("TRACE: host_timer_init skipped for QEMU workaround\\n");\n/s' "${hafnium_cpu}"
    fi

    if ! grep -q 'TRACE: host_timer_save_arch_timer skipped for QEMU workaround' "${hafnium_host_timer}"; then
        perl -0pi -e 's/void host_timer_disable\(void\)\n\{\n#if SECURE_WORLD == 1\n\twrite_msr\(cnthps_ctl_el2, 0\);\n#else\n\twrite_msr\(cnthp_ctl_el2, 0\);\n#endif\n\t\/\* Ensure that the write to ctl register has taken effect\. \*\/\n\tisb\(\);\n\}/void host_timer_disable(void)\n{\n\tdlog_info("TRACE: host_timer_disable skipped for QEMU workaround\\n");\n\}/s' "${hafnium_host_timer}"
        perl -0pi -e 's/void host_timer_init\(void\)\n\{\n\thost_timer_disable\(\);\n\n#if SECURE_WORLD == 1\n\tstruct interrupt_descriptor int_desc = \{\n\t\t\.interrupt_id = ARM_SEL2_TIMER_PHYS_INT,\n\t\t\.type = INT_DESC_TYPE_PPI,\n\t\t\.config = 1U, \/\* Level-sensitive \*\/\n\t\t\.sec_state = INT_DESC_SEC_STATE_S,\n\t\t\.priority = 0x0,\n\t\t\.valid = true,\n\t\t\.mpidr_valid = false,\n\t\t\.enabled = true,\n\t\};\n\n\tplat_interrupts_configure_interrupt\(int_desc\);\n#endif\n\}/void host_timer_init(void)\n{\n\tdlog_info("TRACE: host_timer_init skipped for QEMU workaround\\n");\n\}/s' "${hafnium_host_timer}"
        perl -0pi -e 's/void host_timer_save_arch_timer\(struct timer_state \*timer\)\n\{\n#if SECURE_WORLD == 1\n\ttimer->cval = read_msr\(MSR_CNTHPS_CVAL_EL2\);\n\ttimer->ctl = read_msr\(MSR_CNTHPS_CTL_EL2\);\n#else\n\ttimer->cval = read_msr\(MSR_CNTHP_CVAL_EL2\);\n\ttimer->ctl = read_msr\(MSR_CNTHP_CTL_EL2\);\n#endif\n\}/void host_timer_save_arch_timer(struct timer_state *timer)\n{\n\t(void)timer;\n\tdlog_info("TRACE: host_timer_save_arch_timer skipped for QEMU workaround\\n");\n\}/s' "${hafnium_host_timer}"
        perl -0pi -e 's/void host_timer_track_deadline\(struct timer_state \*timer\)\n\{\n\t\/\*\n\t \* Clear timer control register before restoring compare value, to avoid\n\t \* a spurious timer interrupt\. This could be a problem if the interrupt\n\t \* is configured as edge-triggered, as it would then be latched in\.\n\t \*\/\n#if SECURE_WORLD == 1\n\twrite_msr\(cnthps_ctl_el2, 0\);\n\twrite_msr\(cnthps_cval_el2, timer->cval\);\n\twrite_msr\(cnthps_ctl_el2, timer->ctl\);\n#else\n\twrite_msr\(cnthp_ctl_el2, 0\);\n\twrite_msr\(cnthp_cval_el2, timer->cval\);\n\twrite_msr\(cnthp_ctl_el2, timer->ctl\);\n#endif\n\t\/\* Ensure that the write to ctl register has taken effect\. \*\/\n\tisb\(\);\n\}/void host_timer_track_deadline(struct timer_state *timer)\n{\n\t(void)timer;\n\tdlog_info("TRACE: host_timer_track_deadline skipped for QEMU workaround\\n");\n\}/s' "${hafnium_host_timer}"
    fi

    if ! grep -q 'TRACE: emulating timer access without host timer' "${hafnium_el1_timer}"; then
        perl -0pi -e 's/#include "hf\/dlog.h"/#include "hf\/dlog.h"\n\n#include <limits.h>/' "${hafnium_el1_timer}"
        perl -0pi -e 's@\n/\*\*\n \* Access to CNTP timer register is trapped and emulated using S-EL2\n \* physical timer\.\n \*/\nbool el1_physical_timer_process_access\(struct vcpu \*vcpu, uintreg_t esr\)\n\{.*?\n\}\n@\nstatic uint64_t timer_remaining_ticks(struct vcpu *vcpu)\n{\n\tuint64_t current_ticks = read_msr(cntpct_el0);\n\tuint64_t compare_value = vcpu->regs.arch_timer.cval;\n\n\tif (compare_value >= current_ticks) {\n\t\treturn compare_value - current_ticks;\n\t}\n\n\treturn 0;\n}\n\n/**\n * Access to CNTP timer register is trapped and emulated using saved vCPU\n * state only, avoiding unsupported S-EL2 host timer accesses under QEMU.\n */\nbool el1_physical_timer_process_access(struct vcpu *vcpu, uintreg_t esr)\n{\n\tuintreg_t sys_register = GET_ISS_SYSREG(esr);\n\tuintreg_t rt_register = GET_ISS_RT(esr);\n\tuintreg_t value = 0;\n\tuint64_t current_ticks = read_msr(cntpct_el0);\n\n\tdlog_info("TRACE: emulating timer access without host timer\\n");\n\n\tif (ISS_IS_READ(esr)) {\n\t\tswitch (sys_register) {\n\t\tcase GET_ISS_ENCODING(3, 3, 14, 2, 1):\n\t\t\tvalue = vcpu->regs.arch_timer.ctl;\n\t\t\tbreak;\n\t\tcase GET_ISS_ENCODING(3, 3, 14, 2, 2):\n\t\t\tvalue = vcpu->regs.arch_timer.cval;\n\t\t\tbreak;\n\t\tcase GET_ISS_ENCODING(3, 3, 14, 2, 0):\n\t\t\tvalue = timer_remaining_ticks(vcpu);\n\t\t\tif (value > INT32_MAX) {\n\t\t\t\tvalue = INT32_MAX;\n\t\t\t}\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tdlog_notice(\n\t\t\t\t"Unsupported timer register read: op0=%lu, "\n\t\t\t\t"op1=%lu, crn=%lu, crm=%lu, op2=%lu, rt=%lu.\\n",\n\t\t\t\tGET_ISS_OP0(esr), GET_ISS_OP1(esr), GET_ISS_CRN(esr),\n\t\t\t\tGET_ISS_CRM(esr), GET_ISS_OP2(esr), GET_ISS_RT(esr));\n\t\t\tbreak;\n\t\t}\n\t\tvcpu->regs.r[rt_register] = value;\n\t} else {\n\t\tvalue = vcpu->regs.r[rt_register];\n\t\tswitch (sys_register) {\n\t\tcase GET_ISS_ENCODING(3, 3, 14, 2, 1):\n\t\t\tvcpu->regs.arch_timer.ctl = value;\n\t\t\tbreak;\n\t\tcase GET_ISS_ENCODING(3, 3, 14, 2, 2):\n\t\t\tvcpu->regs.arch_timer.cval = value;\n\t\t\tbreak;\n\t\tcase GET_ISS_ENCODING(3, 3, 14, 2, 0):\n\t\t\tvcpu->regs.arch_timer.cval = current_ticks + value;\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tdlog_notice(\n\t\t\t\t"Unsupported timer register write: op0=%lu, "\n\t\t\t\t"op1=%lu, crn=%lu, crm=%lu, op2=%lu, rt=%lu, value=%lu.\\n",\n\t\t\t\tGET_ISS_OP0(esr), GET_ISS_OP1(esr), GET_ISS_CRN(esr),\n\t\t\t\tGET_ISS_CRM(esr), GET_ISS_OP2(esr), GET_ISS_RT(esr), value);\n\t\t\tbreak;\n\t\t}\n\t}\n\n\treturn true;\n}\n@s' "${hafnium_el1_timer}"
    fi
}

patch_hafnium_qemu_host_timer_workaround

patch_optee_debug_console_base() {
    local optee_main="${OPTEE_DIR}/core/arch/arm/plat-vexpress/main.c"

    require_file "${optee_main}" "OP-TEE vexpress platform main source"

    if [[ -z "${OPTEE_DEBUG_CONSOLE_BASE}" ]]; then
        return 0
    fi

    if grep -q 'HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE' "${optee_main}"; then
        perl -0pi -e 's/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE\s+0x[0-9a-fA-F]+/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE '"${OPTEE_DEBUG_CONSOLE_BASE}"'/g' "${optee_main}"
        if grep -q 'HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA' "${optee_main}"; then
            perl -0pi -e 's/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA\s+\w+/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA '"${OPTEE_DEBUG_CONSOLE_MEM_AREA}"'/g' "${optee_main}"
        else
            perl -0pi -e 's/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE [^\n]+\n/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE '"${OPTEE_DEBUG_CONSOLE_BASE}"'\n#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA '"${OPTEE_DEBUG_CONSOLE_MEM_AREA}"'\n/g' "${optee_main}"
        fi
        perl -0pi -e 's/register_phys_mem_pgdir\(MEM_AREA_IO_SEC, HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE, PL011_REG_SIZE\);/register_phys_mem_pgdir(HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA, HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE, PL011_REG_SIZE);/g' "${optee_main}"
        return 0
    fi

    perl -0pi -e 's/static struct pl011_data console_data __nex_bss;/#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE '"${OPTEE_DEBUG_CONSOLE_BASE}"'\n#define HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA '"${OPTEE_DEBUG_CONSOLE_MEM_AREA}"'\n\nstatic struct pl011_data console_data __nex_bss;/g' "${optee_main}"
    perl -0pi -e 's/register_phys_mem_pgdir\(MEM_AREA_IO_SEC, CONSOLE_UART_BASE, PL011_REG_SIZE\);/register_phys_mem_pgdir(HETEROGENEOUS_SOC_DEBUG_CONSOLE_MEM_AREA, HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE, PL011_REG_SIZE);/g' "${optee_main}"
    perl -0pi -e 's/pl011_init\(&console_data, CONSOLE_UART_BASE, CONSOLE_UART_CLK_IN_HZ,/pl011_init(&console_data, HETEROGENEOUS_SOC_DEBUG_CONSOLE_BASE, CONSOLE_UART_CLK_IN_HZ,/g' "${optee_main}"
}

patch_optee_debug_console_base

if [[ -n "${HAFNIUM_TOOLCHAIN_BIN}" ]]; then
    PATH="${HAFNIUM_TOOLCHAIN_BIN}:${PATH}"
fi

if [[ -d "${LLVM_TOOLCHAIN_BIN}" ]]; then
    PATH="${LLVM_TOOLCHAIN_BIN}:${PATH}"
fi

python3 -m venv "${PYTHON_VENV_DIR}"
PATH="${PYTHON_VENV_DIR}/bin:${PATH}"
"${PYTHON_VENV_DIR}/bin/pip" install --upgrade pip
"${PYTHON_VENV_DIR}/bin/pip" install fdt click cryptography pyelftools

mkdir -p "${SECURE_STACK_ROOT}/generated" "${OPTEE_BUILD_DIR}"

optee_load_address_dec=$((OPTEE_LOAD_ADDRESS))
optee_mem_size_dec=$((OPTEE_MEM_SIZE))
optee_entry_offset_dec=$((OPTEE_ENTRY_OFFSET))
optee_tzdram_start_dec=$((optee_load_address_dec + optee_entry_offset_dec))
optee_tzdram_size_dec=$((optee_mem_size_dec - optee_entry_offset_dec))

make -C "${OPTEE_DIR}" \
    O="${OPTEE_BUILD_DIR}" \
    PLATFORM="${OPTEE_PLATFORM}" \
    CFG_ARM64_core=y \
    CFG_ARM_GICV3="${OPTEE_CFG_ARM_GICV3}" \
    CFG_CALLOUT=y \
    CFG_CORE_ASYNC_NOTIF=y \
    CFG_CORE_HAFNIUM_INTC=y \
    CFG_CORE_SEL2_SPMC=y \
    CFG_CORE_WORKAROUND_NSITR_CACHE_PRIME=n \
    CFG_DEBUG_INFO=y \
    CFG_NOTIF_TEST_WD=y \
    CFG_SEMIHOSTING_CONSOLE="${OPTEE_USE_SEMIHOSTING_CONSOLE}" \
    CFG_SEMIHOSTING_CONSOLE_FILE="${OPTEE_SEMIHOSTING_CONSOLE_FILE}" \
    CFG_TEE_CORE_LOG_LEVEL="${OPTEE_CORE_LOG_LEVEL}" \
    CFG_TZDRAM_START="$(printf '0x%08x' "${optee_tzdram_start_dec}")" \
    CFG_TZDRAM_SIZE="$(printf '0x%08x' "${optee_tzdram_size_dec}")" \
    CFG_USER_TA_TARGETS=ta_arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_core=aarch64-linux-gnu- \
    CROSS_COMPILE_ta_arm64=aarch64-linux-gnu- \
    DEBUG=0 \
    all

OPTEE_PAGER_BIN="${OPTEE_BUILD_DIR}/core/tee-pager_v2.bin"
OPTEE_PAGEABLE_BIN="${OPTEE_BUILD_DIR}/core/tee-pageable_v2.bin"
require_file "${OPTEE_PAGER_BIN}" "OP-TEE pager binary"
require_file "${OPTEE_PAGEABLE_BIN}" "OP-TEE pageable binary"

optee_uart_device_region=""
if [[ "${OPTEE_INCLUDE_UART_DEVICE_REGION}" == "1" ]]; then
    optee_uart_device_region=$(cat <<EOF
    device-regions {
        compatible = "arm,ffa-manifest-device-regions";

        uart1 {
            base-address = <0x00000000 ${OPTEE_UART_BASE}>;
            pages-count = <1>;
            attributes = <${OPTEE_UART_ATTRIBUTES}>;
            interrupts = <${OPTEE_UART_INTERRUPT}>;
        };
    };
EOF
)
fi

cat > "${ARM_SPMC_OPTEE_MANIFEST_DTS}" <<EOF
/dts-v1/;

/ {
    compatible = "arm,ffa-manifest-1.0";

    description = "op-tee";
    ffa-version = <0x00010001>;
    uuid = <0x486178e0 0xe7f811e3 0xbc5e0002 0xa5d5c51b>;
    id = <1>;
    execution-ctx-count = <8>;
    exception-level = <2>;
    execution-state = <0>;
    load-address = <${OPTEE_LOAD_ADDRESS}>;
    mem-size = <${OPTEE_MEM_SIZE}>;
    entrypoint-offset = <${OPTEE_ENTRY_OFFSET}>;
    xlat-granule = <0>;
    boot-order = <0>;
    messaging-method = <0x3>;
    ns-interrupts-action = <1>;

    gp-register-num = <0x0>;

    boot-info {
        compatible = "arm,ffa-manifest-boot-info";
        ffa_manifest;
    };
${optee_uart_device_region}
};
EOF

cat > "${ARM_SPMC_SP_LAYOUT}" <<EOF
{
    "op-tee": {
        "image": "${OPTEE_PAGER_BIN}",
        "pm": "${ARM_SPMC_OPTEE_MANIFEST_DTS}"
    }
}
EOF

make -C "${HAFNIUM_DIR}" clobber
make -C "${HAFNIUM_DIR}" PLATFORM="${HAFNIUM_PLATFORM}"

HAFNIUM_BIN="${HAFNIUM_DIR}/out/reference/${HAFNIUM_PLATFORM}_clang/hafnium.bin"
require_file "${HAFNIUM_BIN}" "Hafnium secure world binary"
hafnium_bin_size="$(stat -c '%s' "${HAFNIUM_BIN}")"
hafnium_bin_size_hex="$(printf '0x%x' "${hafnium_bin_size}")"

cat > "${ARM_SPMC_TB_FW_CONFIG_DTS}" <<EOF
/dts-v1/;

/ {
    secure-partitions {
        compatible = "arm,sp";

        op-tee {
            uuid = "${OPTEE_UUID_STRING}";
            load-address = <${OPTEE_LOAD_ADDRESS}>;
        };
    };
};
EOF

cat > "${ARM_SPMC_TOS_FW_CONFIG_DTS}" <<EOF
/dts-v1/;

/ {
    compatible = "arm,ffa-core-manifest-1.0";
    #address-cells = <2>;
    #size-cells = <1>;

    attribute {
        spmc_id = <${SPMC_ID}>;
        maj_ver = <${SPMC_VERSION_MAJOR}>;
        min_ver = <${SPMC_VERSION_MINOR}>;
        exec_state = <0x0>;
        load_address = <0x0 ${HAFNIUM_LOAD_ADDRESS}>;
        entrypoint = <0x0 ${HAFNIUM_LOAD_ADDRESS}>;
        binary_size = <${hafnium_bin_size_hex}>;
    };

    hypervisor {
        compatible = "hafnium,hafnium";
        ffa_tee_enabled;

        vm1 {
            is_ffa_partition;
            load_address = <${OPTEE_LOAD_ADDRESS}>;
            debug_name = "op-tee";
            vcpu_count = <${SPMC_VCPU_COUNT}>;
            mem_size = <${OPTEE_MEM_SIZE}>;
        };
    };

    cpus {
        #address-cells = <0x02>;
        #size-cells = <0x00>;

        cpu@0 {
            device_type = "cpu";
            reg = <0x0 0x0>;
        };
        cpu@3 {
            device_type = "cpu";
            reg = <0x0 0x3>;
        };
        cpu@2 {
            device_type = "cpu";
            reg = <0x0 0x2>;
        };
        cpu@1 {
            device_type = "cpu";
            reg = <0x0 0x1>;
        };
    };

    memory@0 {
        device_type = "memory";
        reg = <0x0 ${QEMU_SEC_DRAM_BASE} ${QEMU_SEC_DRAM_SIZE}>;
    };

    memory@1 {
        device_type = "ns-memory";
        reg = <0x0 ${QEMU_NS_DRAM_BASE} ${QEMU_NS_DRAM_SIZE}>;
    };

    memory@2 {
        device_type = "device-memory";
        reg = <0x0 ${QEMU_SECURE_GPIO_BASE} ${QEMU_SECURE_GPIO_SIZE}>;
    };

    memory@3 {
        device_type = "ns-device-memory";
        reg = <0x0 ${QEMU_DEVICE0_BASE} ${QEMU_DEVICE0_SIZE}>,
              <0x0 ${QEMU_DEVICE1_BASE} ${QEMU_DEVICE1_SIZE}>;
    };
};
EOF

mkdir -p "${TFA_BUILD_ROOT}"
TFA_BUILD_PLAT="${TFA_BUILD_ROOT}/qemu/${TFA_BUILD_VARIANT}"
TFA_SP_DTS_LIST_FRAGMENT="${TFA_BUILD_PLAT}/sp_list_fragment.dts"
TFA_SP_GEN_MK="${TFA_BUILD_PLAT}/sp_gen.mk"
TFA_FIP_PFLASH="${TFA_BUILD_PLAT}/fip-pflash.bin"
mkdir -p "${TFA_BUILD_PLAT}"
"${PYTHON_VENV_DIR}/bin/python3" \
    "${TFA_DIR}/tools/sptool/sp_mk_generator.py" \
    "${TFA_SP_GEN_MK}" \
    "${ARM_SPMC_SP_LAYOUT}" \
    "${TFA_BUILD_PLAT}" \
    "single-root" \
    "${TFA_SP_DTS_LIST_FRAGMENT}"

TFA_ARGS=(
    CROSS_COMPILE=aarch64-linux-gnu-
    PLAT=qemu
    PYTHON="${PYTHON_VENV_DIR}/bin/python3"
    DEBUG="${TFA_DEBUG}"
    SPD=spmd
    SPMD_SPM_AT_SEL2=1
    BL32="${HAFNIUM_BIN}"
    BL33="${ARM_BL33_IMAGE}"
    BUILD_BASE="${TFA_BUILD_ROOT}"
    QEMU_USE_GIC_DRIVER="${TFA_QEMU_GIC_DRIVER}"
    QEMU_TB_FW_CONFIG_DTS="${ARM_SPMC_TB_FW_CONFIG_DTS}"
    QEMU_TOS_FW_CONFIG_DTS="${ARM_SPMC_TOS_FW_CONFIG_DTS}"
    SP_DTS_LIST_FRAGMENT="${TFA_SP_DTS_LIST_FRAGMENT}"
)

if [[ "${INCLUDE_OPTEE_BL32_EXTRAS}" == "1" ]]; then
    TFA_ARGS+=(
        BL32_EXTRA1="${OPTEE_PAGER_BIN}"
        BL32_EXTRA2="${OPTEE_PAGEABLE_BIN}"
    )
fi

if [[ -n "${ARM_SPMC_SP_LAYOUT}" ]]; then
    require_file "${ARM_SPMC_SP_LAYOUT}" "Secure partition layout JSON"
    TFA_ARGS+=(SP_LAYOUT_FILE="${ARM_SPMC_SP_LAYOUT}")
fi

if [[ -n "${TFA_LOG_LEVEL}" ]]; then
    TFA_ARGS+=(LOG_LEVEL="${TFA_LOG_LEVEL}")
fi

make -C "${TFA_DIR}" "${TFA_ARGS[@]}" all fip
truncate -s 64M "${TFA_FIP_PFLASH}"
dd if="${TFA_BUILD_PLAT}/fip.bin" of="${TFA_FIP_PFLASH}" conv=notrunc status=none

echo "ARM_TFA_BL1=${TFA_BUILD_PLAT}/bl1.bin"
echo "ARM_TFA_FIP=${TFA_BUILD_PLAT}/fip.bin"
echo "ARM_TFA_FIP_PFLASH=${TFA_FIP_PFLASH}"
echo "ARM_TFA_QEMU_BIOS=${TFA_BUILD_PLAT}/qemu_fw.bios"
echo "ARM_TFA_QEMU_ROM=${TFA_BUILD_PLAT}/qemu_fw.rom"
echo "ARM_HAFNIUM_BIN=${HAFNIUM_BIN}"
echo "ARM_OPTEE_PAGER_BIN=${OPTEE_PAGER_BIN}"
echo "ARM_OPTEE_PAGEABLE_BIN=${OPTEE_PAGEABLE_BIN}"
echo "ARM_SPMC_TB_FW_CONFIG_DTS=${ARM_SPMC_TB_FW_CONFIG_DTS}"
echo "ARM_SPMC_TOS_FW_CONFIG_DTS=${ARM_SPMC_TOS_FW_CONFIG_DTS}"
