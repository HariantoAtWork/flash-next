#!/usr/bin/env bash
# Serve wrapper aligned with /opt/gufo/scripts/run-gufo.sh but only flags this gufo build accepts.
set -euo pipefail

GUFO_DIR="${GUFO_DIR:-/opt/gufo}"
GUFO_BIN="${GUFO_BIN:-${GUFO_DIR}/build/release/gufo}"

: "${GUFO_MODEL:?set GUFO_MODEL to the first UD-IQ4_XS shard}"
[ -f "$GUFO_MODEL" ] || { echo "model not found: $GUFO_MODEL" >&2; exit 1; }

PORT=${PORT:-8900}
JOBS=${JOBS:-2}
CONTEXT=${GUFO_CONTEXT:-131072}
MTP=${GUFO_MTP:-}

export LD_LIBRARY_PATH="${ROCM_PATH:-/opt/rocm}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GUFO_PREFILL_TILE=${GUFO_PREFILL_TILE:-8192}

NPU_ENV=()
if [ "${GUFO_NPU:-1}" != 0 ] && [ -e /dev/accel/accel0 ] && [ -d "$GUFO_DIR/tools/npu" ]; then
  xrt_dir=${XRT_DIR:-/opt/xilinx/xrt}
  if ! "$GUFO_DIR/tools/npu/fabric-clock.sh" status > /dev/null 2>&1; then
    echo "WARNING: GPU fabric clock not held: running without the NPU." >&2
  elif [ -x "${xrt_dir}/bin/xrt-smi" ] && "${xrt_dir}/bin/xrt-smi" examine -r platform 2>&1 | grep -qi "power mode *: turbo"; then
    echo "WARNING: NPU is in turbo mode: running without the NPU." >&2
  else
    NPU_ENV=(GUFO_NPU_DIR="$GUFO_DIR/tools/npu")
    export LD_LIBRARY_PATH="${xrt_dir}/lib:${LD_LIBRARY_PATH}"
  fi
fi

CACHE_DIR=${GUFO_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/gufo/snapshots}
CACHE_BYTES=${GUFO_CACHE_BYTES:-34359738368}
LOG=${GUFO_LOG:-${XDG_CACHE_HOME:-$HOME/.cache}/gufo/gufo.log}
mkdir -p "$CACHE_DIR" "$(dirname "$LOG")"
[ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 104857600 ] && mv -f "$LOG" "$LOG.1"

if [ -n "$MTP" ] && [ -f "$MTP" ]; then
  SPEC=(--speculative mtp --mtp-model "$MTP")
else
  echo "WARNING: no MTP sidecar (set GUFO_MTP): running without speculative decoding." >&2
  SPEC=()
fi

exec env "${NPU_ENV[@]}" "$GUFO_BIN" serve llm \
  -m "$GUFO_MODEL" \
  --host 0.0.0.0 \
  --served-model-name "Qwen3.8 Flash Next" \
  --port "$PORT" \
  -c "$CONTEXT" \
  -n 16384 \
  -j "$JOBS" \
  --prefill-chunk 4096 \
  "${SPEC[@]}" \
  --cache-disk "$CACHE_DIR" \
  --cache-disk-bytes "$CACHE_BYTES" \
  --cache-disk-staging-bytes "${GUFO_CACHE_STAGING_BYTES:-4294967296}" \
  --cache-ram-bytes "${GUFO_CACHE_RAM_BYTES:-3758096384}" \
  --reasoning-effort "${GUFO_EFFORT:-low}" \
  --log-progress \
  "$@" 2>&1 | tee -a "$LOG"
