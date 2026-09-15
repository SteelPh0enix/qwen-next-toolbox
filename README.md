# Qwen3.8-Next-Flash toolbox — AMD Strix Halo (`gfx1151`)

Serve **Qwen3.8-Flash-Next (177B)** on a 128 GB Ryzen AI Max / Max+ (Radeon 8060S, `gfx1151`)
with the ROCm/HIP stack from [`pwilkin/strix-halo`](https://github.com/pwilkin/strix-halo), in
Docker. Nothing is installed as root on the host and the host's `/opt/rocm` is never touched.

You need: Linux x86_64 with `amdgpu` loaded, Docker + Compose v2, 128 GB unified memory,
~110 GiB free for the weights (plus ~9 GB image and ~3 GiB build state).

> Container recipe — Fedora 44 base, AMD's `amdrocm{,-core-devel}10.0-gfx1151` package sets, the
> `/opt/rocm/core*` layout, Compose device flags — comes from
> [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes). What is
> added here is the `pwilkin/strix-halo` build itself, driven by its own installer.

## Table of contents

1. [Quick start](#1-quick-start)
2. [What you get](#2-what-you-get)
3. [Host requirements](#3-host-requirements)
4. [Configure](#4-configure)
5. [Build the image](#5-build-the-image)
6. [Build the stack and download weights](#6-build-the-stack-and-download-weights)
7. [Run llama-server](#7-run-llama-server)
8. [Other weights and arbitrary models](#8-other-weights-and-arbitrary-models)
9. [Tuning](#9-tuning)
10. [Rootless vs rootful Docker](#10-rootless-vs-rootful-docker)
11. [Troubleshooting](#11-troubleshooting)
12. [Reference](#12-reference)

---

## 1. Quick start

```bash
cp .env.example .env                  # 1. config; defaults are fine for rootless Docker
docker compose build setup            # 2. image (~9 GB, needs network)
./pull-models.sh                      # 3. compile ROCr/HIP/llama.cpp + download ~96 GiB weights
docker compose up -d server           # 4. serve on http://localhost:8080
curl -s localhost:8080/health         # {"status":"ok"} once loaded — loading 93 GiB takes a while
```

Step 3 compiles in under 10 minutes at `JOBS=16`; the rest is download-bound. It is **resumable** —
interrupt and rerun any time.

Chat with it:

```bash
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Introduce Strix Halo in one line."}],"max_tokens":64}'
```

Point any OpenAI-compatible client at `http://localhost:8080/v1`. The first request after a start is
slow: weights are read on demand, so pages are cold.

Before step 1, fix these if they apply to you:

* **Rootful (system) Docker** → set `STRIX_USER=$(id -u):$(id -g)` in `.env`; see
  [rootless vs rootful](#10-rootless-vs-rootful-docker).
* **`/dev/kfd` not readable** → `sudo usermod -aG render,video $USER`, log out and back in.
* **`max locked memory`** → `ulimit -l` should be `unlimited`; a rootless daemon cannot raise it
  above its own limit (systemd drop-in).
* **Not a 128 GB Strix Halo** → this profile will not fit. On the same container the smaller
  `qwen38-27b` profile works: [27B variant](#the-27b-variant).

Everything below explains those commands and the knobs you can turn.

## 2. What you get

| Layer | Source | Result |
| :-- | :-- | :-- |
| ROCr runtime | `pwilkin/rocm-systems@ilintar-experiments` (`7dda3ac`) — retained PM4 command lists | `libhsa-runtime64.so.1.21.0`, built into the state directory |
| HIP runtime | same fork, `projects/clr` + `projects/hip` | `libamdhip64.so.7.16`, built into the state directory |
| Engine | `pwilkin/llama.cpp@strix-halo` (`d67d5883`) — UMA scheduler ring, wave32 `TOP_K`, gfx1151 tuning, MTP speculative decoding | `llama-server`, `llama-bench`, `test-backend-sched-ring` |
| Weights | `ilintar/qwen3.8-flash-next-gguf-strix-halo` | 9 × IQ4_NL `PROJFIX` shards (93 GiB) + `mtp-…-shared-Q8_0.gguf` draft (2.8 GiB). Text only, no vision projector |
| ROCm SDK | AMD Core SDK 10.0 (TheRock stream), `amdrocm{,-core-devel}10.0-gfx1151` | `hipcc`, AMD LLVM, rocBLAS/hipBLAS with gfx1151 kernels, `amd_comgr`, `rocprofiler-register` |

Upstream's numbers for this configuration on one Radeon 8060S, 16384 batch/ubatch:

| Context depth | Prefill t/s | Decode t/s |
| :-- | --: | --: |
| 0 | 1204.31 ± 2.31 | 26.28 ± 0.29 |
| 40 000 | 1086.29 ± 0.96 | 16.63 ± 0.14 |

Prefill is the tuned path; upstream says decode is not where it should be yet.

## 3. Host requirements

```bash
test -r /dev/kfd -a -w /dev/kfd && echo "kfd ok"
ls -l /dev/dri/renderD*
awk '$1 == "gfx_target_version" && $2 != 0 { print $2 }' \
    /sys/class/kfd/kfd/topology/nodes/*/properties      # want: 110501
```

* `amdgpu` loaded, `gfx1151` visible in the KFD topology, `gc_11_5_0` firmware present — a kernel
  from 2025 or newer is a safe bet. The container inherits whatever your user can open.
* Docker Engine with the Compose v2 plugin; `memlock` as high as possible.
* Disk: ~110 GiB for weights (96 GiB + headroom) and ~3 GiB for build state. Both directories may
  live anywhere — they are bind-mounted.
* 128 GB unified memory. The model does not fit in 64 GB; there is no smaller profile to fall back
  to here (see [the 27B variant](#the-27b-variant)).

Check the whole chain without building anything:

```bash
docker compose --profile setup run --rm setup \
  bash /opt/strix-halo/install-flash-next.sh --check-only --skip-packages --model-dir /models
```

Expected tail:

```
[install.sh] Detected an accessible gfx1151 device through amdgpu/KFD.
[install.sh] Verifying the system ROCm SDK at /opt/rocm/core-10.0
[install.sh] Found HIP 7.15.26333-0000000.
[install.sh] All prerequisite checks passed.
```

## 4. Configure

`docker compose` reads `.env` automatically. Defaults in `.env.example` work as-is for rootless
Docker; both mounted directories must be writable by the container user.

| Variable | Default | Meaning |
| :-- | :-- | :-- |
| `STRIX_STATE_DIR` | `./state` | Mounted as the container's `$HOME`: checkouts, build trees, venv, HF cache, generated launchers. Delete to start over. |
| `STRIX_MODEL_DIR` | `./models` | Mounted at `/models`; where the weights live. |
| `STRIX_PORT` | `8080` | Host port for the API. |
| `JOBS` | `16` | Build parallelism for `setup`. |
| `HF_TOKEN` | empty | Only if the weight repository is gated. |
| `STRIX_USER` | `root` | Container user — see [rootless vs rootful](#10-rootless-vs-rootful-docker). |
| `STRIX_RENDER_GID`, `STRIX_VIDEO_GID` | `303`, `26` | Host GIDs owning `/dev/kfd` and `/dev/dri/renderD128`: `getent group render video \| cut -d: -f3`. |
| `STRIX_SHM_SIZE` | `8g` | `/dev/shm` size. |
| `MODEL_FILE`, `DRAFT_MODEL`, `MMPROJ_FILE` | pinned set | Weights to serve — see [section 8](#8-other-weights-and-arbitrary-models). |
| `CTX_SIZE`, `BATCH_SIZE`, `UBATCH_SIZE`, `PARALLEL`, `MTP_N_MAX`, `ENABLE_RETAINED_PM4`, `GPU_MAX_HW_QUEUES` | see [tuning](#9-tuning) | Launcher knobs. |
| `MODEL_ALIAS` | `Qwen 3.8 Flash Next` | Model name reported to API clients (`--alias`). |

## 5. Build the image

Why a container at all: the installer needs a complete, *current* ROCm SDK under one `$ROCM_ROOT`
(`hipcc`, AMD LLVM, cmake packages `hip`/`hipblas`/`rocblas`/`amd_comgr`/`rocprofiler-register`), and
the fork is rebased on ROCm 10 (`libamdhip64.so.7`). Most distributions ship an older ROCm or none at
all, and AMD publishes ROCm 10 only for Fedora/RHEL and Ubuntu — hence a Fedora 44 image fed from
`stable.repo.amd.com`. The host contributes just the `amdgpu` driver and firmware.

```bash
docker compose build setup            # or: docker build -t qwen-next-toolbox:latest .
```

~9 GB. Installs `amdrocm10.0-gfx1151` (runtime libraries, incl. gfx1151 rocBLAS kernels) and
`amdrocm-core-devel10.0-gfx1151` (compiler + `-dev` packages) from AMD's repository, plus the build
tools the installer expects — which is why the container can build without ever calling a package
manager. The image also holds the upstream installer (`install.sh`) and its `flash-next` front end
under `/opt/strix-halo/`, downloaded from `pwilkin/strix-halo` at build time (not checked into this
repo); pin a commit with `--build-arg STRIX_HALO_REF=<sha>`.

## 6. Build the stack and download weights

`./pull-models.sh` is the upstream installer from `/opt/strix-halo/`. In order it:

1. re-checks the host (driver, KFD, SDK);
2. creates a Python venv with `CppHeaderParser` and `huggingface_hub[hf_xet]`;
3. clones both repositories and pins them to the recorded commits, refusing to continue if a
   checkout has local changes;
4. builds ROCr, then HIP against that ROCr, then `llama.cpp` for `gfx1151`, and verifies
   `libggml-hip.so` resolves `libamdhip64`/`libhsa-runtime64` through the fresh prefixes, not the SDK;
5. downloads the 9 shards and the MTP draft into `STRIX_MODEL_DIR`, SHA-256 verifying each;
6. writes `qwen3.8-strix-halo-server` and `llama-server-strix-halo` into `state/.local/bin/`.

**Resumable:** git pins are re-checked, CMake builds are incremental, `hf` resumes partial files
from `<STRIX_MODEL_DIR>/.cache/huggingface` (delete it to restart a shard from scratch), and any
file already present is hash-checked instead of re-downloaded. Launchers are written only at step 6,
so the server cannot start until one run finishes cleanly. Extra flags go to the installer:
`./pull-models.sh --jobs 8`.

### Bringing your own weights

Put these exact filenames in `STRIX_MODEL_DIR` and the next `setup` run verifies and keeps them
(names and SHA-256 sums live in `/opt/strix-halo/install.sh`):

```
Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf   … through 00009
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
```

A mismatch is a hard error, not a silent re-download — fix or delete the offending file and rerun.
This section is only about the *pinned* files; other weights need no `setup` run
([section 8](#8-other-weights-and-arbitrary-models)). `setup` always fetches the pinned set; if you
never serve it, you can delete those files afterwards (rerunning `setup` downloads them again).

### The 27B variant

`/opt/strix-halo/install.sh` defaults to the smaller, more mature `qwen38-27b` profile (~30 GiB of
IQ4_XS weights plus a DFlash2 draft and a vision projector):

```bash
docker compose --profile setup run --rm setup bash /opt/strix-halo/install.sh --skip-packages --model-dir /models
```

Both profiles install launchers under the same names — keep separate state directories for both.
`serve.sh` always applies the flash-next flag set (MTP speculation, 16384 batch), so for 27B run the
upstream launcher instead:

```bash
docker compose run --rm --service-ports \
  --entrypoint /home/strix/.local/bin/qwen3.8-strix-halo-server \
  server --host 0.0.0.0 --port 8080
```

## 7. Run llama-server

```bash
docker compose up -d server
docker compose logs -f server          # Ctrl-C once it settles
curl -s localhost:8080/props | head
docker compose stop server             # or: down
```

`serve.sh` (mounted from this repo at `/opt/toolbox/serve.sh`) applies the tuned configuration:
`-dev ROCm0 -ngl 999 -fa on -fit off`, `--load-mode none --lazy-mode on-direct` (keeps the 27.5 GB
per-layer embedding table out of the resident set), `f16` KV, 262144-token context (this toolbox's
default; upstream's launcher ships 65536), 16384 batch and ubatch, `--jinja`, `--alias` (see
[section 9](#9-tuning)), and MTP speculation with draft width 3 on the same device. It reads the engine and pinned-weight paths from
`state/.local/share/qwen3.8-strix-halo/config.sh` and never re-derives them.

Extra `llama-server` arguments appended to the service come last, so they win:

```bash
docker compose run --rm --service-ports server --api-key "$(openssl rand -hex 16)" --parallel 2
```

Plain `docker run`, if you would rather not use Compose — every item matters: devices for KFD/DRM,
`seccomp=unconfined` for the HSA ioctls, `memlock` for pinning weights, and the three mounts,
because the built runtimes live in `state/` on the host and `serve.sh` is read from the repo:

```bash
docker run --rm -it \
  --device /dev/kfd --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1:-1 --shm-size 8g \
  -e HF_TOKEN -e CTX_SIZE=262144 -e MTP_N_MAX=3 \
  -v "$PWD/state:/home/strix" \
  -v /path/to/models:/models \
  -v "$PWD/serve.sh:/opt/toolbox/serve.sh:ro" \
  -p 8080:8080 \
  --entrypoint /opt/toolbox/serve.sh \
  qwen-next-toolbox:latest --host 0.0.0.0 --port 8080
```

Watch the GPU with `rocm-smi` / `rocminfo`, which ship in the image
(`docker compose exec server rocm-smi -u`). On an APU, rocm-smi's "VRAM" counters only cover the
small carve-out — watch unified memory with `free` on the host.

## 8. Other weights and arbitrary models

Any GGUF works in place of the pinned shards — another quant of the same model, your own merge, a
quantized fine-tune. Put it in `STRIX_MODEL_DIR` and name it in `.env` (or per invocation):

```bash
MODEL_FILE=Qwen3.8-Next-IQ4_XS-00001-of-00003.gguf docker compose up -d server      # split set: name shard 1
MODEL_FILE=my-merge-Q8_0.gguf DRAFT_MODEL=my-merge-mtp-Q8_0.gguf docker compose up -d server
MODEL_FILE=some-model-IQ3.gguf DRAFT_MODEL=none docker compose up -d server         # no draft -> no speculation
```

| Variable | Meaning |
| :-- | :-- |
| `MODEL_FILE` | main weights. Bare name = under `/models`; absolute path = mounted into the container as-is. Default: the pinned shard `…-00001-of-00009.gguf`. Rename the served model with `MODEL_ALIAS`. |
| `DRAFT_MODEL` | MTP draft. `none` drops the whole `--spec-*` block (use when no draft matches the quant). Default: the pinned `mtp-…-shared-Q8_0.gguf`. |
| `MMPROJ_FILE` | optional vision projector, off by default — the pinned flash-next weights are text only. |

`serve.sh` checks that every file it was told to use exists and exits naming the offending variable.
Arguments appended to the service still come last, so
`docker compose run --rm --service-ports server -- -m /models/other.gguf` overrides `MODEL_FILE` for
one run.

The second installed launcher runs any GGUF under the custom runtime with no opinionated flags:

```bash
docker compose run --rm --service-ports \
  --entrypoint /home/strix/.local/bin/llama-server-strix-halo \
  server -m /models/some-model.gguf -ngl 999 -fa on --host 0.0.0.0 --port 8080
```

`llama-bench` and `test-backend-sched-ring` live in the same build tree:

```bash
docker compose run --rm --entrypoint bash server -c \
  '$HOME/.local/share/qwen3.8-strix-halo/build/llama.cpp/bin/llama-bench -m /models/some-model.gguf'
```

## 9. Tuning

Set in `.env`, or per invocation (`CTX_SIZE=32768 docker compose up -d server`).

| Variable | Default | Notes |
| :-- | :-- | :-- |
| `CTX_SIZE` | `262144` | Set here; upstream's launcher defaults to `65536`. The memory-limiting knob on 128 GB — with `-fit off` nothing is auto-shrunk, so an impossible request fails instead of backing off. Drop to `65536`/`131072` if the model loads but a long prompt does not. |
| `BATCH_SIZE` / `UBATCH_SIZE` | `16384` | The tuned prefill path. Larger ubatch measures the same within error and costs ~8 GiB of compute buffers. |
| `MTP_N_MAX` | `3` | MTP draft width. `0` disables speculation — `serve.sh` then skips loading the draft entirely. |
| `PARALLEL` | `1` | Slots. Each extra slot costs KV memory and decode throughput on an APU. |
| `ENABLE_RETAINED_PM4` | `1` | The fork's retained PM4 command lists. `0` sets `GGML_CUDA_DISABLE_GRAPHS=1` — A/B control, or if graphs misbehave. |
| `GPU_MAX_HW_QUEUES` | `1` | Keeps the iGPU from latching to max clock when idle. |
| `MODEL_ALIAS` | `Qwen 3.8 Flash Next` | Name served to API clients (`--alias`); comma-separated for several. Shows up in `/props`, `/v1/models`, and the `model` field of completions. |
| `HSA_OVERRIDE_GFX_VERSION` | `11.5.1` | Set by the launcher; only override if you know why. |
| `GGML_HIP_ENABLE_UNIFIED_MEMORY` | `1` | Set by the launcher. |

## 10. Rootless vs rootful Docker

| | rootless | rootful (system daemon) |
| :-- | :-- | :-- |
| container `root` | your host uid — files in the mounts stay yours | real root; files land root-owned |
| `STRIX_USER` | leave `root` | `$(id -u):$(id -g)` |
| `STRIX_RENDER_GID` / `STRIX_VIDEO_GID` | usually irrelevant, the daemon already passes devices you may open | required, and the uid must be able to open the devices |
| `memlock` | capped by the daemon's own limit (systemd drop-in for the user service) | set on the daemon unit |

The compose file never uses `privileged`, never adds capabilities, never mounts the docker socket or
the host filesystem.

## 11. Troubleshooting

| Symptom | Cause and fix |
| :-- | :-- |
| `failed to initialize ROCm: no ROCm-capable device is detected` | Devices not passed, `seccomp` blocking HSA ioctls, or the container user cannot open `/dev/kfd`. Use the compose service rather than a hand-written `docker run`; re-check [section 3](#3-host-requirements). |
| `the amdgpu kernel module is not loaded`, `gfx1151 was not detected in KFD topology` | Host driver/firmware. Update kernel and `amdgpu` firmware (`gc_11_5_0_*`); nothing in this image can fix it. |
| `the current user cannot access /dev/kfd` | Add the host user to `render`/`video`, log out and back in, confirm the rootless daemon restarted afterwards. |
| `mkdir: cannot create directory '/home/strix/.local': Permission denied` | `STRIX_STATE_DIR` is not writable by `STRIX_USER`. Under rootless Docker, use the default `STRIX_USER=root`. |
| `a complete ROCm SDK was not found` / `missing ROCm CMake package: …` | Image rebuilt without the AMD repository reachable. `docker run --rm --entrypoint hipconfig qwen-next-toolbox:latest --version` should print `7.15.x`. |
| `xxd not found!` during the ROCr build | Image built before `xxd` was added to the package list (Fedora 44 split it out of `vim-common`). Rebuild. |
| HIP crashes, `MES failed to respond`, hangs at model load | Host kernel or amdgpu firmware too old for Strix Halo. Update the host, then retest with `ENABLE_RETAINED_PM4=0` to separate the fork's graph path from the driver. |
| Allocation failures, OOM killer wins | Something else holds unified memory. Close other GPU users, lower `CTX_SIZE`/`PARALLEL`, or drop `UBATCH_SIZE` to 8192. `docker compose exec server rocm-smi -u` and `free` show what holds what. |
| Download stalls or a shard is corrupt | Rerun `./pull-models.sh`. To discard half-finished data: `rm -rf "$STRIX_MODEL_DIR/.cache/huggingface"`. |
| `server` starts and immediately exits with `No such file or directory` | Launchers do not exist yet — finish a `setup` run. |
| `serve.sh: no such model: … (MODEL_FILE)` | Typo, or the file is not under `STRIX_MODEL_DIR` (`/models`). Absolute paths must be mounted separately. |
| `serve.sh: … config.sh not found` | Stack is built only up to the download step; finish a `setup` run. |
| Port 8080 already in use | Change `STRIX_PORT`. |
| Weird symbol errors after a build that pulled a new ROCm | Versioned paths (`/opt/rocm/core-10.0`) are baked into the generated launchers. Rerun `setup`; if it persists, delete `STRIX_STATE_DIR/.local/share/qwen3.8-strix-halo` and rebuild from scratch. |

## 12. Reference

```
Dockerfile              Fedora 44 + AMD ROCm 10.0 gfx1151 SDK + build dependencies
compose.yaml            setup (profile "setup") and server services
.env / .env.example     host paths, port, credentials, launcher knobs, weight overrides
pull-models.sh          wrapper around the setup service (POSIX sh)
serve.sh                entrypoint of the `server` service; tuned launch + weight overrides
state/                  build output + generated launchers (created on first run)
models/                 weights (created on first run)
```

Inside the container:

```
/opt/toolbox/serve.sh                                   `server` entrypoint (mounted from the repo)
/home/strix/.local/bin/qwen3.8-strix-halo-server        upstream tuned launcher for flash-next
/home/strix/.local/bin/llama-server-strix-halo          generic wrapper, sets LD_LIBRARY_PATH
/home/strix/.local/share/qwen3.8-strix-halo/
  src/{rocm-systems,llama.cpp}                          pinned checkouts
  build/{rocr,hip,llama.cpp}                            build trees; llama-server in build/llama.cpp/bin
  runtime/{rocr,hip}                                    the custom libhsa-runtime64 / libamdhip64
  venv/                                                 build + downloader Python environment
  cache/huggingface                                     HF/xet cache
/opt/rocm → /opt/rocm/core-10.0                         AMD SDK; never modified at runtime
```

A shell in the built environment: `docker compose run --rm --entrypoint bash server`.

**Runtime environment the launchers set** — `LD_LIBRARY_PATH` with the custom `hip`/`rocr` prefixes
first, then the SDK (`/opt/rocm/core/lib`, `…/lib/rocm_sysdeps/lib`); `HSA_OVERRIDE_GFX_VERSION=11.5.1`;
`GGML_HIP_ENABLE_UNIFIED_MEMORY=1`; `ENABLE_RETAINED_PM4=1` with `DEBUG_HIP_GRAPH_PM4=1`, or
`GGML_CUDA_DISABLE_GRAPHS=1` when disabled.

**Pins** — ROCm and llama.cpp commits are recorded in the installer (`/opt/strix-halo/install.sh`),
which refuses to move off them, so rebuilds stay reproducible. The AMD SDK package is
`amdrocm-core-devel10.0-gfx1151`.

**Upstream** — [installer and guide](https://github.com/pwilkin/strix-halo) ·
[amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) (container layout) ·
[write-up with benchmarks](https://pwilkin.github.io/strix-halo/) ·
[llama.cpp fork](https://github.com/pwilkin/llama.cpp/tree/strix-halo) ·
[rocm-systems fork](https://github.com/pwilkin/rocm-systems/tree/ilintar-experiments) ·
[weights](https://huggingface.co/ilintar/qwen3.8-flash-next-gguf-strix-halo). llama.cpp, ROCm, Qwen
and the quantized weights remain under their respective licenses; the wrapper files in this
repository are MIT, as is the upstream installer.
