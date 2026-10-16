#!/usr/bin/env bash
# dc.sh - docker compose helper for the flash-next stack.
#
# Usage:
#   ./dc.sh init                    copy *.example (skip override) + build model-download
#   ./dc.sh init:override           copy docker-compose.override.yml.example
#   ./dc.sh build [service ...]     build images via _build.yml (default: all)
#   ./dc.sh download                download weights (compose profile: init)
#   ./dc.sh up [service ...]        start the stack (default: flash-next)
#   ./dc.sh down [args ...]         stop the stack
#   ./dc.sh restart                 restart the flash-next container
#   ./dc.sh ps                      list containers
#   ./dc.sh logs [service ...]      tail logs (default: flash-next)
#   ./dc.sh run [service] [cmd ...] run a one-off container (default: flash-next)
#   ./dc.sh pull [service ...]      pull images (default: all)
#   ./dc.sh config                  print merged compose config
#
# Developers (Hub multi-arch publish; not needed for local run):
#   ./dc.sh push [service ...]      build+push via _push.yml (amd64 + arm64)
#
# First-time setup: ./dc.sh init && ./dc.sh init:override
# Then edit .env, ./dc.sh download, ./dc.sh up (pulls flash-next from Hub).
# Requires GUFO_MODEL (and optionally GUFO_MTP / GUFO_MMPROJ) in .env;
# see .env.example.
#
# GPU: host video/render group ids are auto-detected and passed to compose
# as VIDEO_GID / RENDER_GID; override with:
#   VIDEO_GID=44 RENDER_GID=999 ./dc.sh up

set -euo pipefail

cd "$(dirname "$0")"

COMPOSE="docker compose"
BUILD="-f _build.yml"
PUSH="-f _push.yml"

usage() {
    sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

# Compose file set: main yml required; override only when present (tsdproxy etc.).
compose_main() {
    if [ ! -f docker-compose.yml ]; then
        echo "Missing docker-compose.yml. Run: ./dc.sh init" >&2
        exit 1
    fi
    local args=(-f docker-compose.yml)
    if [ -f docker-compose.override.yml ]; then
        args+=(-f docker-compose.override.yml)
    fi
    printf '%s\n' "${args[@]}"
}

# Copy SRC → DEST unless DEST already exists.
cp_example() {
    local src="$1"
    local dest="$2"
    if [ ! -f "$src" ]; then
        echo "Missing example: $src" >&2
        return 1
    fi
    if [ -e "$dest" ]; then
        echo "==> skip $dest (already exists)"
        return 0
    fi
    cp "$src" "$dest"
    echo "==> created $dest from $src"
}

# Resolve host video/render group ids (flash-next needs them via group_add).
# Precedence: env override > device ownership > named groups > compose defaults.
export_gpu_gids() {
    if [ -z "${VIDEO_GID:-}" ]; then
        VIDEO_GID="$(stat -c %g /dev/dri/card0 2>/dev/null \
            || getent group video | cut -d: -f3 2>/dev/null \
            || true)"
    fi
    if [ -z "${RENDER_GID:-}" ]; then
        RENDER_GID="$(stat -c %g /dev/dri/renderD128 2>/dev/null \
            || getent group render | cut -d: -f3 2>/dev/null \
            || true)"
    fi
    [ -n "${VIDEO_GID:-}" ] || { echo "WARN: VIDEO_GID not detected; set it manually." >&2; }
    [ -n "${RENDER_GID:-}" ] || { echo "WARN: RENDER_GID not detected; set it manually." >&2; }
    export VIDEO_GID RENDER_GID
    echo "==> GPU gids: video=${VIDEO_GID:-?} render=${RENDER_GID:-?}"
}

# Format seconds as e.g. 45s, 2m 34s, 1h 05m 12s.
format_elapsed() {
    local total="${1:-0}"
    local h=$((total / 3600)) m=$(((total % 3600) / 60)) s=$((total % 60))
    if [ "$h" -gt 0 ]; then
        printf '%dh %02dm %02ds' "$h" "$m" "$s"
    elif [ "$m" -gt 0 ]; then
        printf '%dm %02ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

# Wait until the serve healthcheck reports the API is up.
wait_ready() {
    echo "Waiting for flash-next (model load can take up to 10 minutes)..."
    local -a main
    local started=$SECONDS
    mapfile -t main < <(compose_main)
    for _ in $(seq 1 120); do
        if docker compose "${main[@]}" exec -T flash-next \
            curl -sf http://127.0.0.1:8900/v1/models >/dev/null 2>&1; then
            echo "flash-next is ready ($(format_elapsed $((SECONDS - started))))."
            return 0
        fi
        sleep 10
    done
    echo "Timed out waiting for flash-next after $(format_elapsed $((SECONDS - started))). Check ./dc.sh logs" >&2
    return 1
}

cmd="${1:-}"
shift || true

case "${cmd}" in
    init)
        echo "==> Initialising from *.example (excluding override)"
        shopt -s nullglob
        for src in .env.example *.example; do
            case "$src" in
                *override*.example) continue ;;
            esac
            # .env.example → .env ; docker-compose.yml.example → docker-compose.yml
            cp_example "$src" "${src%.example}"
        done
        shopt -u nullglob
        # Newcomers: only the HF downloader is built locally; flash-next comes from Hub.
        echo "==> Building model-download only (flash-next is pulled from Hub on up)"
        ${COMPOSE} ${BUILD} build model-download
        echo "==> Done. Edit .env, then: ./dc.sh download && ./dc.sh up"
        echo "==> Optional tsdproxy: ./dc.sh init:override"
        ;;
    init:override)
        echo "==> Initialising docker-compose.override.yml"
        cp_example docker-compose.override.yml.example docker-compose.override.yml
        ;;
    build)
        services="${@:-}"
        echo "==> Building image(s): ${services:-all}"
        ${COMPOSE} ${BUILD} build ${services}
        ;;
    push)
        # Developers only: Hub multi-arch publish (linux/amd64 + linux/arm64).
        # Not needed for local init/build/download/up.
        services="${@:-}"
        echo "==> [developers] multi-arch build+push via _push.yml: ${services:-all}"
        ${COMPOSE} ${PUSH} build --no-cache --push ${services}
        ;;
    download)
        # model-download is behind compose profile "init" so plain `up` skips it.
        # Progress bars need a TTY (./dc.sh download in a real terminal).
        echo "==> Downloading model weights (profile init; idempotent)"
        mapfile -t MAIN < <(compose_main)
        if [ -t 1 ]; then
            echo "==> Progress bars enabled (interactive TTY)"
            ${COMPOSE} "${MAIN[@]}" --profile init run --rm model-download
        else
            echo "==> No TTY: bars may be limited. Tip: run from a terminal, or watch size with:"
            echo "    watch -n2 du -sh ${MODELS_DIR:-./models}/\$(basename \"\${HF_REPO:-model}\")"
            ${COMPOSE} "${MAIN[@]}" --profile init run --rm -T model-download
        fi
        ;;
    up)
        services="${@:-flash-next}"
        export_gpu_gids
        echo "==> Starting: ${services}"
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" up -d ${services}
        wait_ready
        ;;
    down)
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" down "$@"
        ;;
    restart)
        export_gpu_gids
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" up -d --force-recreate flash-next
        wait_ready
        ;;
    ps)
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" ps "$@"
        ;;
    logs)
        services="${@:-flash-next}"
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" logs -f --tail=100 ${services}
        ;;
    run)
        service="${1:-flash-next}"
        shift || true
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" run --rm "${service}" "$@"
        ;;
    pull)
        services="${@:-}"
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" pull ${services}
        ;;
    config)
        mapfile -t MAIN < <(compose_main)
        ${COMPOSE} "${MAIN[@]}" config
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: ${cmd}" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
esac
