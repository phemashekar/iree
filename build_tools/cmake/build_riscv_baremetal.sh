#!/bin/bash

# Copyright 2026 The IREE Authors
#
# Licensed under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Cross-compile the runtime for bare-metal RISC-V 64 using
# build_tools/cmake/generic_riscv64.cmake.
#
# Requires RISCV_TOOLCHAIN_ROOT pointing at a riscv64-unknown-elf clang
# toolchain (bin/clang, bin/llvm-ar, riscv64-unknown-elf/ newlib sysroot) and
# IREE_HOST_BIN_DIR with the precompiled host tools. The desired build
# directory can be passed as the first argument, otherwise
# IREE_TARGET_BUILD_DIR is used, defaulting to "build-riscv-baremetal".
# Designed for CI, but can be run manually. Expects to be run from the root
# of the IREE repository.

set -xeuo pipefail

BUILD_DIR="${1:-${IREE_TARGET_BUILD_DIR:-build-riscv-baremetal}}"
CMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE:-Release}"
IREE_HOST_BIN_DIR="$(realpath "${IREE_HOST_BIN_DIR:-build/install/bin}")"

source build_tools/cmake/setup_build.sh
source build_tools/cmake/setup_ccache.sh

# QEMU's virt machine (and most riscv64 boards) place RAM at 0x80000000,
# outside the default medlow code model's addressing range.
export CFLAGS="-mcmodel=medany ${CFLAGS:-}"
export CXXFLAGS="-mcmodel=medany ${CXXFLAGS:-}"
export ASMFLAGS="-mcmodel=medany ${ASMFLAGS:-}"

declare -a args
args=(
  "-G" "Ninja"
  "-B" "${BUILD_DIR}"

  "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}"
  "-DPython3_EXECUTABLE=${IREE_PYTHON3_EXECUTABLE}"

  # Cross compiling bare-metal RISC-V.
  "-DCMAKE_TOOLCHAIN_FILE=$(realpath build_tools/cmake/generic_riscv64.cmake)"
  "-DRISCV_TOOLCHAIN_ROOT=${RISCV_TOOLCHAIN_ROOT}"
  "-DIREE_BUILD_COMPILER=OFF"
  "-DIREE_BUILD_SAMPLES=OFF"
  "-DIREE_HOST_BIN_DIR=${IREE_HOST_BIN_DIR}"

  # Only the synchronous driver is buildable without an OS.
  "-DIREE_HAL_DRIVER_DEFAULTS=OFF"
  "-DIREE_HAL_DRIVER_LOCAL_SYNC=ON"
)

"${CMAKE_BIN}" "${args[@]}"
"${CMAKE_BIN}" --build "${BUILD_DIR}" -- -k 0

if (( IREE_USE_CCACHE == 1 )); then
  ccache --show-stats
fi
