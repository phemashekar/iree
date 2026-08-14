#!/bin/bash

# Copyright 2026 The IREE Authors
#
# Licensed under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Builds and runs a single-op IREE workload on bare-metal riscv64 under
# qemu-system-riscv64 (-machine virt, no OS, semihosted I/O).
#
# Required environment:
#   RISCV_TOOLCHAIN_ROOT      riscv64-unknown-elf clang toolchain used for the
#                             runtime build (compiles the runner).
#   RISCV_LINK_TOOLCHAIN_ROOT riscv-none-elf gcc toolchain whose newlib is
#                             built -mcmodel=medany (links the firmware,
#                             provides crt0 + semihost.specs).
#   QEMU_BIN                  qemu-system-riscv64 binary.
#   IREE_HOST_BIN_DIR         host tools (iree-compile, iree-c-embed-data).
#   IREE_TARGET_BUILD_DIR     runtime build from build_riscv_baremetal.sh.
#
# Optional:
#   BACKEND=llvm-cpu (default) | vmvx
#     llvm-cpu: kernels as RISC-V machine code in an embedded ELF, loaded via
#               the hal_loader module (inline-dynamic execution model).
#     vmvx:     kernels as portable VM bytecode (inline-static + vmvx-inline);
#               no loader involved.
#
# Expects to be run from the root of the IREE repository.

set -xeuo pipefail

BACKEND="${BACKEND:-llvm-cpu}"
IREE_TARGET_BUILD_DIR="${IREE_TARGET_BUILD_DIR:-build-riscv-baremetal}"
IREE_HOST_BIN_DIR="$(realpath "${IREE_HOST_BIN_DIR}")"
SRC_DIR="$(realpath build_tools/riscv/baremetal)"
OUT_DIR="$(realpath "${IREE_TARGET_BUILD_DIR}")/baremetal_smoketest_${BACKEND}"
mkdir -p "${OUT_DIR}"

# 1. Compile the module for the inline HAL (no device on bare metal).
if [[ "${BACKEND}" == "llvm-cpu" ]]; then
  "${IREE_HOST_BIN_DIR}/iree-compile" \
    --iree-execution-model=inline-dynamic \
    --iree-hal-target-device=local \
    --iree-hal-local-target-device-backends=llvm-cpu \
    --iree-llvmcpu-target-triple=riscv64-unknown-unknown-elf \
    --iree-llvmcpu-target-cpu-features=+m,+a,+f,+d,+c \
    "${SRC_DIR}/simple_mul.mlir" -o "${OUT_DIR}/simple_mul.vmfb"
  BACKEND_DEFS=(-DUSE_LLVMCPU=1)
else
  "${IREE_HOST_BIN_DIR}/iree-compile" \
    --iree-execution-model=inline-static \
    --iree-hal-target-device=local \
    --iree-hal-local-target-device-backends=vmvx-inline \
    "${SRC_DIR}/simple_mul.mlir" -o "${OUT_DIR}/simple_mul.vmfb"
  BACKEND_DEFS=()
fi

# 2. Embed the vmfb as a C array (no filesystem on bare metal).
"${IREE_HOST_BIN_DIR}/iree-c-embed-data" \
  --output_header="${OUT_DIR}/simple_mul_module.h" \
  --output_impl="${OUT_DIR}/simple_mul_module.c" \
  --identifier=simple_mul_module --flatten "${OUT_DIR}/simple_mul.vmfb"

# 3. Compile the runner with the same flags as generic_riscv64.cmake.
for src in "${SRC_DIR}/runner.c" "${OUT_DIR}/simple_mul_module.c"; do
  "${RISCV_TOOLCHAIN_ROOT}/bin/clang" \
    --sysroot="${RISCV_TOOLCHAIN_ROOT}/riscv64-unknown-elf" \
    -march=rv64i2p1ma2p1f2p2d2p2c2p0 -mabi=lp64d -mcmodel=medany \
    ${BACKEND_DEFS[@]+"${BACKEND_DEFS[@]}"} \
    -DIREE_PLATFORM_GENERIC=1 -DIREE_FILE_IO_ENABLE=0 \
    "-DIREE_TIME_NOW_FN={ return 0; }" \
    -DIREE_DEVICE_SIZE_T=uint64_t -DPRIdsz=PRIu64 \
    -DIREE_SYNCHRONIZATION_DISABLE_UNSAFE=1 \
    -DIREE_ALLOCATOR_SYSTEM_CTL=iree_allocator_libc_ctl \
    -Iruntime/src -I"${IREE_TARGET_BUILD_DIR}/runtime/src" \
    -Ithird_party/flatcc/include -I"${OUT_DIR}" \
    -O2 -Wno-pointer-sign -c "${src}" -o "${OUT_DIR}/$(basename "${src%.c}").o"
done

# 4. Link the firmware. start.S sets the stack pointer and enables the FPU;
#    text is placed at the virt machine's RAM base.
"${RISCV_LINK_TOOLCHAIN_ROOT}/bin/riscv-none-elf-gcc" \
  --specs=semihost.specs -march=rv64imafdc -mabi=lp64d -mcmodel=medany \
  -Wl,-Ttext-segment=0x80000000 -Wl,--defsym=__stack_top=0x88000000 -Wl,-e,_enter \
  "${SRC_DIR}/start.S" "${OUT_DIR}/runner.o" "${OUT_DIR}/simple_mul_module.o" \
  -Wl,--start-group $(find "${IREE_TARGET_BUILD_DIR}" -name '*.a' | tr '\n' ' ') -Wl,--end-group \
  -lm -o "${OUT_DIR}/runner.elf"

# 5. Run. The ELF is passed as -bios so QEMU jumps to its entry point;
#    semihosting propagates the exit code.
timeout 120 "${QEMU_BIN}" -machine virt -m 512M -nographic -semihosting \
  -bios "${OUT_DIR}/runner.elf" | tee "${OUT_DIR}/run.log"
grep -q "PASS: single-op inference on bare-metal riscv64" "${OUT_DIR}/run.log"
