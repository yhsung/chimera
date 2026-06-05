#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

command -v brew >/dev/null 2>&1 || die "Homebrew is required on the macOS host"
command -v limactl >/dev/null 2>&1 || brew install lima

if limactl list | awk '{print $1}' | grep -qx "${LIMA_NAME}"; then
    echo "Lima VM ${LIMA_NAME} already exists"
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
    echo "Repo is under \$HOME — Lima can access it directly at ${CHIMERA_ROOT}"
fi

echo "Lima VM ready. Enter it with:"
echo "  limactl shell ${LIMA_NAME}"
