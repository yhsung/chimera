#!/usr/bin/env bash
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
ARM_BL33_IMAGE="${ARM_BL33_IMAGE:-/usr/share/qemu-efi-aarch64/QEMU_EFI.fd}"
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
    CFG_TEE_CORE_LOG_LEVEL=2 \
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

    device-regions {
        compatible = "arm,ffa-manifest-device-regions";

        uart1 {
            base-address = <0x00000000 0x09040000>;
            pages-count = <1>;
            attributes = <0x3>;
            interrupts = <0x28 0xb01>;
        };
    };
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

    memory@40000000 {
        device_type = "ns-memory";
        reg = <0x0 0x40000000 0xc0000000>;
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
