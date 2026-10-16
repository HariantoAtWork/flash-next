#!/usr/bin/env sh
# Download HF_MODEL_FILES (+ optional MTP / mmproj) with visible progress bars.
set -eu

# Force bars on even if an AI-agent env var leaks into the container.
export HF_HUB_DISABLE_PROGRESS_BARS=0
export PYTHONUNBUFFERED=1

: "${HF_REPO:?set HF_REPO}"
: "${HF_MODEL_FILES:?set HF_MODEL_FILES}"
HF_MODEL_REVISION=${HF_MODEL_REVISION:-main}
HF_MTP_MODEL_REVISION=${HF_MTP_MODEL_REVISION:-$HF_MODEL_REVISION}
HF_MMPROJ_MODEL_REVISION=${HF_MMPROJ_MODEL_REVISION:-$HF_MODEL_REVISION}

dest="/workspace/models/$(basename "$HF_REPO")"
mkdir -p "$dest"

# Run `hf` under a PTY so tqdm/xet bars render even without `docker -t`.
hf_progress() {
	python - "$@" <<'PY'
import os, pty, sys

os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "0"
argv = ["hf", *sys.argv[1:]]
status = pty.spawn(argv)
if os.WIFEXITED(status):
    raise SystemExit(os.WEXITSTATUS(status))
if os.WIFSIGNALED(status):
    raise SystemExit(128 + os.WTERMSIG(status))
raise SystemExit(1)
PY
}

# Build ordered file list (shards, then optional MTP / mmproj).
# shellcheck disable=SC2086
set -- $HF_MODEL_FILES
if [ -n "${HF_MTP_MODEL:-}" ]; then
	set -- "$@" "$HF_MTP_MODEL"
fi
if [ -n "${HF_MMPROJ_MODEL:-}" ]; then
	set -- "$@" "$HF_MMPROJ_MODEL"
fi

total=$#
i=0
echo "==> Downloading $total file(s) from $HF_REPO → $dest"

for file in "$@"; do
	i=$((i + 1))
	# MTP / mmproj may use their own revision; shards use HF_MODEL_REVISION.
	rev=$HF_MODEL_REVISION
	case "$file" in
	"${HF_MTP_MODEL:-__none__}") rev=$HF_MTP_MODEL_REVISION ;;
	"${HF_MMPROJ_MODEL:-__none__}") rev=$HF_MMPROJ_MODEL_REVISION ;;
	esac
	echo
	echo "==> [$i/$total] $file"
	hf_progress download "$HF_REPO" "$file" \
		--revision "$rev" \
		--repo-type model \
		--local-dir "$dest" \
		--format human
done

echo
echo "==> Done. Files under $dest"
