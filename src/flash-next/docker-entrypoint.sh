#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/rocm/bin:${GUFO_DIR}/build/release:${PATH}"
xrt_lib="/usr/lib/x86_64-linux-gnu"
xrt_dir="${XRT_DIR:-/opt/xilinx/xrt}"
if [[ -d "${xrt_dir}/lib" ]]; then
  xrt_lib="${xrt_dir}/lib:${xrt_lib}"
fi
export LD_LIBRARY_PATH="${ROCM_PATH}/lib:${xrt_lib}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

if [[ "${1:-}" == "serve" ]]; then
  shift
  exec "${GUFO_DIR}/scripts/run-gufo.sh" "$@"
fi

if [[ "${1:-}" == "gufo" ]]; then
  shift
  exec "${GUFO_BIN}" "$@"
fi

if [[ "${1:-}" == "bench" ]]; then
  shift
  exec "${GUFO_BIN}" bench "$@"
fi

exec "$@"
