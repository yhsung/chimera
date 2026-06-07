#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

command -v brew >/dev/null 2>&1 || die "Homebrew is required on the macOS host"
command -v limactl >/dev/null 2>&1 || brew install lima

if limactl list | awk '{print $1}' | grep -qx "${LIMA_NAME}"; then
    echo "Lima VM ${LIMA_NAME} already exists"
    limactl start "${LIMA_NAME}" 2>/dev/null || true
else
    limactl start --name="${LIMA_NAME}" --vm-type=vz \
        --cpus="${LIMA_CPUS}" --memory="${LIMA_MEMORY}" --disk="${LIMA_DISK}" \
        template://ubuntu-lts
fi

if [[ "${VM_SOURCE_DIR}" != "${CHIMERA_ROOT}" ]]; then
    echo "Deploying chimera source tree to ${VM_SOURCE_DIR} ..."
    prepare_vm_source_tree
    echo "Source tree deployed."
else
    echo "Deploying chimera source tree to ~/chimera-src ..."
    mkdir -p "${HOME}/chimera-src"
    rsync -a \
        --exclude '.git/' \
        --exclude 'build-linux/' \
        --exclude '.DS_Store' \
        "${CHIMERA_ROOT}/" "${HOME}/chimera-src/"
    echo "Source tree deployed to ~/chimera-src"
fi

# ── Install chimera-ssh / chimera-keyinject on the macOS host ──────────────────
# Appends shell functions to ~/.zshrc so the user can SSH into guests from
# macOS without remembering Lima's dynamic port.
INSTALL_MARKER="# chimera-ssh helpers (added by host-install-lima-host.sh)"
if grep -qF "${INSTALL_MARKER}" "${HOME}/.zshrc" 2>/dev/null; then
    echo "chimera-ssh / chimera-keyinject already installed in ~/.zshrc"
else
    echo "Installing chimera-ssh / chimera-keyinject into ~/.zshrc ..."

    # Resolve the repo scripts dir relative to this script
    REPO_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

    cat >> "${HOME}/.zshrc" <<FUNCTIONS

${INSTALL_MARKER}
chimera-ssh() {
  local ssh_config="\${HOME}/.lima/${LIMA_NAME}/ssh.config"
  [[ -f "\${ssh_config}" ]] || { echo "Lima VM not running (no ssh.config)"; return 1; }
  ssh -F "\${ssh_config}" \\
      -o ProxyCommand="ssh -F '\${ssh_config}' -W %h:%p lima-${LIMA_NAME}" \\
      -o PasswordAuthentication=no \\
      -o StrictHostKeyChecking=no \\
      -o UserKnownHostsFile=/dev/null \\
      "\$@"
}
chimera-keyinject() {
  local vm_script_dir="\${VM_SCRIPT_DIR:-\${HOME}/chimera-src/scripts/heterogeneous-soc}"
  echo "Injecting SSH public key into Chimera guests..."
  echo "  (QEMU must not be running)"
  echo ""
  limactl shell ${LIMA_NAME} -- bash "\${vm_script_dir}/guest-install-ssh-keys-to-guests.sh"
}
FUNCTIONS
    echo "chimera-ssh / chimera-keyinject installed. Restart your shell or source ~/.zshrc"
fi

echo ""
echo "Lima VM ready. Enter it with:"
echo "  limactl shell ${LIMA_NAME}"
echo ""
echo "After starting the showcase, connect to guests from macOS:"
echo "  chimera-ssh root@debian-arm64.local"
