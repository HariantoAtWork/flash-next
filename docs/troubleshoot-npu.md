# Troubleshoot NPU (Docker)

Runtime NPU is opt-in. The image is built with NPU support
(`GUFO_ENABLE_NPU=ON`), but `docker-serve.sh` only sets `GUFO_NPU_DIR` when
**all** of these hold:

1. `GUFO_NPU != 0` (set in `.env`)
2. `/dev/accel/accel0` exists inside the container
3. GPU fabric clock is held (`fabric-clock.sh status` succeeds)
4. NPU power mode is **not** `turbo` (checked only if `xrt-smi` is available)

Otherwise the serve script prints a warning and continues **GPU-only**.

Quick check after `./dc.sh restart`:

```bash
./dc.sh logs
# Look for:
#   WARNING: GPU fabric clock not held: running without the NPU.
#   WARNING: NPU is in turbo mode: running without the NPU.
```

No such warning + `GUFO_NPU=1` usually means NPU was enabled for that start.

---

## WARNING: NPU is in turbo mode

### What it means

`docker-serve.sh` ran `xrt-smi examine -r platform` and saw power mode
`turbo`. Gufo skips the NPU in that mode (even if the fabric clock is held).

### Fix (preferred: env at serve start)

Set in `.env` so `docker-serve.sh` runs `xrt-smi configure` before the turbo
guard on every start (no post-hoc `docker exec`):

```bash
GUFO_NPU=1
GUFO_NPU_PMODE=performance
# or: balanced | default | powersaver  (never turbo)
```

Then:

```bash
./dc.sh restart
```

Power mode resets on every driver load / reboot; the env re-applies it each
serve start. Confirm:

```bash
docker exec flash-next xrt-smi examine -r platform | grep -i 'power mode'
# or look for: NPU power mode set to performance.
```

### Manual (host or running container)

The image ships `xrt-smi` via `libxrt-utils` / `libxrt-utils-npu`:

```bash
sudo xrt-smi configure --pmode performance
# or:
docker exec flash-next xrt-smi configure --pmode performance
```

### If `xrt-smi` is still missing

- Classic XRT installs put the binary under `/opt/xilinx/xrt/bin` (override
  with `XRT_DIR` in `.env`). The serve script also accepts `xrt-smi` on `PATH`.
- Rebuild the image if you are on an older tag that only had the XRT libs:
  `docker compose -f _build.yml build flash-next`.

---

## Fabric clock is held on every start (Option A)

### What it means

Compose always runs the one-shot `fabric-clock` service before `flash-next`:

```text
fabric-clock → /opt/gufo/tools/npu/fabric-clock.sh hold
flash-next   → depends_on: service_completed_successfully
```

That pins the GPU fabric clock (`pp_dpm_fclk`) at its top level via sysfs.
It happens **whenever** you `up` / `restart`, even if:

- `GUFO_NPU=0` (GPU-only), or
- a later NPU precondition fails (no `/dev/accel`, turbo mode, etc.)

That is the accepted Option A trade-off: simple Compose wiring, clock always
held at start.

### Why it matters

Gufo’s NPU docs warn that **changing the fabric clock while the NPU is busy
can hang the machine**. Holding it before serve reduces that risk when NPU is
on. Pinning it for GPU-only runs is usually harmless but keeps fclk at the top
level until reboot (or manual release).

### Check status

```bash
docker compose run --rm --entrypoint /opt/gufo/tools/npu/fabric-clock.sh \
  fabric-clock status
# held
# or: NOT held  (exit 1)
```

### Release manually (optional)

`compose down` does **not** release the clock. It resets at reboot. To release
without rebooting:

```bash
docker compose run --rm --entrypoint /opt/gufo/tools/npu/fabric-clock.sh \
  fabric-clock release
```

### Hold failed / `fabric-clock` exited non-zero

Then `flash-next` will not start (`depends_on:
service_completed_successfully`). Typical causes:

- Container not privileged (sysfs write denied)
- Missing `/dev/kfd` / `/dev/dri` on the `fabric-clock` service (separate
  container — GPU nodes should be passed so amdgpu sysfs is present)
- No amdgpu `pp_dpm_fclk` node visible
- Hold verify flake (`could not hold it` within ~5s) — retry
  `./dc.sh restart`; clock may already be held
- Driver / firmware oddity on this board

Inspect:

```bash
docker compose logs fabric-clock
docker compose run --rm --entrypoint sh fabric-clock -c \
  'ls /sys/class/drm/card*/device/pp_dpm_fclk; ls -l /dev/dri /dev/kfd'
```

---

## Other common NPU skips

### `GUFO_NPU=0` in `.env`

Default in `.env.example`. Serve stays GPU-only even though `fabric-clock`
still runs. Set `GUFO_NPU=1` and `./dc.sh restart`.

### Missing `/dev/accel/accel0` in the container

Compose must pass the device:

```yml
devices:
  - /dev/kfd
  - /dev/dri
  - /dev/accel/accel0
```

Confirm on the host and in a throwaway container:

```bash
ls -l /dev/accel/accel0
docker compose run --rm --entrypoint ls flash-next -l /dev/accel/accel0
```

### NPU kept in runtime suspend (host)

If the NPU still misbehaves after hold + non-turbo mode:

```bash
# Find the NPU / amdxdna PCI id, then:
echo on | sudo tee /sys/bus/pci/devices/<npu-pci-id>/power/control
```

See upstream gufo `docs/NPU.md` for the full prerequisite table.

---

## Safe GPU-only again

```bash
# .env
GUFO_NPU=0
```

```bash
./dc.sh restart
# optional: release fabric clock
docker compose run --rm --entrypoint /opt/gufo/tools/npu/fabric-clock.sh \
  fabric-clock release
```
