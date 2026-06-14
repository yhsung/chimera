#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SESSION_NAME="${SESSION_NAME:-heterogeneous-soc}"
ARM_RUN_SCRIPT="${ARM_RUN_SCRIPT:-scripts/heterogeneous-soc/guest-run-arm-phase1.sh}"
RISCV_RUN_SCRIPT="${RISCV_RUN_SCRIPT:-scripts/heterogeneous-soc/guest-run-riscv-phase3.sh}"
RISCV_BOOT_MODE="${RISCV_BOOT_MODE:-direct}"
RISCV_KERNEL_CMDLINE="${RISCV_KERNEL_CMDLINE:-modules=loop,squashfs,sd-mod,usb-storage,9p,9pnet,9pnet_virtio console=ttyS0 earlycon=sbi irqpoll}"
PHASE3_QEMU_MACHINE="${PHASE3_QEMU_MACHINE:-virt,aclint=on}"
PHASE3_QEMU_CPU="${PHASE3_QEMU_CPU:-rv64}"
SERVER_SCRIPT="${SERVER_SCRIPT:-scripts/heterogeneous-soc/guest-start-ivshmem-server.sh}"
STOP_DEMO_GUESTS_SCRIPT="${STOP_DEMO_GUESTS_SCRIPT:-scripts/heterogeneous-soc/guest-stop-demo-guests.sh}"
STOP_STALE_DEMO_GUESTS="${STOP_STALE_DEMO_GUESTS:-1}"
AUTO_PREPARE_GUESTS_SCRIPT="${AUTO_PREPARE_GUESTS_SCRIPT:-scripts/heterogeneous-soc/guest-demo-auto-prepare-guests.sh}"
AUTO_PREPARE_GUESTS="${AUTO_PREPARE_GUESTS:-1}"
LIMA_NAME="${LIMA_NAME:-qemu-dev}"
RUN_IN_LIMA="${RUN_IN_LIMA:-auto}"
CONTROL_MESSAGE="${CONTROL_MESSAGE:-Control-pane helpers:
bash scripts/heterogeneous-soc/guest-demo-prepare-guests.sh
bash scripts/heterogeneous-soc/guest-demo-guest-run-pong.sh
bash scripts/heterogeneous-soc/guest-demo-guest-run-ping.sh}"
ENV_SETUP_SCRIPT="${ENV_SETUP_SCRIPT:-}"
HOST_TERM="${TERM:-}"
FALLBACK_TERM="${FALLBACK_TERM:-xterm-256color}"

die() {
    echo "error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || die "required file not found: $1"
}

require_repo_or_abs_file() {
    local path="$1"

    if repo_file_exists "${path}" || [[ -f "${path}" ]]; then
        return
    fi

    die "required file not found: ${path}"
}

shell_quote() {
    printf '%q' "$1"
}

should_run_in_lima() {
    case "${RUN_IN_LIMA}" in
        1|true|TRUE|yes|YES)
            return 0
            ;;
        0|false|FALSE|no|NO)
            return 1
            ;;
        auto|AUTO)
            [[ "$(uname -s)" != "Linux" ]] && command -v limactl >/dev/null 2>&1
            return
            ;;
        *)
            return 1
            ;;
    esac
}

remote_path_expr() {
    local path="$1"

    if [[ -n "${HOME:-}" && "${path}" == "${HOME}" ]]; then
        printf '$HOME'
        return
    fi

    if [[ -n "${HOME:-}" && "${path}" == "${HOME}/"* ]]; then
        printf '$HOME/%s' "${path#"${HOME}/"}"
        return
    fi

    shell_quote "${path}"
}

lima_env_assignments() {
    local pairs=()
    local var_name
    local value

    for var_name in BUILD_DIR VM_SOURCE_DIR ASSET_DIR; do
        value="${!var_name:-}"
        if [[ -n "${value}" ]]; then
            pairs+=("${var_name}=$(remote_path_expr "${value}")")
        fi
    done

    printf '%s' "${pairs[*]}"
}

run_repo_command_now() {
    local cmd="$1"
    local remote_cmd
    local remote_env

    if should_run_in_lima; then
        remote_cmd="cd $(shell_quote "${REPO_ROOT}") && ${cmd}"
        remote_env="$(lima_env_assignments)"
        if [[ -n "${remote_env}" ]]; then
            remote_cmd="${remote_env} ${remote_cmd}"
        fi

        limactl shell "${LIMA_NAME}" -- sh -lc "${remote_cmd}"
        return
    fi

    (
        cd "${REPO_ROOT}"
        eval "${cmd}"
    )
}

send_repo_command() {
    local target="$1"
    local cmd="$2"
    local remote_cmd
    local remote_env

    if should_run_in_lima; then
        remote_cmd="cd $(shell_quote "${REPO_ROOT}") && ${cmd}"
        remote_env="$(lima_env_assignments)"
        if [[ -n "${remote_env}" ]]; then
            remote_cmd="${remote_env} ${remote_cmd}"
        fi

        tmux send-keys \
            -t "${target}" \
            "limactl shell $(shell_quote "${LIMA_NAME}") -- sh -lc $(shell_quote "${remote_cmd}")" \
            C-m
        return
    fi

    tmux send-keys -t "${target}" "cd $(shell_quote "${REPO_ROOT}") && ${cmd}" C-m
}

send_local_repo_command() {
    local target="$1"
    local cmd="$2"

    tmux send-keys -t "${target}" "cd $(shell_quote "${REPO_ROOT}") && ${cmd}" C-m
}

send_message_pane() {
    local target="$1"
    local message="$2"

    tmux send-keys -t "${target}" "cd $(shell_quote "${REPO_ROOT}") && printf '%s\n' $(shell_quote "${message}")" C-m
}

command_prefix() {
    local prefix=""

    if [[ -n "${ENV_SETUP_SCRIPT}" ]]; then
        prefix=". $(shell_quote "${ENV_SETUP_SCRIPT}") && "
    fi

    printf '%s' "${prefix}"
}

repo_file_exists() {
    [[ -f "${REPO_ROOT}/$1" ]]
}

should_stop_stale_demo_guests() {
    case "${STOP_STALE_DEMO_GUESTS}" in
        1|true|TRUE|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

should_auto_prepare_guests() {
    case "${AUTO_PREPARE_GUESTS}" in
        1|true|TRUE|yes|YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

select_tmux_term() {
    if [[ -n "${HOST_TERM}" ]] && infocmp "${HOST_TERM}" >/dev/null 2>&1; then
        printf '%s' "${HOST_TERM}"
        return
    fi

    if infocmp "${FALLBACK_TERM}" >/dev/null 2>&1; then
        printf '%s' "${FALLBACK_TERM}"
        return
    fi

    printf 'screen'
}

maybe_launch_server() {
    local target="$1"
    local build_dir="${BUILD_DIR:-${REPO_ROOT}/build-linux}"
    local server_bin=""
    local candidate
    local prefix

    prefix="$(command_prefix)"
    if should_run_in_lima; then
        if repo_file_exists "${SERVER_SCRIPT}" || [[ -f "${SERVER_SCRIPT}" ]]; then
            send_repo_command "${target}" "${prefix}$(shell_quote "${SERVER_SCRIPT}")"
            return
        fi
    fi

    for candidate in \
        "${build_dir}/ivshmem-server" \
        "${build_dir}/contrib/ivshmem-server/ivshmem-server"; do
        if [[ -x "${candidate}" ]]; then
            server_bin="${candidate}"
            break
        fi
    done

    if repo_file_exists "${SERVER_SCRIPT}" && [[ -n "${server_bin}" ]]; then
        send_repo_command "${target}" "${prefix}$(shell_quote "${SERVER_SCRIPT}")"
        return
    fi

    send_message_pane "${target}" \
        "ivshmem server not launched. Expected binary under ${build_dir} (for example ${build_dir}/contrib/ivshmem-server/ivshmem-server). Build it first with scripts/heterogeneous-soc/guest-build-ivshmem-tools.sh in the Linux/Lima environment, or set BUILD_DIR to the directory that already contains ivshmem-server."
}

maybe_launch_arm() {
    local target="$1"
    local prefix

    prefix="$(command_prefix)"
    if should_run_in_lima; then
        if repo_file_exists "${ARM_RUN_SCRIPT}" || [[ -f "${ARM_RUN_SCRIPT}" ]]; then
            send_repo_command "${target}" "${prefix}$(shell_quote "${ARM_RUN_SCRIPT}")"
            return
        fi
    fi

    if [[ "${ARM_RUN_SCRIPT}" == "scripts/heterogeneous-soc/guest-run-arm-phase2.sh" ]]; then
        if [[ -z "${ARM_LINUX_IMAGE:-}" ]]; then
            send_message_pane "${target}" \
                "ARM Phase 2 not launched. Set ARM_LINUX_IMAGE to the ARM disk/ISO image, and if needed also ARM_TFA_QEMU_BIOS or ARM_TFA_BL1 plus ARM_TFA_FIP."
            return
        fi
    fi

    if repo_file_exists "${ARM_RUN_SCRIPT}" || [[ -f "${ARM_RUN_SCRIPT}" ]]; then
        send_repo_command "${target}" "${prefix}$(shell_quote "${ARM_RUN_SCRIPT}")"
        return
    fi

    send_message_pane "${target}" \
        "ARM runner not launched. Script not found: ${ARM_RUN_SCRIPT}"
}

maybe_launch_riscv() {
    local target="$1"
    local prefix
    local riscv_iso="${RISCV_ISO:-${HOME}/iso/alpine-standard-3.23.4-riscv64.iso}"

    prefix="$(command_prefix)"
    if should_run_in_lima; then
        if repo_file_exists "${RISCV_RUN_SCRIPT}" || [[ -f "${RISCV_RUN_SCRIPT}" ]]; then
            if [[ -n "${RISCV_KERNEL_CMDLINE}" ]]; then
                send_repo_command \
                    "${target}" \
                    "${prefix}PHASE3_QEMU_MACHINE=$(shell_quote "${PHASE3_QEMU_MACHINE}") PHASE3_QEMU_CPU=$(shell_quote "${PHASE3_QEMU_CPU}") RISCV_BOOT_MODE=$(shell_quote "${RISCV_BOOT_MODE}") RISCV_KERNEL_CMDLINE=$(shell_quote "${RISCV_KERNEL_CMDLINE}") $(shell_quote "${RISCV_RUN_SCRIPT}")"
            else
                send_repo_command \
                    "${target}" \
                    "${prefix}PHASE3_QEMU_MACHINE=$(shell_quote "${PHASE3_QEMU_MACHINE}") PHASE3_QEMU_CPU=$(shell_quote "${PHASE3_QEMU_CPU}") RISCV_BOOT_MODE=$(shell_quote "${RISCV_BOOT_MODE}") $(shell_quote "${RISCV_RUN_SCRIPT}")"
            fi
            return
        fi
    fi

    if [[ ! -f "${riscv_iso}" ]]; then
        send_message_pane "${target}" \
            "RISC-V runner not launched. Missing installer ISO: ${riscv_iso}. Fetch assets first with scripts/heterogeneous-soc/guest-fetch-images.sh in the Linux/Lima environment, or set RISCV_ISO to an existing image."
        return
    fi

    if repo_file_exists "${RISCV_RUN_SCRIPT}" || [[ -f "${RISCV_RUN_SCRIPT}" ]]; then
        if [[ -n "${RISCV_KERNEL_CMDLINE}" ]]; then
            send_repo_command \
                "${target}" \
                "${prefix}PHASE3_QEMU_MACHINE=$(shell_quote "${PHASE3_QEMU_MACHINE}") PHASE3_QEMU_CPU=$(shell_quote "${PHASE3_QEMU_CPU}") RISCV_BOOT_MODE=$(shell_quote "${RISCV_BOOT_MODE}") RISCV_KERNEL_CMDLINE=$(shell_quote "${RISCV_KERNEL_CMDLINE}") $(shell_quote "${RISCV_RUN_SCRIPT}")"
        else
            send_repo_command \
                "${target}" \
                "${prefix}PHASE3_QEMU_MACHINE=$(shell_quote "${PHASE3_QEMU_MACHINE}") PHASE3_QEMU_CPU=$(shell_quote "${PHASE3_QEMU_CPU}") RISCV_BOOT_MODE=$(shell_quote "${RISCV_BOOT_MODE}") $(shell_quote "${RISCV_RUN_SCRIPT}")"
        fi
        return
    fi

    send_message_pane "${target}" \
        "RISC-V runner not launched. Script not found: ${RISCV_RUN_SCRIPT}"
}

require_cmd tmux
require_repo_or_abs_file "${SERVER_SCRIPT}"
require_repo_or_abs_file "${ARM_RUN_SCRIPT}"
require_repo_or_abs_file "${RISCV_RUN_SCRIPT}"
require_repo_or_abs_file "${STOP_DEMO_GUESTS_SCRIPT}"
require_repo_or_abs_file "${AUTO_PREPARE_GUESTS_SCRIPT}"

TMUX_TERM_VALUE="$(select_tmux_term)"

if tmux has-session -t "${SESSION_NAME}" 2>/dev/null; then
    exec env TERM="${TMUX_TERM_VALUE}" tmux attach -t "${SESSION_NAME}"
fi

if should_stop_stale_demo_guests; then
    run_repo_command_now "$(shell_quote "${STOP_DEMO_GUESTS_SCRIPT}")"
fi

env TERM="${TMUX_TERM_VALUE}" tmux new-session -d -s "${SESSION_NAME}" -n demo

server_pane="$(env TERM="${TMUX_TERM_VALUE}" tmux display-message -p -t "${SESSION_NAME}:0.0" '#{pane_id}')"
arm_pane="$(env TERM="${TMUX_TERM_VALUE}" tmux split-window -h -P -F '#{pane_id}' -t "${server_pane}")"
riscv_pane="$(env TERM="${TMUX_TERM_VALUE}" tmux split-window -v -P -F '#{pane_id}' -t "${arm_pane}")"
control_pane="$(env TERM="${TMUX_TERM_VALUE}" tmux split-window -v -P -F '#{pane_id}' -t "${server_pane}")"

env TERM="${TMUX_TERM_VALUE}" tmux select-pane -t "${server_pane}" -T server
env TERM="${TMUX_TERM_VALUE}" tmux select-pane -t "${arm_pane}" -T arm
env TERM="${TMUX_TERM_VALUE}" tmux select-pane -t "${riscv_pane}" -T riscv
env TERM="${TMUX_TERM_VALUE}" tmux select-pane -t "${control_pane}" -T control

maybe_launch_server "${server_pane}"
maybe_launch_arm "${arm_pane}"
maybe_launch_riscv "${riscv_pane}"
if should_auto_prepare_guests; then
    send_local_repo_command "${control_pane}" "bash $(shell_quote "${AUTO_PREPARE_GUESTS_SCRIPT}")"
fi
send_message_pane "${control_pane}" "${CONTROL_MESSAGE}"

env TERM="${TMUX_TERM_VALUE}" tmux select-layout -t "${SESSION_NAME}:0" tiled
env TERM="${TMUX_TERM_VALUE}" tmux select-pane -t "${control_pane}"
exec env TERM="${TMUX_TERM_VALUE}" tmux attach -t "${SESSION_NAME}"
