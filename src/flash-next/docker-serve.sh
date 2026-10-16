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
MMPROJ=${GUFO_MMPROJ:-}

export LD_LIBRARY_PATH="${ROCM_PATH:-/opt/rocm}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GUFO_PREFILL_TILE=${GUFO_PREFILL_TILE:-8192}

NPU_ENV=()
if [ "${GUFO_NPU:-1}" != 0 ] && [ -e /dev/accel/accel0 ] && [ -d "$GUFO_DIR/tools/npu" ]; then
  xrt_dir=${XRT_DIR:-/opt/xilinx/xrt}
  # PPA XRT puts xrt-smi on PATH (/usr/bin); classic installs use $XRT_DIR/bin.
  xrt_smi=""
  if [ -x "${xrt_dir}/bin/xrt-smi" ]; then
    xrt_smi="${xrt_dir}/bin/xrt-smi"
  elif command -v xrt-smi >/dev/null 2>&1; then
    xrt_smi="$(command -v xrt-smi)"
  fi

  # Optional: set NPU power mode before the turbo guard (resets on driver load).
  # GUFO_NPU_PMODE=performance|balanced|default|powersaver  (turbo refused)
  pmode=${GUFO_NPU_PMODE:-}
  if [ -n "$pmode" ]; then
    if [ -z "$xrt_smi" ]; then
      echo "WARNING: GUFO_NPU_PMODE=$pmode set but xrt-smi not found; leaving mode unchanged." >&2
    else
      case "$pmode" in
        default|powersaver|balanced|performance)
          if ! "$xrt_smi" configure --pmode "$pmode" >/dev/null; then
            echo "WARNING: failed to set NPU power mode to $pmode." >&2
          else
            echo "NPU power mode set to $pmode." >&2
          fi
          ;;
        turbo)
          echo "WARNING: GUFO_NPU_PMODE=turbo is unsupported (gufo skips NPU); leaving mode unchanged." >&2
          ;;
        *)
          echo "WARNING: unknown GUFO_NPU_PMODE=$pmode (use default|powersaver|balanced|performance)." >&2
          ;;
      esac
    fi
  fi

  if ! "$GUFO_DIR/tools/npu/fabric-clock.sh" status > /dev/null 2>&1; then
    echo "WARNING: GPU fabric clock not held: running without the NPU." >&2
  elif [ -n "$xrt_smi" ] && "$xrt_smi" examine -r platform 2>&1 | grep -qi "power mode *: turbo"; then
    echo "WARNING: NPU is in turbo mode: running without the NPU." >&2
  else
    NPU_ENV=(GUFO_NPU_DIR="$GUFO_DIR/tools/npu")
    if [ -d "${xrt_dir}/lib" ]; then
      export LD_LIBRARY_PATH="${xrt_dir}/lib:${LD_LIBRARY_PATH}"
    fi
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

if [ -n "$MMPROJ" ] && [ -f "$MMPROJ" ]; then
  VISION=(--mmproj "$MMPROJ")
else
  echo "WARNING: no vision projector (set GUFO_MMPROJ): image inputs disabled." >&2
  VISION=()
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
  "${VISION[@]}" \
  --cache-disk "$CACHE_DIR" \
  --cache-disk-bytes "$CACHE_BYTES" \
  --cache-disk-staging-bytes "${GUFO_CACHE_STAGING_BYTES:-4294967296}" \
  --cache-ram-bytes "${GUFO_CACHE_RAM_BYTES:-3758096384}" \
  --reasoning-effort "${GUFO_EFFORT:-low}" \
  --log-progress \
  "$@" 2>&1 | tee -a "$LOG"
