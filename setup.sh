#!/usr/bin/env bash
# Build the container image, compile the ROCm/llama.cpp stack and download the pinned weights.
#
#   ./setup.sh                image build (cached), then compile + download (resumable, hash-verified)
#   ./setup.sh -u             refresh the upstream install scripts first (new pins), recompile
#   ./setup.sh --mmproj       also fetch the vision projector (mmproj-F16.gguf, ~0.9 GiB)
#   ./setup.sh --jobs 8       flags we do not know are passed to the upstream installer
#
# Everything lives in STRIX_MODEL_DIR and state/ (see .env); re-running verifies instead of
# redoing. Needs ~110 GiB free on the model disk. Never touches the host system.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [-u] [--mmproj] [--use-docker | --use-podman] [installer flags...]

Builds the qwen-next-toolbox image, then runs the upstream installer from it: compiles
the custom ROCr/HIP/llama.cpp stack into state/ and downloads the pinned
Qwen3.8-Next-Flash weights (main shards + MTP draft) into the model directory.

  -u, --update        rebuild with the latest install scripts from
                      pwilkin/strix-halo (fresh upstream pins; the ~9 GB of ROCm
                      layers are reused from the cache)
      --mmproj        also download the vision projector (mmproj-F16.gguf)
      --use-docker    use Docker even when podman is available
      --use-podman    use podman even when Docker is available
  -h, --help          show this help

Any other flag (e.g. --jobs 8) is forwarded to the upstream installer
(bash /opt/strix-halo/install-flash-next.sh --help inside the container).

Serve the model afterwards with ./run.sh.
EOF
}

die() {
  printf 'setup.sh: %s\n' "$*" >&2
  exit 1
}

update=0
mmproj=0
engine=''
installer_args=()
while (($#)); do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -u | --update) update=1 ;;
    --mmproj) mmproj=1 ;;
    --use-docker) engine=docker ;;
    --use-podman) engine=podman ;;
    *) installer_args+=("$1") ;;
  esac
  shift
done

# --- pick a container engine -------------------------------------------
has_docker() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
has_podman() {
  command -v podman >/dev/null 2>&1 || return 1
  podman compose version >/dev/null 2>&1 || command -v podman-compose >/dev/null 2>&1
}
case $engine in
  docker) has_docker || die 'docker with the compose v2 plugin not found' ;;
  podman) has_podman || die 'podman with a compose backend not found; install podman-compose' ;;
  *)
    if has_docker; then
      engine=docker
      has_podman && printf 'note: both docker and podman found, using docker (--use-podman to override)\n'
    elif has_podman; then
      engine=podman
    else
      die 'neither docker (with the compose v2 plugin) nor podman (with podman-compose) found'
    fi
    ;;
esac
if [[ $engine == docker ]]; then
  compose=(docker compose)
elif podman compose version >/dev/null 2>&1; then
  compose=(podman compose)
else
  compose=(podman-compose)
fi

# --- build the image -----------------------------------------------------
# The image carries the upstream installer and the pins it records, so a fresh BUILD_ID is
# what picks up an upstream update: it invalidates only the layer that downloads the
# installer. STRIX_HALO_REF pins the installer itself (the rollback path).
if ((update)); then
  build_id=$(date -u +%Y%m%dT%H%M%SZ)
  printf 'image     -> rebuilding with the latest upstream install scripts\n'
else
  build_id=0
  printf 'image     -> building from cache (use ./setup.sh -u to pick up upstream updates)\n'
fi
if [[ $engine == docker ]]; then
  BUILD_ID="$build_id" "${compose[@]}" --profile setup build setup
else
  podman build --build-arg "BUILD_ID=$build_id" \
    --build-arg "STRIX_HALO_REF=${STRIX_HALO_REF:-main}" \
    -t qwen-next-toolbox:latest "$here"
fi

# --- build the stack, download the weights -------------------------------
printf '\nstack     -> compiling and downloading the pinned weights (resumable, interrupt any time)\n\n'
"${compose[@]}" --profile setup run --rm setup \
  bash /opt/strix-halo/install-flash-next.sh --skip-packages --model-dir /models "${installer_args[@]}"

# --- optional vision projector --------------------------------------------
# Not part of the upstream installer's pins, so it is pinned here and fetched with wget.
if ((mmproj)); then
  file='mmproj-F16.gguf'
  url="https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/$file"
  sha256=1f7b7f0b984cf065c604360c29c8098362ed61b290db0ff12c6f360bb1a8a980
  model_dir=${STRIX_MODEL_DIR:-}
  if [[ -z $model_dir && -f $here/.env ]]; then
    model_dir=$(sed -n 's/^STRIX_MODEL_DIR=//p' "$here/.env" | head -n 1)
  fi
  model_dir=${model_dir:-$here/models}
  case $model_dir in
    /*) ;;
    ./*) model_dir=$here/${model_dir#./} ;;
    *) model_dir=$here/$model_dir ;;
  esac
  target=$model_dir/$file
  if [[ -f $target ]] && [[ $(sha256sum "$target" | cut -d' ' -f1) == "$sha256" ]]; then
    printf 'projector -> ok, already present: %s\n' "$target"
  else
    command -v wget >/dev/null || die 'wget is required to fetch the projector'
    mkdir -p "$model_dir"
    printf 'projector -> %s (862 MiB, resumable)\n' "$target"
    wget -c -O "$target" "$url"
    [[ $(sha256sum "$target" | cut -d' ' -f1) == "$sha256" ]] ||
      die "hash mismatch for $target - delete it and rerun"
  fi
  printf '          note: serve it with MMPROJ_FILE=%s; it is unstable on this stack\n' "$file"
fi

printf '\ndone. launchers are in state/.local/bin/, serve the model with ./run.sh\n'
