# Qwen3.8-Next-Flash toolbox for AMD Strix Halo (`gfx1151`)

Serve Qwen3.8-Flash-Next (177B) on a 128 GB Ryzen AI Max / Max+ (Radeon 8060S) using the ROCm/HIP
stack from [pwilkin/strix-halo](https://github.com/pwilkin/strix-halo). It all runs in Docker or
podman: nothing is installed on the host, and the host's `/opt/rocm` is left alone.

1. [Quick start](#1-quick-start)
2. [What you get](#2-what-you-get)
3. [Requirements](#3-requirements)
4. [Configure](#4-configure)
5. [Build the stack and download the weights](#5-build-the-stack-and-download-the-weights)
6. [Run llama-server](#6-run-llama-server)
7. [Other weights and arbitrary models](#7-other-weights-and-arbitrary-models)
8. [Tuning](#8-tuning)
9. [How updates work](#9-how-updates-work)
10. [Rootless vs rootful Docker](#10-rootless-vs-rootful-docker)
11. [Troubleshooting](#11-troubleshooting)
12. [Reference](#12-reference)

## 1. Quick start

Needs a 128 GB Strix Halo machine, Docker with the Compose v2 plugin or podman with a compose
backend, and about 110 GiB free. What to check on the host: [section 3](#3-requirements).

### Install and serve

```bash
cp .env.example .env        # 1. config; the defaults suit rootless Docker
./setup.sh                  # 2. image, compile ROCr/HIP/llama.cpp, download ~97 GiB of weights
./run.sh                    # 3. serve on http://localhost:8080
curl -s localhost:8080/health   # {"status":"ok"} once the weights are mapped
```

Loading 93 GiB takes a while and the first request is slower than the rest: the weights are read on
demand, so the pages start cold. Both scripts choose Docker or podman on their own
(`--use-docker` / `--use-podman` to pick) and take `-h`. `setup.sh` is resumable, so interrupt and
rerun it any time; compiling takes under 10 minutes at the default `JOBS=16` and the rest is
download-bound. It also fetches the vision projector (~0.9 GiB), served by default unless you pass
`--no-mmproj`. `run.sh` serves in the background and prints the commands for logs and stopping;
`--no-detach` serves in the foreground. It recreates the container on every start, so an edited
`.env` always applies.

```bash
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Introduce Strix Halo in one line."}],"max_tokens":64}'
```

Any OpenAI-compatible client can point at `http://localhost:8080/v1`.

### Check these before the first run

* Rootful (system) Docker: set `STRIX_USER=$(id -u):$(id -g)` in `.env`, see
  [rootless vs rootful](#10-rootless-vs-rootful-docker).
* `/dev/kfd` is not readable by your user: `sudo usermod -aG render,video $USER`, then log out and
  back in.
* `ulimit -l` should be `unlimited`. A rootless daemon cannot raise it above its own limit
  (systemd drop-in for the user service).
* You do not have 128 GB: this profile will not fit, but the smaller `qwen38-27b` one does, see
  [the 27B variant](#the-27b-variant).

### Update

```bash
./setup.sh -u    # 1. take the current upstream pins, rebuild the image, recompile
./run.sh         # 2. serve on the new binaries
```

That is the whole update, and `-u` is the only command that reaches upstream. Nothing is uninstalled
and no weights are re-downloaded, the ~9 GB of ROCm layers come from the image cache, and the engine
recompiles incrementally. Every `setup.sh` run prints a `pins ->` line naming what it will build
against: a bare commit means image and stack agree, `-> <commit>` means the build will move, and
`STEP BACK` means the image pins something older than the build in `state/`, in which case `setup.sh`
stops instead of recompiling backwards.

| When | Run |
| :-- | :-- |
| the server log says the built stack and the image disagree | `./setup.sh` |
| behaviour looks stale, or a binary does not match its pins | `./setup.sh --rebuild-state` |
| an older upstream is wanted on purpose | `STRIX_HALO_REF=<installer commit> ./setup.sh` |
| image cache or package list looks broken | `docker compose build --no-cache setup` |

How the pins and the cache behind all this work: [section 9](#9-how-updates-work).

## 2. What you get

| Layer | Source | Result |
| :-- | :-- | :-- |
| ROCm runtime | `pwilkin/rocm-systems@ilintar-experiments`, retained PM4 command lists | custom `libhsa-runtime64`, built into the state directory |
| HIP runtime | the same fork, `projects/clr` and `projects/hip` | custom `libamdhip64` |
| Engine | `pwilkin/llama.cpp@strix-halo`: UMA scheduler ring, wave32 `TOP_K`, gfx1151 tuning, MTP speculation | `llama-server`, `llama-bench`, `test-backend-sched-ring` |
| Weights | `ilintar/qwen3.8-flash-next-gguf-strix-halo`, `unsloth/Qwen3.8-Flash-Next-GGUF` | 9 × IQ4_NL `PROJFIX` shards (93 GiB), `mtp-…-shared-Q8_0.gguf` draft (2.8 GiB), `mmproj-BF16.gguf` projector (0.9 GiB) |
| ROCm SDK | AMD Core SDK 10.0 (TheRock stream), `amdrocm{,-core-devel}10.0-gfx1151` | `hipcc`, AMD LLVM, rocBLAS/hipBLAS with gfx1151 kernels |

Upstream measured this configuration on a Radeon 8060S at batch and ubatch 16384:

| Context | Prefill t/s | Decode t/s |
| :-- | --: | --: |
| 0 | 1204.31 ± 2.31 | 26.28 ± 0.29 |
| 40 000 | 1086.29 ± 0.96 | 16.63 ± 0.14 |

Prefill is the tuned path; upstream says decode is not there yet.

## 3. Requirements

Linux x86_64 with `amdgpu` loaded, `gfx1151` in the KFD topology and `gc_11_5_0` firmware (a kernel
from 2025 or newer is a safe bet), Docker with the Compose v2 plugin or podman with a compose
backend, 128 GB unified memory, and about 110 GiB free for the weights plus 3 GiB for build state.
The two mounted directories may live anywhere. The container inherits whatever devices your user can
open; `memlock` should be as high as the daemon allows.

Check the devices by hand:

```bash
test -r /dev/kfd -a -w /dev/kfd && echo "kfd ok"
ls -l /dev/dri/renderD*
awk '$1 == "gfx_target_version" && $2 != 0 { print $2 }' \
    /sys/class/kfd/kfd/topology/nodes/*/properties      # want: 110501
```

Or check the whole chain after the image is built, without building the stack:

```bash
docker compose --profile setup run --rm setup \
  bash /opt/strix-halo/install-flash-next.sh --check-only --skip-packages --model-dir /models
```

The tail should read `All prerequisite checks passed.`

## 4. Configure

`docker compose` reads `.env` automatically. Copy `.env.example` and adjust; the defaults work for
rootless Docker, and both mounted directories must be writable by the container user.

| Variable | Default | Meaning |
| :-- | :-- | :-- |
| `STRIX_STATE_DIR` | `./state` | Mounted as the container's `$HOME`: checkouts, build trees, venv, HF cache, launchers. Deleting it starts over. |
| `STRIX_MODEL_DIR` | `./models` | Mounted at `/models`, where the weights live. |
| `STRIX_MODEL_DIR_EXTRA` | empty | Extra host weights directory mounted at `/models-extra`; falls back to `STRIX_MODEL_DIR`. |
| `STRIX_PORT` | `8080` | Host port for the API. |
| `JOBS` | `16` | Build parallelism. |
| `HF_TOKEN` | empty | Only if the weight repository is gated. |
| `STRIX_USER` | `root` | Container user, see [rootless vs rootful](#10-rootless-vs-rootful-docker). |
| `STRIX_RENDER_GID`, `STRIX_VIDEO_GID` | `303`, `26` | Host GIDs owning `/dev/kfd` and `/dev/dri/renderD128`: `getent group render video \| cut -d: -f3`. |
| `STRIX_SHM_SIZE` | `8g` | `/dev/shm` size. |
| `MODEL_FILE`, `DRAFT_MODEL`, `MMPROJ_FILE` | pinned set | Which weights to serve, see [section 7](#7-other-weights-and-arbitrary-models). |
| `CTX_SIZE`, `BATCH_SIZE`, `UBATCH_SIZE`, `PARALLEL`, `MTP_N_MAX`, `NGRAM_MOD`, `ENABLE_RETAINED_PM4`, `GPU_MAX_HW_QUEUES`, `MODEL_ALIAS` | see [tuning](#8-tuning) | Launcher knobs. |

## 5. Build the stack and download the weights

```bash
docker compose build setup    # optional; ./setup.sh builds it if it is missing
./setup.sh
```

A container is needed because the installer builds against a complete, current ROCm 10 SDK under one
`$ROCM_ROOT`, which most distributions do not package and AMD ships only for Fedora/RHEL and Ubuntu.
The image is a Fedora 44 base fed from `stable.repo.amd.com` (~9 GB) that installs
`amdrocm10.0-gfx1151` and `amdrocm-core-devel10.0-gfx1151` plus the installer's build dependencies,
so the build never calls a package manager. The host contributes only the kernel driver and
firmware. The image also carries the upstream installer under `/opt/strix-halo/`, downloaded at
build time rather than checked in. Nothing from this repository is copied into the image, so neither
the weights nor `.env` reach the daemon (see `.dockerignore`).

`./setup.sh` then runs that installer in `STRIX_STATE_DIR` and `STRIX_MODEL_DIR`: it re-checks the
host, creates a Python venv, clones `rocm-systems` and `llama.cpp` at the recorded pins, builds ROCr,
then HIP against it, then llama.cpp for `gfx1151`, downloads the shards and the MTP draft with
SHA-256 verification, and writes the launchers into `state/.local/bin/`. Launchers come last, so
the server cannot start until one run finishes cleanly.

Reruns verify instead of redoing: git pins are re-checked, CMake builds are incremental, partial
downloads resume from `<STRIX_MODEL_DIR>/.cache/huggingface`, and any file already present is
hash-checked. Extra flags go to the installer, e.g. `./setup.sh --jobs 8`. When incremental is not
enough, `./setup.sh --rebuild-state` compiles from scratch; see
[section 9](#9-how-updates-work).

### Bringing your own weights

These exact filenames in `STRIX_MODEL_DIR` are verified and kept by the next `setup` run (names and
sums live in `/opt/strix-halo/install.sh`):

```
Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf   … through 00009
mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
```

A checksum mismatch is a hard error rather than a silent re-download; delete or fix the file and
rerun. `setup` always fetches the pinned set, so if you never serve it you can delete those files
afterwards, knowing that the next run downloads them again. Any other weights need no `setup` run
at all ([section 7](#7-other-weights-and-arbitrary-models)).

The vision projector is not in the upstream pins, so this repository pins `mmproj-BF16.gguf` from
[unsloth/Qwen3.8-Flash-Next-GGUF](https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF) and
`setup.sh` fetches it after the installer with the same verify-or-refuse rule. `--no-mmproj` skips
the download.

### The 27B variant

Upstream's `/opt/strix-halo/install.sh` defaults to the smaller `qwen38-27b` profile (~30 GiB of
IQ4_XS weights, a DFlash2 draft, a projector):

```bash
docker compose --profile setup run --rm setup bash /opt/strix-halo/install.sh --skip-packages --model-dir /models
```

Both profiles install launchers under the same names, so keep a separate state directory for each.
`serve.sh` applies the flash-next flag set (MTP speculation, 16384 batch), so run the upstream
launcher for 27B instead:

```bash
docker compose run --rm --service-ports \
  --entrypoint /home/strix/.local/bin/qwen3.8-strix-halo-server \
  server --host 0.0.0.0 --port 8080
```

## 6. Run llama-server

```bash
./run.sh                    # background; prints the logs and stop commands
./run.sh --no-detach        # foreground, Ctrl-C stops
curl -s localhost:8080/props | head
docker compose stop server  # or: down
```

`scripts/serve.sh` is the container entrypoint and applies the tuned configuration:
`-dev ROCm0 -ngl 999 -fa on -fit off`, `--load-mode none --lazy-mode on-direct` (keeps the 27.5 GB
per-layer embedding table out of the resident set), `f16` KV, 262144-token context (upstream's
launcher uses 65536), batch and ubatch 16384, `--jinja`, `--alias`, MTP speculation with draft width
3, and draftless `ngram-mod` speculation. It takes the engine and pinned-weight paths from
`state/.local/share/qwen3.8-strix-halo/config.sh` and re-derives nothing. See
[section 7](#7-other-weights-and-arbitrary-models) for the weights and [section 8](#8-tuning) for
the knobs.

Arguments appended to the service come last, so they win:

```bash
docker compose run --rm --service-ports server --api-key "$(openssl rand -hex 16)" --parallel 2
```

Plain `docker run` works too. The devices, `seccomp=unconfined` for the HSA ioctls, `memlock` for
pinning weights and the three mounts are all required: the built runtimes live in `state/` on the
host and `serve.sh` is read from the repo.

```bash
docker run --rm -it \
  --device /dev/kfd --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1:-1 --shm-size 8g \
  -e HF_TOKEN -e CTX_SIZE=262144 -e MTP_N_MAX=3 \
  -v "$PWD/state:/home/strix" \
  -v /path/to/models:/models \
  -v "$PWD/scripts/serve.sh:/opt/toolbox/serve.sh:ro" \
  -p 8080:8080 \
  --entrypoint /opt/toolbox/serve.sh \
  qwen-next-toolbox:latest --host 0.0.0.0 --port 8080
```

`rocm-smi` and `rocminfo` ship in the image (`docker compose exec server rocm-smi -u`). On an APU
the "VRAM" counters only cover the small carve-out; watch unified memory with `free` on the host.

## 7. Other weights and arbitrary models

Any GGUF works in place of the pinned shards: another quant, your own merge, a quantized fine-tune.
Put it in `STRIX_MODEL_DIR` and name it in `.env` or per invocation.

```bash
MODEL_FILE=Qwen3.8-Next-IQ4_XS-00001-of-00003.gguf docker compose up -d server      # split set: name shard 1
MODEL_FILE=my-merge-Q8_0.gguf DRAFT_MODEL=my-merge-mtp-Q8_0.gguf docker compose up -d server
MODEL_FILE=some-model-IQ3.gguf DRAFT_MODEL=builtin docker compose up -d server      # MTP head inside the main GGUF
MODEL_FILE=some-model-IQ3.gguf DRAFT_MODEL=none docker compose up -d server         # no MTP draft (ngram-mod stays on)
MMPROJ_FILE=none docker compose up -d server                                        # text-only: no vision projector
# Weights already on disk elsewhere: mount them with STRIX_MODEL_DIR_EXTRA (at /models-extra) and
# use the absolute container path:
STRIX_MODEL_DIR_EXTRA=/data/models/UD-Q4_K_XL \
  MODEL_FILE=/models-extra/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf docker compose up -d server
```

| Variable | Meaning |
| :-- | :-- |
| `MODEL_FILE` | Main weights. A bare name resolves under `/models`; an absolute path must be mounted (`/models-extra/...` for `STRIX_MODEL_DIR_EXTRA`). Default: the pinned shard `…-00001-of-00009.gguf`. |
| `DRAFT_MODEL` | MTP draft: a sidecar file (bare name = under `/models`), `builtin` to run speculation off the nextn head inside `MODEL_FILE`, or `none` to drop `draft-mtp` (`NGRAM_MOD=0` turns speculation off entirely). Default: the pinned `mtp-…-shared-Q8_0.gguf`. Weights converted without MTP tensors fail at load naming missing `blk.N.nextn.*`. |
| `MMPROJ_FILE` | Vision projector. Empty, the default, serves `mmproj-BF16.gguf` when `./setup.sh` has downloaded it; `none` drops `--mmproj`; anything else must be a file that exists. A served projector adds `--image-min-tokens 1024`, the floor Qwen-VL needs for grounding, and about 1 GiB resident. |

`serve.sh` checks that every file it was told to use exists and exits naming the variable. Only the
default projector is optional: without it the server logs that it is serving text-only and starts
anyway. To override a weight for one run, append the flag instead of setting the variable:
`docker compose run --rm --service-ports server -- -m /models/other.gguf`.

The second launcher runs any GGUF under the custom runtime with no opinionated flags:

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

## 8. Tuning

Set in `.env`, or per invocation (`CTX_SIZE=32768 docker compose up -d server`).

| Variable | Default | Notes |
| :-- | :-- | :-- |
| `CTX_SIZE` | `262144` | The memory-limiting knob on 128 GB. With `-fit off` nothing shrinks automatically, so an impossible request fails instead of backing off; drop to `65536` or `131072` if the model loads but a long prompt does not. |
| `BATCH_SIZE`, `UBATCH_SIZE` | `16384` | The tuned prefill path. A larger ubatch measures the same within error and costs about 8 GiB of compute buffers. |
| `MTP_N_MAX` | `3` | MTP draft width (`--spec-draft-n-max`). `0` drops the MTP draft, `builtin` included; ngram-mod keeps running unless `NGRAM_MOD=0`. |
| `NGRAM_MOD` | `1` | Draftless n-gram speculation, listed after `draft-mtp` in `--spec-type`. No weights, about 16 MB of hash pool shared by all slots, and it drafts repeated text and code. llama.cpp prefers it, so the MTP head drafts when the pool has nothing. `0` disables it. |
| `NGRAM_MOD_N_MATCH`, `NGRAM_MOD_N_MIN`, `NGRAM_MOD_N_MAX` | empty | ngram-mod lookup length and draft range. Empty keeps the llama.cpp defaults `24`/`48`/`64`, already sized for a MoE target; smaller drafts usually help dense models. |
| `PARALLEL` | `1` | Slots. Each extra slot costs KV memory and decode throughput on an APU. |
| `ENABLE_RETAINED_PM4` | `1` | The fork's retained PM4 command lists. `0` sets `GGML_CUDA_DISABLE_GRAPHS=1`, as an A/B control or if graphs misbehave. |
| `GPU_MAX_HW_QUEUES` | `1` | Keeps the iGPU from latching to max clock when idle. |
| `MODEL_ALIAS` | `Qwen 3.8 Flash Next` | Name served to API clients (`--alias`), comma-separated for several. Appears in `/props`, `/v1/models` and the `model` field. |
| `HSA_OVERRIDE_GFX_VERSION` | `11.5.1` | Set by the launcher; override only if you know why. |
| `GGML_HIP_ENABLE_UNIFIED_MEMORY` | `1` | Set by the launcher. |

## 9. How updates work

The pins are two commits, `llama_repo_commit` and `rocm_repo_commit`, recorded in the upstream
installer that the image carries at `/opt/strix-halo/install.sh`. Every build checks out exactly
those commits, so updating means putting a newer installer into the image, which is what `-u` does.
It passes a `BUILD_ID` that changes on each run: the layer that downloads the installer then misses
the cache while the ~9 GB of ROCm layers above it are reused, and the id is remembered in
`.strix-build-id` so later plain runs hit that same layer. Falling back to `BUILD_ID=0` would match
the installer of the very first build and move `:latest` back to its pins.

`state/.local/share/qwen3.8-strix-halo/pins.env` records the pins of the last successful build, and
`serve.sh` compares it with the image it starts in and warns in the server log when the two disagree.
`setup.sh` refuses to compile backwards; naming an older installer is also the rollback path, since
the installer itself is fetched by commit:

```bash
STRIX_HALO_REF=<installer commit> ./setup.sh
./run.sh
```

A setup run fast-forwards the `llama.cpp` checkout to the new pin, rebuilds incrementally, gates on
`test-backend-sched-ring`, and writes the launchers last, so a run that fails halfway leaves the
previous build in place. ROCr and HIP follow the same rule with their own pins. The checkouts have to
be clean: the installer will not move a tree with local changes (`git -C
state/.local/share/qwen3.8-strix-halo/src/llama.cpp status`).

To see where you stand without reading the setup output:

```bash
git -C state/.local/share/qwen3.8-strix-halo/src/llama.cpp log --oneline -1   # built from
docker run --rm --entrypoint grep qwen-next-toolbox:latest \
  -e llama_repo_commit -e rocm_repo_commit /opt/strix-halo/install.sh         # in the image now
```

`./setup.sh --rebuild-state` deletes `build/` and `runtime/` in the state directory and compiles
ROCr, HIP and llama.cpp from scratch, keeping the `src/` checkouts, the venv and every weight. If
even that is suspect, `docker compose build --no-cache setup` rebuilds the image including the AMD
packages, and `rm -rf "$STRIX_STATE_DIR"` starts over from nothing, venv and download cache
included.

## 10. Rootless vs rootful Docker

| | rootless | rootful (system daemon) |
| :-- | :-- | :-- |
| container `root` | your host uid, so files in the mounts stay yours | real root; files land root-owned |
| `STRIX_USER` | leave `root` | `$(id -u):$(id -g)` |
| `STRIX_RENDER_GID`, `STRIX_VIDEO_GID` | usually irrelevant, the daemon already passes devices you may open | required, and the uid must be able to open the devices |
| `memlock` | capped by the daemon's own limit (systemd drop-in for the user service) | set on the daemon unit |

Compose never uses `privileged`, never adds capabilities, and never mounts the docker socket or the
host filesystem.

## 11. Troubleshooting

| Symptom | Cause and fix |
| :-- | :-- |
| `failed to initialize ROCm: no ROCm-capable device is detected` | Devices not passed, `seccomp` blocking HSA ioctls, or the container user cannot open `/dev/kfd`. Use the compose service rather than a hand-written `docker run`, and re-check [section 3](#3-requirements). |
| `the amdgpu kernel module is not loaded`, `gfx1151 was not detected in KFD topology` | Host driver or firmware. Update the kernel and `amdgpu` firmware (`gc_11_5_0_*`); nothing in this image can fix it. |
| `the current user cannot access /dev/kfd` | Add the host user to `render`/`video`, log out and back in, then confirm the rootless daemon restarted. |
| `mkdir: cannot create directory '/home/strix/.local': Permission denied` | `STRIX_STATE_DIR` is not writable by `STRIX_USER`. Under rootless Docker, use the default `STRIX_USER=root`. |
| `a complete ROCm SDK was not found`, `missing ROCm CMake package: …` | Image rebuilt without the AMD repository reachable. `docker run --rm --entrypoint hipconfig qwen-next-toolbox:latest --version` should print `7.15.x`. |
| `xxd not found!` during the ROCr build | Image built before `xxd` was added to the package list (Fedora 44 split it out of `vim-common`). Rebuild. |
| HIP crashes, `MES failed to respond`, hangs at model load | Host kernel or firmware too old for Strix Halo. Update the host, then retest with `ENABLE_RETAINED_PM4=0` to separate the fork's graph path from the driver. |
| Allocation failures, OOM killer wins | Something else holds unified memory. Close other GPU users, lower `CTX_SIZE`/`PARALLEL`, or drop `UBATCH_SIZE` to 8192. `docker compose exec server rocm-smi -u` and `free` show what holds what. |
| Download stalls or a shard is corrupt | Rerun `./setup.sh`. To discard half-finished data: `rm -rf "$STRIX_MODEL_DIR/.cache/huggingface"`. |
| `server` exits immediately with `No such file or directory`, or `serve.sh: … config.sh not found` | The build never finished, so the launchers and `config.sh` do not exist. Finish a `./setup.sh` run. |
| `serve.sh: no such model / draft model: …` | Typo, or the file is not under `STRIX_MODEL_DIR` (`/models`). Absolute paths must be mounted separately. Use `DRAFT_MODEL=builtin` when the main GGUF carries its own MTP head. |
| Load fails with missing `blk.N.nextn.*` tensors under `DRAFT_MODEL=builtin` | Those weights were converted without the MTP head. Serve the sidecar draft instead, or `DRAFT_MODEL=none`. |
| `serve.sh: no such projector: … (MMPROJ_FILE)` | `MMPROJ_FILE` names a file that is not under `STRIX_MODEL_DIR`. `./setup.sh` fetches the pinned one, unless a previous run used `--no-mmproj`. |
| `serve.sh: note: no projector at …, serving text-only` | Informational: the pinned projector is not in `STRIX_MODEL_DIR`. Run `./setup.sh`, or keep it text-only. |
| Port 8080 already in use | Change `STRIX_PORT`. |
| Rebuild "succeeded" but the pins are unchanged | The installer layer came from the cache. Rebuild with `./setup.sh -u`, or `docker compose build --no-cache setup`. |
| `setup.sh: the image pins older commits than the stack in …` | The image moved behind the build in `STRIX_STATE_DIR` (`STEP BACK` in the `pins ->` line). `./setup.sh -u` for current pins, `STRIX_HALO_REF=<installer-commit> ./setup.sh` if the move back is deliberate. |
| `serve.sh: WARNING the built stack and this image disagree` | `:latest` was re-pointed since the last build, or the state directory was swapped. Rerun `./setup.sh`, or `./setup.sh --rebuild-state` if the binaries look stale. |
| Weird symbol errors after a build that pulled a new ROCm | The launchers bake in versioned paths (`/opt/rocm/core-10.0`). Rerun `./setup.sh`, then `--rebuild-state`; delete `STRIX_STATE_DIR/.local/share/qwen3.8-strix-halo` only if both fail. |

## 12. Reference

```
Dockerfile              Fedora 44 + AMD ROCm 10.0 gfx1151 SDK + build dependencies
compose.yaml            setup (profile "setup") and server services
.env / .env.example     host paths, port, credentials, launcher knobs, weight overrides
.strix-build-id         last BUILD_ID used, so plain runs do not fall back to a cached installer
.dockerignore           keeps weights, state and .env out of the build context
setup.sh                host entry point: build the image, compile the stack, download the weights
run.sh                  host entry point: serve with the .env settings (detached; --no-detach)
scripts/serve.sh        entrypoint of the server service: tuned launch + weight overrides
state/                  build output and generated launchers (created on first run)
models/                 weights (created on first run)
```

Inside the container:

```
/opt/toolbox/serve.sh                                   server entrypoint (mounted from scripts/)
/home/strix/.local/bin/qwen3.8-strix-halo-server        upstream tuned launcher for flash-next
/home/strix/.local/bin/llama-server-strix-halo          generic wrapper, sets LD_LIBRARY_PATH
/home/strix/.local/share/qwen3.8-strix-halo/
  src/{rocm-systems,llama.cpp}                          pinned checkouts
  build/{rocr,hip,llama.cpp}                            build trees; llama-server in build/llama.cpp/bin
  runtime/{rocr,hip}                                    custom libhsa-runtime64 / libamdhip64
  venv/                                                 build and downloader Python environment
  cache/huggingface                                     HF/xet cache
  config.sh                                             what serve.sh reads: engine + pinned weights
  pins.env                                              pins stamped by setup.sh, checked by serve.sh
/opt/rocm -> /opt/rocm/core-10.0                        AMD SDK, never modified at runtime
```

A shell in the built environment: `docker compose run --rm --entrypoint bash server`. The launchers
put the custom `hip`/`rocr` prefixes first on `LD_LIBRARY_PATH`, then the SDK.

Upstream: [installer and guide](https://github.com/pwilkin/strix-halo) ·
[llama.cpp fork](https://github.com/pwilkin/llama.cpp/tree/strix-halo) ·
[rocm-systems fork](https://github.com/pwilkin/rocm-systems/tree/ilintar-experiments) ·
[weights](https://huggingface.co/ilintar/qwen3.8-flash-next-gguf-strix-halo) ·
[benchmarks write-up](https://pwilkin.github.io/strix-halo/). The container recipe (Fedora 44 base,
AMD package sets, `/opt/rocm/core*` layout, Compose device flags) comes from
[amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes). llama.cpp, ROCm, Qwen
and the quantized weights keep their own licenses; the wrapper files here are MIT, as is the upstream
installer.
