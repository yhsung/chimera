#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

SECURE_STACK_ROOT="${SECURE_STACK_ROOT:-${HOME}/heterogeneous-soc-secure-stack}"
TFA_DIR="${TFA_DIR:-${SECURE_STACK_ROOT}/trusted-firmware-a}"
HAFNIUM_DIR="${HAFNIUM_DIR:-${SECURE_STACK_ROOT}/hafnium}"
OPTEE_DIR="${OPTEE_DIR:-${SECURE_STACK_ROOT}/optee_os}"
TFA_REMOTE="${TFA_REMOTE:-https://git.trustedfirmware.org/TF-A/trusted-firmware-a.git}"
HAFNIUM_REMOTE="${HAFNIUM_REMOTE:-https://git.trustedfirmware.org/hafnium/hafnium.git}"
OPTEE_REMOTE="${OPTEE_REMOTE:-https://github.com/OP-TEE/optee_os.git}"
OPTEE_REVISION="${OPTEE_REVISION:-4.9.0}"

mkdir -p "${SECURE_STACK_ROOT}"

if [[ ! -d "${TFA_DIR}/.git" ]]; then
    git clone --depth 1 "${TFA_REMOTE}" "${TFA_DIR}"
else
    git -C "${TFA_DIR}" pull --ff-only
fi

if [[ ! -d "${HAFNIUM_DIR}/.git" ]]; then
    git clone --depth 1 --recurse-submodules "${HAFNIUM_REMOTE}" "${HAFNIUM_DIR}"
else
    git -C "${HAFNIUM_DIR}" pull --ff-only
    git -C "${HAFNIUM_DIR}" submodule update --init --recursive
fi

if [[ ! -d "${OPTEE_DIR}/.git" ]]; then
    git clone --depth 1 --branch "${OPTEE_REVISION}" "${OPTEE_REMOTE}" "${OPTEE_DIR}"
else
    git -C "${OPTEE_DIR}" fetch --tags --depth 1 origin "${OPTEE_REVISION}"
    git -C "${OPTEE_DIR}" checkout --detach FETCH_HEAD
fi
