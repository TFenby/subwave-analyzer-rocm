# subwave-analyzer-rocm

[SUB/WAVE](https://github.com/perminder-klair/subwave)'s heavy analyzer image
(CLAP "sounds-like" embeddings + Demucs vocal ranges) with AMD ROCm torch
wheels in place of the CPU ones. Everything else is byte-for-byte upstream's
`subwave-analyzer-heavy`; the analyzer picks the GPU on its own because ROCm
torch reports AMD cards through `torch.cuda.is_available()`.

Tags track upstream releases (`latest`, `1.28.0`, `1.28`, …) so
`SUBWAVE_VERSION` pins work unchanged. Rebuilt automatically when upstream
releases.

The host needs only the `amdgpu` kernel driver; the ROCm userspace ships in
the image. It is large: the ROCm torch wheel alone unpacks to 21 GB (10 GB of
that is hipblaslt kernels for every supported GPU arch), so budget ~31 GB of
disk versus ~2 GB for upstream's heavy image.

## Same host as the station

1. Drop `docker-compose.analyzer-rocm.yml` next to your `docker-compose.yml`.
2. In `.env`:

   ```
   COMPOSE_FILE=docker-compose.yml:docker-compose.analyzer-rocm.yml
   VIDEO_GID=44      # from: getent group video render
   RENDER_GID=105
   ANALYZE_CONCURRENCY=1   # keep at 1 on cards with 4 GB or less
   ```

3. `docker compose up -d analyzer`

## Remote GPU host

The analyzer is plain HTTP, and the controller already copes with a remote
one: it stages audio to a shared path when it can and falls back to a URL
download when it cannot. So the minimal remote setup is the same file, run on
its own on the GPU host, with one reachability block uncommented:

- **Published port** (`ports:`): no other setup. Station `.env`:
  `ANALYZE_URL=http://<gpu-host>:8080`, `ANALYZER_REPLICAS=0`.
- **Swarm overlay** (`networks:`): name resolution and no published port.
  Create it once, attachable, with a subnet that overlaps nothing:
  `docker network create -d overlay --attachable --subnet 172.30.1.0/24 subwave-remote`.
  The station then needs `docker-compose.station.yml` in its `COMPOSE_FILE`
  so the controller joins it, and `ANALYZE_URL=http://sub-wave-analyzer:8080`.

Set `ANALYZE_CONCURRENCY` to the same value on both hosts.

That gives you bpm, key, loudness, structure, CLAP vectors and vocal ranges.
Two features additionally need the analyzer to **write** into the station's
state: the stem cache and stem-blend transitions. For those, add NFS:

### NFS for stems and blends

The station **host** serves it, not a container. A mount inside a container
is made either by the host kernel, which cannot reach a Swarm overlay, or by
a container holding `SYS_ADMIN`, and a containerised nfsd additionally fights
overlayfs for its NFSv4 pseudo-root. The host server needs neither.

Station host (`/srv/subwave/state` is wherever your compose's `./state`
lives; the GPU host's address is the only client the exports accept):

```
apt install nfs-kernel-server
cat >> /etc/exports <<'EOF'
/srv/subwave/state/analyze-tmp   192.168.1.20(ro,sync,no_subtree_check)
/srv/subwave/state/transitions   192.168.1.20(rw,sync,no_subtree_check)
/srv/subwave/state/stems         192.168.1.20(rw,sync,no_subtree_check)
EOF
exportfs -ra
```

- Use an **address**, not a hostname: nfsd matches names by reverse DNS of
  the client, and an unmatched client sees "no such file or directory", not
  "access denied".
- `analyze-tmp` is read-only because the analyzer only reads staged audio
  there. Secrets and settings are never exported.
- If the station sets `STEMS_DIR`, export that path as the third line and
  set `NFS_STEMS_EXPORT` to it on the GPU host.
- **`analyze-tmp` must be a mount point.** The controller deletes that whole
  directory at the end of every analysis pass and recreates it on the next,
  which breaks the export while it is absent and leaves a mounted client
  holding the deleted inode. A bind mount of a plain directory fixes it: the
  sweep empties the directory, as intended, and the directory survives.

  ```
  mkdir -p /srv/subwave/analyze-tmp /srv/subwave/state/analyze-tmp
  echo '/srv/subwave/analyze-tmp /srv/subwave/state/analyze-tmp none bind 0 0' >> /etc/fstab
  mount -a
  docker compose up -d --force-recreate controller   # the container must see the mount
  exportfs -ra
  ```

GPU host: `nfs-utils` installed, the NFS blocks in
`docker-compose.analyzer-rocm.yml` uncommented, and in `.env`:

```
NFS_HOST=192.168.1.10
NFS_EXPORT_ROOT=/srv/subwave/state
NFS_STEMS_EXPORT=/srv/subwave/stems    # only if the station sets STEMS_DIR
```

Then `docker compose up -d`. Changing a volume's NFS target later means
recreating that named volume; it holds no data of its own, so answer yes.

## Verify

```
docker compose exec analyzer python -c "import torch; p=torch.cuda.get_device_properties(0); print(torch.__version__, torch.cuda.is_available(), p.name, p.gcnArchName)"
# → 2.7.1+rocm6.3 True AMD Radeon ... gfx1030
docker compose logs analyzer | grep 'analysis device'   # after the first CLAP/Demucs job
# → analysis device: cuda (AMD Radeon ...)
```

`ANALYZE_DEVICE=cpu` in `.env` forces CPU without dropping the overlay, same
as upstream's CUDA flavour.

Tracks analysed while the GPU facets were failing are not lost: upstream's
next ordinary "Analyze new tracks" pass widens to every analysed track that
lacks a CLAP vector or vocal ranges and fills them in. No full re-analysis.

## Unsupported cards

ROCm only supports a short list of GPUs. On others torch still finds the card
and then every kernel fails with `HIP error: invalid device function`,
because the wheel ships compiled kernels for a fixed set of architectures.
Presenting the card as a supported sibling via `HSA_OVERRIDE_GFX_VERSION`
usually works; the compose file has the line commented out. Known community
values:

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
