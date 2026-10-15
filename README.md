# flash-next

Docker stack for serving **Qwen3.8 Flash-Next** (UD-IQ4_XS GGUF + optional MTP + mmproj for images) via [gufo](https://github.com/mikealanni/gufo) on AMD ROCm / Radeon GPUs.

## Requirements

- Docker with Compose v2
- AMD GPU with ROCm (`/dev/kfd`, `/dev/dri`)
- Host membership in the `video` / `render` groups (gids are auto-detected by `dc.sh`)
- Hugging Face token with access to the model repo (set in `.env`)

## Quick start

**Newcomers** — `init` copies local config and builds only `model-download`. The
heavy `flash-next` image is pulled from Docker Hub (`harianto/flash-next`) on `up`:

```bash
./dc.sh init                 # *.example → local files + build model-download
./dc.sh init:override        # optional: tsdproxy override
```

Edit `.env`: set `HF_TOKEN`, and confirm `GUFO_MODEL` / `GUFO_MTP` / `GUFO_MMPROJ`.

```bash
./dc.sh download             # fetch GGUF shards + MTP + mmproj into ./models
./dc.sh up                   # pulls harianto/flash-next from Hub if missing, then starts
```

Or copy the examples yourself (then build the downloader separately):

```bash
cp .env.example .env
cp docker-compose.yml.example docker-compose.yml
cp docker-compose.override.yml.example docker-compose.override.yml   # optional
./dc.sh build model-download
./dc.sh download
./dc.sh up
```

Developers who change the gufo image still run `./dc.sh build` (or `./dc.sh build flash-next`) instead of relying on Hub.

API listens on port `8900` by default (`FLASH_NEXT_PORT`).

```bash
curl -s http://127.0.0.1:8900/v1/models
```

## `dc.sh` commands

| Command | What it does |
| --- | --- |
| `init` | Copy `*.example` → local files (skips override; never overwrites) + build `model-download` |
| `init:override` | Copy `docker-compose.override.yml.example` |
| `build [service…]` | Build via `_build.yml` (newcomers: `model-download` only; full build is for developers) |
| `download` | Run `model-download` via compose profile `init` (idempotent; not part of plain `up`) |
| `up [service…]` | Start stack (default: `flash-next`); auto-sets `VIDEO_GID` / `RENDER_GID` |
| `down` | Stop stack |
| `restart` | Recreate `flash-next` with current gids |
| `ps` / `logs` / `run` / `pull` / `config` | Thin wrappers around Compose |
| `push [service…]` | **Developers:** multi-arch build+push via `_push.yml` (amd64 + arm64) |

GPU group override:

```bash
VIDEO_GID=44 RENDER_GID=999 ./dc.sh up
```

## Layout

| Path | Role |
| --- | --- |
| `dc.sh` | Entry point for setup and day-to-day Compose |
| `docker-compose.yml.example` | Runtime services (`flash-next`, `fabric-clock`, `model-download`) |
| `docker-compose.override.yml.example` | Optional tsdproxy network / labels + Prometheus/Grafana |
| `_build.yml` | Local image builds (`harianto/flash-next`, `harianto/hf-downloader`) |
| `_push.yml` | Developer Hub multi-arch publish (amd64 + arm64); use `./dc.sh push` |
| `.env.example` | Tokens, model paths, tags, context window, NPU flag, Grafana admin |
| `src/flash-next/` | Gufo image Dockerfile + serve scripts |
| `src/model-download/` | Hugging Face downloader image |
| `src/prometheus/` | Prometheus scrape config (gufo `/metrics`) |
| `src/grafana/` | Grafana provisioning + Gufo dashboard |
| `.data/` | Runtime state for Prometheus TSDB + Grafana (gitignored) |
| `docs/` | Troubleshooting (NPU) and notes |
| `models/` | Local GGUF weights (gitignored) |

Local `docker-compose.yml`, `docker-compose.override.yml`, and `.env` are gitignored; create them with `./dc.sh init` (and optionally `init:override`) or by copying the `*.example` files yourself.

## Environment

Important variables (see `.env.example`):

| Variable | Purpose |
| --- | --- |
| `HF_TOKEN` | Hugging Face auth for downloads |
| `HF_REPO` / `HF_*_MODEL` | Which GGUF files to fetch |
| `GUFO_MODEL` | First UD-IQ4_XS shard path inside the container |
| `GUFO_MTP` | Optional MTP draft model |
| `GUFO_MMPROJ` | Vision projector for image inputs |
| `MODELS_DIR` | Host models directory (default `./models`) |
| `FLASH_NEXT_PORT` | Published / serve port (default `8900`) |
| `GUFO_CONTEXT` | Serve context window in tokens (default `131072` = 128K; model max `262144` = 256K) |
| `GUFO_NPU` | `1` = NPU path (fabric clock held by `fabric-clock` service); `0` = GPU-only |
| `VIDEO_GID` / `RENDER_GID` | Optional; otherwise detected from `/dev/dri` |

## Notes

- Newcomers: `./dc.sh init` builds `model-download` only; `./dc.sh up` pulls `harianto/flash-next` from Docker Hub. Building `flash-next` locally is optional (developers / custom ROCm builds).
- `model-download` uses compose profile `init`, so plain `docker compose up` / `./dc.sh up` never starts it — only `./dc.sh download` (or `--profile init`).
- NPU (`GUFO_NPU=1`): the one-shot `fabric-clock` service pins the GPU fabric clock before `flash-next` starts. Keep `GUFO_NPU=0` to stay GPU-only; the serve script still skips NPU unless `/dev/accel/accel0` is present and the clock is held. `compose down` does not release the clock (it resets at reboot). See [docs/troubleshoot-npu.md](docs/troubleshoot-npu.md).
- Context window: `GUFO_CONTEXT` sets the serve context (default `131072` = 128K tokens). The model supports up to `262144` (256K), but KV-cache memory scales with the window — only raise it if VRAM allows, or load/serve may crash under memory pressure.
- First model load can take several minutes; `up` / `restart` poll `/v1/models` for up to ~10 minutes.
- Build args (ROCm version, `gfx` target, gufo ref, NPU compile) live in `_build.yml` and can be overridden via `.env`.
- Monitoring (optional, via `docker-compose.override.yml`): Prometheus scrapes
  `flash-next:8900/metrics`; Grafana is published by tsdproxy as hostname
  `grafana` (login from `GRAFANA_ADMIN_*` in `.env`). Config lives under
  `src/prometheus/` and `src/grafana/`; runtime data under `.data/`.
- Changelog entries live in `.changelog/` (not a root `CHANGELOG.md`).
