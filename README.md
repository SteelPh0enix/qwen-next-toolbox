# Qwen3.8-Next-Flash toolbox — AMD Strix Halo (`gfx1151`)

Everything needed to build and serve **Qwen3.8-Flash-Next (177B)** on a 128 GB Strix Halo
machine with the ROCm/HIP stack from
[`pwilkin/strix-halo`](https://github.com/pwilkin/strix-halo), inside Docker.

Only assumption about your machine: **Linux, Docker (+ Compose v2), rootless or rootful,
Ryzen AI Max / Max+ with a Radeon 8060S (`gfx1151`) and 128 GB of unified memory.**

> The container recipe is taken from
> [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes): the
> Fedora 44 base, AMD's `amdrocm{,-core-devel}10.0-gfx1151` package sets, the `/opt/rocm/core*`
> symlink layout and the Compose device flags all come from there. What is added here is the
> `pwilkin/strix-halo` build itself, driven by its own installer.

---

## Table of contents

1. [What you get](#1-what-you-get)
2. [Why a container](#2-why-a-container)
3. [Host requirements](#3-host-requirements)
4. [Repository layout](#4-repository-layout)
5. [Configure](#5-configure)
6. [Build the image](#6-build-the-image)
7. [Build the stack and prepare the weights](#7-build-the-stack-and-prepare-the-weights)
8. [Run llama-server](#8-run-llama-server)
9. [Tuning](#9-tuning)
10. [Arbitrary models](#10-arbitrary-models)
11. [Rootless vs rootful Docker](#11-rootless-vs-rootful-docker)
12. [Troubleshooting](#12-troubleshooting)
13. [Reference](#13-reference)

---

## 1. What you get

| Layer | Source | Result |
| :-- | :-- | :-- |
| ROCr runtime | `pwilkin/rocm-systems@ilintar-experiments` (`7dda3ac`) — adds retained PM4 command lists | `libhsa-runtime64.so.1.21.0`, built into the state directory |
| HIP runtime | same fork, `projects/clr` + `projects/hip` | `libamdhip64.so.7.16`, built into the state directory |
| Engine | `pwilkin/llama.cpp@strix-halo` (`d67d5883`) — UMA scheduler ring, wave32 `TOP_K`, gfx1151 tuning, MTP speculative decoding | `llama-server`, `llama-bench`, `test-backend-sched-ring` |
| Weights | `ilintar/qwen3.8-flash-next-gguf-strix-halo` | 9 × IQ4_NL `PROJFIX` shards (93 GiB) + `mtp-…-shared-Q8_0.gguf` draft (2.8 GiB). Text only, no vision projector |
| ROCm SDK | AMD's Core SDK 10.0 (TheRock stream), `amdrocm{,-core-devel}10.0-gfx1151` | `hipcc`, AMD LLVM, rocBLAS/hipBLAS with gfx1151 kernels, `amd_comgr`, `rocprofiler-register` |

Upstream's published numbers for this exact configuration on one Radeon 8060S, 16384-token
batch and ubatch:

| Context depth | Prefill t/s | Decode t/s |
| :-- | --: | --: |
| 0 | 1204.31 ± 2.31 | 26.28 ± 0.29 |
| 40 000 | 1086.29 ± 0.96 | 16.63 ± 0.14 |

Prefill is the tuned path; upstream states decode is not yet where it should be.

## 2. Why a container

The installer needs a **complete, current ROCm SDK** under a single `$ROCM_ROOT`: `hipcc`,
an AMD LLVM (`clang++`, `llvm-mc`) and the cmake packages `hip`, `hipblas`, `rocblas`,
`amd_comgr`, `rocprofiler-register`. It then compiles its own ROCr and HIP on top of that
SDK and points `llama.cpp` at the results, while `rocBLAS`/`hipBLAS` keep coming from the
SDK at runtime.

That SDK has to be recent — the fork is rebased on ROCm 10 (`HIP 7.16`, `libamdhip64.so.7`)
— and most distributions either package an older ROCm or do not package it at all. AMD only
publishes ROCm 10 as Fedora/RHEL and Ubuntu packages, so the toolbox is a Fedora 44 image fed from
`stable.repo.amd.com`. The host contributes nothing but the `amdgpu` kernel driver and
firmware, and its own ROCm installation (if any) is never touched or shadowed.

Nothing is installed as root on the host, and `/opt/rocm` on the host is never modified.

## 3. Host requirements

* Linux x86_64, `amdgpu` loaded, `gfx1151` visible in the KFD topology, `gc_11_5_0` firmware
  present (a kernel from 2025 or newer is a safe bet for Strix Halo).
* Your user can open the compute devices — this is what the container inherits:

  ```bash
  test -r /dev/kfd -a -w /dev/kfd && echo "kfd ok"
  ls -l /dev/dri/renderD*
  awk '$1 == "gfx_target_version" && $2 != 0 { print $2 }' \
      /sys/class/kfd/kfd/topology/nodes/*/properties      # want: 110501
  ```

  If the first line fails, add yourself to the `render` (and usually `video`) groups and log
  out and back in.
* `ulimit -l` (`max locked memory`) as large as possible, ideally `unlimited`. Compose raises
  the container's limit, but a rootless daemon cannot raise it above its own limit.
* Docker Engine with the Compose v2 plugin.
* Disk: approx. 96 GiB for the weights plus approx. 10 GiB of headroom, and approx. 3 GiB for the build state.
  Both directories may live anywhere; they are bind-mounted.
* 128 GB of unified memory. The model does not fit in 64 GB — there is no smaller profile to
  fall back to here (see [the 27B variant](#switching-to-the-27b-variant) instead).

Check the whole stack of host prerequisites without building anything:

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

## 4. Repository layout

```
Dockerfile              Fedora 44 + AMD ROCm 10.0 gfx1151 SDK + build dependencies
compose.yaml            two services: setup (profile "setup") and server
.env / .env.example     host paths, port, credentials, launcher knobs
pull-models.sh          convenience wrapper around the setup service (POSIX sh)
state/                  build output + generated launchers (created on first run)
models/                 weights (created on first run)
```

The image holds the upstream installer (`install.sh`) and its `flash-next` front end under
`/opt/strix-halo/`, downloaded from `pwilkin/strix-halo` during `docker build` (so building
needs network); they are not checked into this repository.

## 5. Configure

```bash
cp .env.example .env
$EDITOR .env
```

| Variable | Default | Meaning |
| :-- | :-- | :-- |
| `STRIX_STATE_DIR` | `./state` | Host directory mounted as the container's `$HOME`. Holds git checkouts, build trees, the Python venv, the Hugging Face cache and the generated launchers. Delete it to start over. |
| `STRIX_MODEL_DIR` | `./models` | Host directory mounted at `/models`; the weights go here. |
| `STRIX_PORT` | `8080` | Host port for the API. |
| `JOBS` | `16` | Build parallelism for `setup`. |
| `HF_TOKEN` | empty | Only if the weight repository is gated or you already have one and want to use it. |
| `STRIX_USER` | `root` | Container user — see [rootless vs rootful](#11-rootless-vs-rootful-docker). |
| `STRIX_RENDER_GID`, `STRIX_VIDEO_GID` | `303`, `26` | Host GIDs owning `/dev/kfd` and `/dev/dri/renderD128`: `getent group render video \| cut -d: -f3`. |
| `STRIX_SHM_SIZE` | `8g` | `/dev/shm` size. |
| `CTX_SIZE`, `BATCH_SIZE`, `UBATCH_SIZE`, `PARALLEL`, `MTP_N_MAX`, `ENABLE_RETAINED_PM4`, `GPU_MAX_HW_QUEUES` | see [tuning](#9-tuning) | Passed to the `server` container and read by the launcher. |

Both bind-mounted directories must be writable by the container user. With the default
`STRIX_USER=root` under rootless Docker that is your own account, so the defaults in
`.env.example` need no chown'ing.

## 6. Build the image

```bash
docker compose build setup
# equivalent: docker build -t qwen-next-toolbox:latest .
```

The image is ~9 GB: it installs `amdrocm10.0-gfx1151` (runtime libraries, including the
gfx1151 rocBLAS kernels) and `amdrocm-core-devel10.0-gfx1151` (compiler + `-dev` packages)
from AMD's repository, plus the build tools the installer expects. It also preinstalls that
dependency list, which is why the container can build without ever calling a package manager.

## 7. Build the stack and prepare the weights

One command does both — it is the upstream installer from `/opt/strix-halo/`:

```bash
docker compose --profile setup run --rm setup
# or: ./pull-models.sh
```

It will, in order:

1. re-check the host (driver, KFD, SDK) — same checks as `--check-only`;
2. create a Python venv with `CppHeaderParser` and `huggingface_hub[hf_xet]`;
3. clone both repositories and pin them to the recorded commits, refusing to continue if a
   checkout has local changes;
4. build ROCr, then HIP against that ROCr, then `llama.cpp` for `gfx1151`, and verify that
   `libggml-hip.so` resolves `libamdhip64` and `libhsa-runtime64` through the freshly built
   prefixes rather than the SDK;
5. download the 9 shards and the MTP draft into `STRIX_MODEL_DIR`, SHA-256 verifying each one;
6. write `qwen3.8-strix-halo-server` and `llama-server-strix-halo` into
   `state/.local/bin/`.

Compile time is under 10 minutes at `JOBS=16` on a 16-core / 32-thread Strix Halo; after that
the download is limited by your connection (~96 GiB).

**It is resumable.** Interrupt it whenever you like and run it again: git pins are re-checked,
CMake builds are incremental, `hf` resumes partial files from
`<STRIX_MODEL_DIR>/.cache/huggingface` (that directory disappears as each file completes;
delete it to restart one shard from scratch), and any file already present is hash-checked
instead of re-downloaded. The launchers are only written at step 6, so the server cannot start
until one run finishes cleanly.

### Bringing your own weights

Place these exact filenames in `STRIX_MODEL_DIR` and the next `setup` run will verify and keep
them (the authoritative names and SHA-256 sums are in `/opt/strix-halo/install.sh`):

```
Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf   … through 00009
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
```

A mismatch is a hard error, not a silent re-download — fix or delete the offending file and
rerun.

### Switching to the 27B variant

`/opt/strix-halo/install.sh` defaults to the smaller, more mature `qwen38-27b` profile
(~30 GiB of IQ4_XS weights plus a DFlash2 draft and a vision projector):

```bash
docker compose --profile setup run --rm setup bash /opt/strix-halo/install.sh --skip-packages --model-dir /models
```

Both profiles install launchers under the same names, so the `server` service always runs
whichever profile was installed last. Keep separate state directories if you want both.

## 8. Run llama-server

### With Compose

```bash
docker compose up -d server
docker compose logs -f server          # loading 93 GiB takes a while; Ctrl-C once it settles
curl -s localhost:8080/health          # {"status":"ok"} once the model is loaded
curl -s localhost:8080/props | head
docker compose stop server             # or: down
```

The launcher already applies the tuned configuration: `-dev ROCm0 -ngl 999 -fa on -fit off`,
`--load-mode none --lazy-mode on-direct` (this is what keeps the 27.5 GB per-layer embedding
table out of the resident set), `f16` KV cache, 262144-token context (this toolbox's default;
upstream's launcher itself ships 65536), 16384 batch and ubatch,
`--jinja`, and MTP speculation with a draft width of 3 on the same device.

### With plain `docker run`

```bash
docker run --rm -it \
  --device /dev/kfd --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1:-1 --shm-size 8g \
  -e HF_TOKEN -e CTX_SIZE=262144 -e MTP_N_MAX=3 \
  -v "$PWD/state:/home/strix" \
  -v /path/to/models:/models \
  -p 8080:8080 \
  --entrypoint /home/strix/.local/bin/qwen3.8-strix-halo-server \
  qwen-next-toolbox:latest --host 0.0.0.0 --port 8080
```

Everything in that list matters: the devices for KFD and DRM access, `seccomp=unconfined` for
the HSA ioctls, `memlock` for pinning weights, and the two mounts because the launchers and
the built runtimes live in `state/` on the host.

### Talking to it

```bash
curl -s localhost:8080/v1/models
curl -s localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Introduce Strix Halo in one line."}],
       "max_tokens":64}'
```

The first request after start is slow: weights are read on demand rather than mapped, so pages
are still cold. `rocm-smi` and `rocminfo` ship in the image:
`docker compose exec server rocm-smi -u` shows how busy the GPU is. On an APU, rocm-smi's
"VRAM" counters only cover the small carve-out — watch unified memory with `free` on the host.

To pass extra `llama-server` arguments, append them to the service — they are added last and
therefore win:

```bash
docker compose run --rm --service-ports server --api-key "$(openssl rand -hex 16)" --parallel 2
```

## 9. Tuning

Set in `.env`, or per invocation (`CTX_SIZE=32768 docker compose up -d server`).

| Variable | Default | Notes |
| :-- | :-- | :-- |
| `CTX_SIZE` | `262144` | Set here; upstream's launcher defaults to `65536`. It is the memory-limiting knob on 128 GB — `-fit off` means nothing is auto-shrunk, so an impossible request fails instead of backing off. Drop to `65536`/`131072` if the model loads but a long prompt does not. |
| `BATCH_SIZE` / `UBATCH_SIZE` | `16384` | The tuned prefill path. A larger ubatch measures the same within error and costs ~8 GiB of compute buffers. |
| `MTP_N_MAX` | `3` | MTP draft width. `0` disables speculation. |
| `PARALLEL` | `1` | Slots. Each extra slot costs KV memory and decode throughput on an APU. |
| `ENABLE_RETAINED_PM4` | `1` | The fork's retained PM4 command lists. `0` sets `GGML_CUDA_DISABLE_GRAPHS=1` — useful as an A/B control or if graphs misbehave. |
| `GPU_MAX_HW_QUEUES` | `1` | Keeps the iGPU from latching to max clock when idle. |
| `HSA_OVERRIDE_GFX_VERSION` | `11.5.1` | Set by the launcher; only override if you know why. |
| `GGML_HIP_ENABLE_UNIFIED_MEMORY` | `1` | Set by the launcher. |

## 10. Arbitrary models

The second installed launcher runs any GGUF under the custom runtime, with no opinionated
flags of its own:

```bash
docker compose run --rm --service-ports \
  --entrypoint /home/strix/.local/bin/llama-server-strix-halo \
  server -m /models/some-model.gguf -ngl 999 -fa on --host 0.0.0.0 --port 8080
```

`llama-bench` and `test-backend-sched-ring` are in the same build tree:

```bash
docker compose run --rm --entrypoint bash server -c \
  '$HOME/.local/share/qwen3.8-strix-halo/build/llama.cpp/bin/llama-bench -m /models/some-model.gguf'
```

## 11. Rootless vs rootful Docker

| | rootless | rootful (system daemon) |
| :-- | :-- | :-- |
| container `root` | your host uid — files in the mounts stay yours | real root; files land root-owned |
| `STRIX_USER` | leave `root` | set `$(id -u):$(id -g)` |
| `STRIX_RENDER_GID` / `STRIX_VIDEO_GID` | usually irrelevant, the daemon already passes devices you may open | required, and the uid must be able to open the devices |
| `memlock` | capped by the daemon's own limit (`systemd` drop-in for the user service if needed) | set on the daemon unit |

The compose file never uses `privileged`, never adds capabilities, and never mounts the
docker socket or the host filesystem.

## 12. Troubleshooting

| Symptom | Cause and fix |
| :-- | :-- |
| `failed to initialize ROCm: no ROCm-capable device is detected` | Devices not passed, `seccomp` blocking HSA ioctls, or the container user cannot open `/dev/kfd`. Use the compose service rather than a hand-written `docker run`, and re-check section 3. |
| `the amdgpu kernel module is not loaded`, `gfx1151 was not detected in KFD topology` | Host driver/firmware problem. Update kernel and `amdgpu` firmware (`gc_11_5_0_*`); nothing in this image can fix it. |
| `the current user cannot access /dev/kfd` | Add the host user to `render`/`video`, log out, log back in, and confirm the rootless daemon was restarted afterwards. |
| `mkdir: cannot create directory '/home/strix/.local': Permission denied` | `STRIX_STATE_DIR` is not writable by `STRIX_USER`. Under rootless Docker use the default `STRIX_USER=root`. |
| `a complete ROCm SDK was not found` / `missing ROCm CMake package: …` | The image was rebuilt without the AMD repository reachable. `docker run --rm --entrypoint hipconfig qwen-next-toolbox:latest --version` should print `7.15.x`. |
| `xxd not found!` during the ROCr build | An image built before `xxd` was added to the package list (Fedora 44 split it out of `vim-common`). Rebuild. |
| HIP crashes, `MES failed to respond`, or hangs at model load | Host kernel or amdgpu firmware too old for Strix Halo. Update the host, then retest with `ENABLE_RETAINED_PM4=0` to separate the fork's graph path from the driver. |
| Allocation failures, or the OOM killer wins | Something else is holding unified memory. Close other GPU users, lower `CTX_SIZE`/`PARALLEL`, or drop `UBATCH_SIZE` to 8192. `docker compose exec server rocm-smi -u` and `free` on the host show what is holding what. |
| Download stalls or a shard is corrupt | Rerun the setup service. To discard half-finished data: `rm -rf "$STRIX_MODEL_DIR/.cache/huggingface"`. |
| `server` starts and immediately exits with `No such file or directory` | The launchers do not exist yet — finish a `setup` run first. |
| Port 8080 already in use | Change `STRIX_PORT`. |
| Weird symbol errors after a `docker compose build` that pulled a new ROCm | Versioned paths (`/opt/rocm/core-10.0`) are baked into the generated launchers. Rerun `setup`; if it persists, delete `STRIX_STATE_DIR/.local/share/qwen3.8-strix-halo` and rebuild from scratch. |

## 13. Reference

**Inside the container**

```
/home/strix/.local/bin/qwen3.8-strix-halo-server        tuned launcher for flash-next
/home/strix/.local/bin/llama-server-strix-halo          generic wrapper, sets LD_LIBRARY_PATH
/home/strix/.local/share/qwen3.8-strix-halo/
  src/{rocm-systems,llama.cpp}                          pinned checkouts
  build/{rocr,hip,llama.cpp}                            build trees; llama-server lives in build/llama.cpp/bin
  runtime/{rocr,hip}                                    the custom libhsa-runtime64 / libamdhip64
  venv/                                                 build + downloader Python environment
  cache/huggingface                                     HF/xet cache
/opt/rocm → /opt/rocm/core-10.0                         AMD SDK; never modified at runtime
```

A shell in the built environment:

```bash
docker compose run --rm --entrypoint bash server
```

**Runtime environment the launchers set** — `LD_LIBRARY_PATH` with the custom `hip`/`rocr`
prefixes first, then the SDK (`/opt/rocm/core/lib`, `…/lib/rocm_sysdeps/lib`);
`HSA_OVERRIDE_GFX_VERSION=11.5.1`; `GGML_HIP_ENABLE_UNIFIED_MEMORY=1`; `ENABLE_RETAINED_PM4=1`
with `DEBUG_HIP_GRAPH_PM4=1`, or `GGML_CUDA_DISABLE_GRAPHS=1` when it is disabled.

**Pins** — the ROCm and llama.cpp commits are recorded in the installer (`/opt/strix-halo/install.sh`); the image
tag of the AMD SDK is `amdrocm-core-devel10.0-gfx1151`. The installer refuses to move off its
pinned commits, so a rebuild stays reproducible until the installer itself changes. The image
fetches the installer from `main` by default; pin a commit with
`docker build --build-arg STRIX_HALO_REF=<sha> .` (or `docker compose build
--build-arg STRIX_HALO_REF=<sha> setup`) to freeze it.

**Upstream** — [installer and guide](https://github.com/pwilkin/strix-halo) ·
[amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) (container
layout this image derives from) ·
[write-up with the benchmarks](https://pwilkin.github.io/strix-halo/) ·
[llama.cpp fork](https://github.com/pwilkin/llama.cpp/tree/strix-halo) ·
[rocm-systems fork](https://github.com/pwilkin/rocm-systems/tree/ilintar-experiments) ·
[weights](https://huggingface.co/ilintar/qwen3.8-flash-next-gguf-strix-halo).
llama.cpp, ROCm, Qwen and the quantized weights remain under their respective licenses; the
wrapper files in this repository are MIT, as is the upstream installer.
