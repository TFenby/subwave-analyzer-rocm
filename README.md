# subwave-analyzer-rocm

[SUB/WAVE](https://github.com/perminder-klair/subwave)'s heavy analyzer image
(CLAP "sounds-like" embeddings + Demucs vocal ranges) with AMD ROCm torch
wheels in place of the CPU ones. Everything else is byte-for-byte upstream's
`subwave-analyzer-heavy`; the analyzer picks the GPU on its own because ROCm
torch reports AMD cards through `torch.cuda.is_available()`.

Tags track upstream releases (`latest`, `1.28.0`, `1.28`, …) so
`SUBWAVE_VERSION` pins work unchanged. Rebuilt automatically when upstream
releases.

## Use

1. Drop `docker-compose.analyzer-rocm.yml` next to your `docker-compose.yml`.
2. In `.env`:

   ```
   COMPOSE_FILE=docker-compose.yml:docker-compose.analyzer-rocm.yml
   VIDEO_GID=44      # from: getent group video render
   RENDER_GID=105
   ANALYZE_CONCURRENCY=1   # keep at 1 on cards with 4 GB or less
   ```

3. `docker compose up -d analyzer`

The host needs only the `amdgpu` kernel driver; the ROCm userspace ships in
the image. It is large: the ROCm torch wheel alone unpacks to 21 GB (10 GB of
that is hipblaslt kernels for every supported GPU arch), so budget ~31 GB of
disk for the image versus ~2 GB for upstream's heavy image.

## Verify

```
docker compose exec analyzer python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
# → 2.7.1+rocm6.3 True AMD Radeon ...
docker compose logs analyzer | grep 'analysis device'   # after the first CLAP/Demucs job
# → analysis device: cuda (AMD Radeon ...)
```

`ANALYZE_DEVICE=cpu` in `.env` forces CPU without dropping the overlay, same
as upstream's CUDA flavour.

## Unsupported cards

ROCm only supports a short list of GPUs. Others usually work when presented
as a supported sibling via `HSA_OVERRIDE_GFX_VERSION`; the overlay has the
line commented out. Known community values:

| Card | Arch | Set |
| --- | --- | --- |
| RX 6400 / 6500 XT / 6500M (Navi 24) | gfx1034 | `HSA_OVERRIDE_GFX_VERSION=10.3.0` |

These are workarounds, not supported configurations. Watch the analyzer logs
on the first pass: a Demucs out-of-memory degrades that track's vocal ranges
to none rather than failing the job.

## Build locally

```
docker build --build-arg UPSTREAM_TAG=1.28.0 -t subwave-analyzer-rocm .
```

`UPSTREAM_TAG` is any tag of `ghcr.io/perminder-klair/subwave-analyzer-heavy`.
The build reads upstream's torch pin from the image and installs the matching
`+rocm6.3` wheels; it fails loudly if no such wheel exists (bump `ROCM` in the
Dockerfile when that happens).
