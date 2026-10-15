#!/usr/bin/env bash
# dc.sh - docker compose helper for the flash-next stack.
#
# Usage:
#   ./dc.sh build [service ...]     build images via _build.yml (default: all)
#   ./dc.sh download                download model weights (model-download)
#   ./dc.sh up [service ...]        start the stack (default: flash-next)
#   ./dc.sh down [args ...]         stop the stack
#   ./dc.sh restart                 restart the flash-next container
#   ./dc.sh ps                        list containers
#   ./dc.sh logs [service ...]      tail logs (default: flash-next)
#   ./dc.sh run [service] [cmd ...] run a one-off container (default: flash-next)
#   ./dc.sh pull [service ...]      pull images (default: all)
#   ./dc.sh config                  print merged compose config
#
# Requires GUFO_MODEL (and optionally GUFO_MTP / GUFO_MMPROJ) in .env;
# see .env.example.
#
# GPU: host video/render group ids are auto-detected and passed to compose
# as VIDEO_GID / RENDER_GID; override with:
#   VIDEO_GID=44 RENDER_GID=999 ./dc.sh up

set -euo pipefail

cd "$(dirname "$0")"

COMPOSE="docker compose"
MAIN="-f docker-compose.yml -f docker-compose.override.yml"
BUILD="-f _build.yml"

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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

# Wait until the serve healthcheck reports the API is up.
wait_ready() {
    echo "Waiting for flash-next (model load can take up to 10 minutes)..."
    for _ in $(seq 1 120); do
        if docker compose ${MAIN} exec -T flash-next \
            curl -sf http://127.0.0.1:8900/v1/models >/dev/null 2>&1; then
            echo "flash-next is ready."
            return 0
        fi
        sleep 10
    done
    echo "Timed out waiting for flash-next. Check ./dc.sh logs" >&2
    return 1
}

cmd="${1:-}"
shift || true

case "${cmd}" in
    build)
        services="${@:-}"
        echo "==> Building image(s): ${services:-all}"
        ${COMPOSE} ${BUILD} build ${services}
        ;;
    download)
        echo "==> Downloading model weights (idempotent, re-run safe)"
        ${COMPOSE} ${MAIN} run --rm model-download
        ;;
    up)
        services="${@:-flash-next}"
        export_gpu_gids
        echo "==> Starting: ${services}"
        ${COMPOSE} ${MAIN} up -d ${services}
        wait_ready
        ;;
    down)
        ${COMPOSE} ${MAIN} down "$@"
        ;;
    restart)
        export_gpu_gids
        ${COMPOSE} ${MAIN} up -d --force-recreate flash-next
        wait_ready
        ;;
    ps)
        ${COMPOSE} ${MAIN} ps "$@"
        ;;
    logs)
        services="${@:-flash-next}"
        ${COMPOSE} ${MAIN} logs -f --tail=100 ${services}
        ;;
    run)
        service="${1:-flash-next}"
        shift || true
        ${COMPOSE} ${MAIN} run --rm "${service}" "$@"
        ;;
    pull)
        services="${@:-}"
        ${COMPOSE} ${MAIN} pull ${services}
        ;;
    config)
        ${COMPOSE} ${MAIN} config
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
