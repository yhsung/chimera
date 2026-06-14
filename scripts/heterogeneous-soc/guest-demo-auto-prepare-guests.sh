#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_NAME="${SESSION_NAME:-heterogeneous-soc}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-240}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-2}"
POST_LOGIN_WAIT_SECONDS="${POST_LOGIN_WAIT_SECONDS:-2}"

mount_cmd="busybox mkdir -p /mnt/pingpong && (busybox grep -q '^pingpong /mnt/pingpong 9p ' /etc/fstab || echo 'pingpong /mnt/pingpong 9p trans=virtio,version=9p2000.L 0 0' >> /etc/fstab) && (mount /mnt/pingpong 2>/dev/null || busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong) && busybox ls /mnt/pingpong"

pane_id_for_title() {
    local target_title="$1"

    tmux list-panes -a -t "${SESSION_NAME}" -F '#{pane_title} #{pane_id}' \
        | awk -v title="${target_title}" '$1 == title { print $2; exit }'
}

capture_pane() {
    local pane_id="$1"

    tmux capture-pane -p -t "${pane_id}" | tail -n 80
}

guest_state() {
    local text="$1"

    if grep -Eq 'localhost login:| login:$' <<<"${text}"; then
        printf 'login\n'
        return
    fi

    if grep -Eq '(^|[^[:alnum:]_/-])(localhost:[^[:space:]]*#|/[^[:space:]]*#|~[^[:space:]]*#)' <<<"${text}"; then
        printf 'shell\n'
        return
    fi

    printf 'booting\n'
}

wait_for_guest_ready() {
    local title="$1"
    local pane_id="$2"
    local deadline
    local text
    local state

    deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        text="$(capture_pane "${pane_id}")"
        state="$(guest_state "${text}")"
        if [[ "${state}" != "booting" ]]; then
            printf '%s\n' "${state}"
            return 0
        fi
        sleep "${POLL_INTERVAL_SECONDS}"
    done

    echo "Timed out waiting for ${title} guest to reach a login prompt or shell." >&2
    return 1
}

login_if_needed() {
    local title="$1"
    local pane_id="$2"
    local state

    state="$(wait_for_guest_ready "${title}" "${pane_id}")"
    case "${state}" in
        shell)
            echo "${title}: shell prompt detected."
            ;;
        login)
            echo "${title}: login prompt detected, sending root."
            bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" "${title}" "root"
            ;;
        *)
            echo "Unexpected guest state for ${title}: ${state}" >&2
            return 1
            ;;
    esac
}

main() {
    local arm_pane
    local riscv_pane

    arm_pane="$(pane_id_for_title arm)"
    riscv_pane="$(pane_id_for_title riscv)"

    [[ -n "${arm_pane}" ]] || {
        echo "ARM pane not found in tmux session '${SESSION_NAME}'." >&2
        exit 1
    }
    [[ -n "${riscv_pane}" ]] || {
        echo "RISC-V pane not found in tmux session '${SESSION_NAME}'." >&2
        exit 1
    }

    login_if_needed arm "${arm_pane}"
    login_if_needed riscv "${riscv_pane}"

    sleep "${POST_LOGIN_WAIT_SECONDS}"

    echo "Mounting pingpong share in both guests."
    bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" arm "${mount_cmd}"
    bash "${SCRIPT_DIR}/guest-demo-send-to-pane.sh" riscv "${mount_cmd}"
}

main "$@"
