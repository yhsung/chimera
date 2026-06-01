#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

prepare_vm_source_tree

make -C "${PINGPONG_DIR}" clean all
