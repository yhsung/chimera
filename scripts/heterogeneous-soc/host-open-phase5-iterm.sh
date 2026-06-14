#!/usr/bin/env bash
# host-open-phase5-iterm.sh
# Opens a new iTerm2 window, connects to the Lima VM, and launches the
# Phase 5 interactive tmux showcase.
set -euo pipefail

LIMA_CMD="limactl shell qemu-dev"
RUN_CMD="bash /Users/yhsung/chimera-src/scripts/heterogeneous-soc/guest-run-phase5-tmux.sh"

# Write a temp AppleScript as plain text (.applescript).
# Using 'current window' after create avoids the broken 'set X to (create ...)' pattern.
TMPSCRIPT="$(mktemp /tmp/phase5-iterm-XXXX.applescript)"
trap 'rm -f "${TMPSCRIPT}"' EXIT

cat > "${TMPSCRIPT}" << 'SCPT_EOF'
tell application "iTerm"
    activate
    create window with default profile
    delay 1
    tell current session of current window
        write text "LIMA_CMD_PLACEHOLDER"
        delay 5
        write text "RUN_CMD_PLACEHOLDER"
    end tell
end tell
SCPT_EOF

# Substitute the actual commands (single-quoted heredoc avoids shell expansion
# inside the doc; we patch afterward to keep quoting clean).
sed -i '' "s|LIMA_CMD_PLACEHOLDER|${LIMA_CMD}|g" "${TMPSCRIPT}"
sed -i '' "s|RUN_CMD_PLACEHOLDER|${RUN_CMD}|g"   "${TMPSCRIPT}"

osascript "${TMPSCRIPT}"
echo "iTerm2 window opened. Lima connecting → Phase 5 showcase in ~5 s."
echo "Pane navigation: Ctrl-b + arrow keys"
