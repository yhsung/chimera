#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

SESSION_NAME="${SESSION_NAME:-heterogeneous-soc}"
TARGET_TITLE="${1:-}"
shift || true

[[ -n "${TARGET_TITLE}" ]] || {
    echo "usage: $0 <pane-title> <command...>" >&2
    exit 1
}

[[ $# -gt 0 ]] || {
    echo "usage: $0 <pane-title> <command...>" >&2
    exit 1
}

pane_id="$(
    tmux list-panes -a -t "${SESSION_NAME}" -F '#{pane_title} #{pane_id}' \
    | awk -v title="${TARGET_TITLE}" '$1 == title { print $2; exit }'
)"

[[ -n "${pane_id}" ]] || {
    echo "error: no pane titled '${TARGET_TITLE}' found in tmux session '${SESSION_NAME}'" >&2
    exit 1
}

tmux send-keys -t "${pane_id}" "$*" C-m
