#!/usr/bin/env bash
# Build the container image, compile the ROCm/llama.cpp stack and download the pinned weights.
#
#   ./setup.sh                image build (cached), then compile + download (resumable, hash-verified)
#   ./setup.sh -u             refresh the upstream install scripts first (new pins), recompile
#   ./setup.sh --rebuild-state  wipe the build trees first, compile ROCr/HIP/llama.cpp from scratch
#   ./setup.sh --no-mmproj    skip the vision projector download (mmproj-BF16.gguf, ~0.9 GiB)
#   ./setup.sh --jobs 8       flags we do not know are passed to the upstream installer
#
# Everything lives in STRIX_MODEL_DIR and state/ (see .env); re-running verifies instead of
# redoing. Needs ~110 GiB free on the model disk. Never touches the host system.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [-u] [--rebuild-state] [--no-mmproj]
                  [--use-docker | --use-podman] [installer flags...]

Builds the qwen-next-toolbox image, then runs the upstream installer from it: compiles
the custom ROCr/HIP/llama.cpp stack into state/ and downloads the pinned
Qwen3.8-Next-Flash weights (main shards + MTP draft + vision projector) into the model directory.

  -u, --update        rebuild with the latest install scripts from
                      pwilkin/strix-halo (fresh upstream pins; the ~9 GB of ROCm
                      layers are reused from the cache)
      --rebuild-state delete the ROCr/HIP/llama.cpp build trees in the state directory
                      before compiling: a from-scratch build for a stale CMake cache or a
                      suspect binary. The src checkouts, the venv and all weights are kept
      --no-mmproj     skip the vision projector download (mmproj-BF16.gguf)
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

# Read a setting the way compose does: the shell environment wins over .env. Parsed rather than
# sourced, because .env values are unquoted and hold spaces.
env_get() { # env_get KEY DEFAULT
  local key=$1 default=$2 value=${!1:-}
  if [[ -z $value && -f $here/.env ]]; then
    value=$(sed -n "s/^$key=//p" "$here/.env" | head -n 1 | tr -d '\r')
  fi
  printf '%s' "${value:-$default}"
}

# Absolute, ./relative or bare .env path -> absolute host path.
host_path() {
  case $1 in
    /*) printf '%s' "$1" ;;
    ./*) printf '%s' "$here/${1#./}" ;;
    *) printf '%s' "$here/$1" ;;
  esac
}

image=qwen-next-toolbox:latest
build_id_file=$here/.strix-build-id

update=0
mmproj=1
rebuild_state=0
engine=''
installer_args=()
while (($#)); do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -u | --update) update=1 ;;
    --rebuild-state) rebuild_state=1 ;;
    --no-mmproj) mmproj=0 ;;
    --use-docker) engine=docker ;;
    --use-podman) engine=podman ;;
    *) installer_args+=("$1") ;;
  esac
  shift
done

state_dir=$(host_path "$(env_get STRIX_STATE_DIR ./state)")
install_root=$state_dir/.local/share/qwen3.8-strix-halo

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
#
# The id is remembered in .strix-build-id so later plain runs re-hit that same fresh layer.
# Passing BUILD_ID=0 again would still be a cache hit - the layer from the very first build - and
# the image would silently move back to the pins that installer carries.
halo_ref=$(env_get STRIX_HALO_REF main)
if ((update)); then
  build_id=$(date -u +%Y%m%dT%H%M%SZ)
  printf 'image     -> rebuilding with the latest upstream install scripts\n'
elif [[ -s $build_id_file ]]; then
  build_id=$(<"$build_id_file")
  printf 'image     -> building from cache (use ./setup.sh -u to pick up upstream updates)\n'
else
  build_id=$(date -u +%Y%m%dT%H%M%SZ)
  printf 'image     -> no recorded BUILD_ID, fetching the current upstream install scripts\n'
fi
if [[ $engine == docker ]]; then
  BUILD_ID="$build_id" STRIX_HALO_REF="$halo_ref" "${compose[@]}" --profile setup build setup
else
  podman build --build-arg "BUILD_ID=$build_id" \
    --build-arg "STRIX_HALO_REF=$halo_ref" \
    -t "$image" "$here"
fi
printf '%s\n' "$build_id" > "$build_id_file"

# --- compare the pins in the image with the built stack -------------------
# The installer checks out exactly the commits its scripts record, so an image carrying older
# pins moves the whole stack back. Choosing pins deliberately means choosing an installer, which
# is what STRIX_HALO_REF is for; anything else here is a stale image and stops here.
installer_pins=$("$engine" run --rm --entrypoint grep "$image" \
  -E '^readonly (llama|rocm)_repo_commit' /opt/strix-halo/install.sh 2>/dev/null) || installer_pins=''
labels=(llama.cpp rocm-systems)
keys=(llama_repo_commit rocm_repo_commit)
pins=()
if [[ -z $installer_pins ]]; then
  printf 'pins      -> could not read them from %s, skipping the check\n' "$image"
else
  verdicts=()
  backwards=0
  for i in 0 1; do
    pins[i]=$(sed -n "s/^readonly ${keys[i]}=//p" <<<"$installer_pins")
    [[ -n ${pins[i]} ]] || continue
    head=''
    if command -v git >/dev/null 2>&1 && [[ -d $install_root/src/${labels[i]}/.git ]]; then
      head=$(git -C "$install_root/src/${labels[i]}" rev-parse HEAD 2>/dev/null) || true
    fi
    if [[ -z $head ]]; then
      verdicts+=("${labels[i]} ${pins[i]:0:8} new")
    elif [[ $head == "${pins[i]}" ]]; then
      verdicts+=("${labels[i]} ${pins[i]:0:8}")
    elif [[ -n ${pins[i]} ]] &&
      git -C "$install_root/src/${labels[i]}" merge-base --is-ancestor "${pins[i]}" HEAD 2>/dev/null; then
      verdicts+=("${labels[i]} ${head:0:8} -> ${pins[i]:0:8} STEP BACK")
      backwards=1
    else
      verdicts+=("${labels[i]} ${head:0:8} -> ${pins[i]:0:8}")
    fi
  done
  line=''
  for v in "${verdicts[@]}"; do line+="${line:+, }$v"; done
  [[ -n $line ]] && printf 'pins      -> %s\n' "$line"
  if ((backwards)) && [[ $halo_ref == main ]]; then
    die "the image pins older commits than the stack in $state_dir was built from; ./setup.sh -u takes the current upstream pins, STRIX_HALO_REF=<installer-commit> ./setup.sh moves back on purpose"
  fi
fi

# --- optional: compile from scratch ---------------------------------------
if ((rebuild_state)); then
  case $install_root in
    */.local/share/qwen3.8-strix-halo) ;;
    *) die "refusing to remove $install_root" ;;
  esac
  printf 'state     -> removing the build and runtime trees (src, venv, weights are kept)\n'
  rm -rf "$install_root/build" "$install_root/runtime"
fi

# --- build the stack, download the weights -------------------------------
printf '\nstack     -> compiling and downloading the pinned weights (resumable, interrupt any time)\n\n'
"${compose[@]}" --profile setup run --rm setup \
  bash /opt/strix-halo/install-flash-next.sh --skip-packages --model-dir /models "${installer_args[@]}"

# --- vision projector --------------------------------------------------------
# Not part of the upstream installer's pins, so it is pinned here and fetched with wget.
if ((mmproj)); then
  file='mmproj-BF16.gguf'
  url="https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/$file"
  sha256=2e788f8c511d8093c7b43cb87b2fd7e14228340318057f8fb20c86df2efe2355
  model_dir=$(host_path "$(env_get STRIX_MODEL_DIR ./models)")
  target=$model_dir/$file
  if [[ -f $target ]] && [[ $(sha256sum "$target" | cut -d' ' -f1) == "$sha256" ]]; then
    printf 'projector -> ok, already present: %s\n' "$target"
  else
    command -v wget >/dev/null || die 'wget is required to fetch the projector'
    mkdir -p "$model_dir"
    printf 'projector -> %s (866 MiB, resumable)\n' "$target"
    wget -c -O "$target" "$url"
    [[ $(sha256sum "$target" | cut -d' ' -f1) == "$sha256" ]] ||
      die "hash mismatch for $target - delete it and rerun"
  fi
  printf '          note: served by default; MMPROJ_FILE=none serves text-only\n'
fi

# --- record what this stack was built from --------------------------------
# serve.sh compares this stamp with the pins of the image it starts in: a cached image build can
# re-point :latest while the state directory stays where it was.
stamp=$install_root/pins.env
if [[ -n $installer_pins ]] && ( : >"$stamp" ) 2>/dev/null; then
  {
    printf '# written by ./setup.sh, consumed by scripts/serve.sh. Do not edit.\n'
    printf 'STRIX_HALO_REF=%s\n' "$halo_ref"
    printf 'STRIX_BUILD_ID=%s\n' "$build_id"
    printf 'STRIX_LLAMA_REPO_COMMIT=%s\n' "${pins[0]:-}"
    printf 'STRIX_ROCM_REPO_COMMIT=%s\n' "${pins[1]:-}"
  } >"$stamp"
elif [[ -n $installer_pins ]]; then
  printf 'note: cannot write %s, serve.sh will not be able to check the pins\n' "$stamp"
fi

printf '\ndone. launchers are in state/.local/bin/, serve the model with ./run.sh\n'
