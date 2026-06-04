#!/usr/bin/env bash
# Wrapper that forces Lima-correct env vars before calling the harness.
# Lima's ~/.bashrc may pre-export CHIMERA_ROOT/FREERTOS_DEMO_ELF/BUILD_DIR to
# ~/chimera-src paths from a previous build session.  We override them all here.
set -euo pipefail

REPO_ROOT=/Users/yhsung/dev-projects/chimera

export CHIMERA_ROOT="${REPO_ROOT}"
export BUILD_DIR=/home/yhsung.guest/chimera-build-linux
export FREERTOS_DEMO_ELF="${REPO_ROOT}/contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf"
export HARNESS_TIMEOUT="${HARNESS_TIMEOUT:-300}"
export HARNESS_LOG_DIR=/home/yhsung.guest/harness-logs
export SKIP_BUILD=1

exec "${REPO_ROOT}/scripts/heterogeneous-soc/run-freertos-harness.sh" "$@"
