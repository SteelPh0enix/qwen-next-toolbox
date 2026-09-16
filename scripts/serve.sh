#!/usr/bin/env bash
# Entrypoint for the `server` service: the tuned Qwen3.8-Next-Flash launch, with the weights
# overridable from the environment (MODEL_FILE, DRAFT_MODEL, MMPROJ_FILE, MODEL_ALIAS - see
# README section 9).
# Projector: empty MMPROJ_FILE = the pinned mmproj-BF16.gguf when it exists (./setup.sh fetches it,
# absent means text-only); MMPROJ_FILE=none drops --mmproj.
#
# Paths to the built engine and to the pinned weights come from the config.sh that the
# installer writes; only the model selection is overridden here, never the ROCm wiring.
set -euo pipefail

die() {
  printf 'serve.sh: %s\n' "$*" >&2
  exit 1
}

# Bare names and relative paths resolve under the model mount; absolute paths are used as they are.
resolve() {
  case $1 in
  /*) printf '%s' "$1" ;;
  *) printf '%s/%s' /models "$1" ;;
  esac
}

config=${STRIX_HALO_INSTALL_ROOT:-$HOME/.local/share/qwen3.8-strix-halo}/config.sh
[[ -r $config ]] || die "$config not found - build the stack first (./setup.sh)"
# shellcheck disable=SC1090
source "$config"
[[ -x ${STRIX_GENERIC_WRAPPER:-} ]] || die "$config does not define an executable STRIX_GENERIC_WRAPPER"

# The built stack and the image it runs in move independently: a cached image build can re-point
# :latest without the state directory changing. setup.sh stamps the pins it built from.
stamp=$(dirname "$config")/pins.env
installer=/opt/strix-halo/install.sh
if [[ -r $stamp && -r $installer ]]; then
  drift=()
  for key in llama_repo_commit rocm_repo_commit; do
    built=$(sed -n "s/^STRIX_${key^^}=//p" "$stamp")
    pinned=$(sed -n "s/^readonly ${key}=//p" "$installer")
    if [[ -n $built && -n $pinned && $built != "$pinned" ]]; then
      drift+=("${key%%_repo_commit} built ${built:0:8}, image ${pinned:0:8}")
    fi
  done
  if ((${#drift[@]})); then
    printf 'serve.sh: WARNING the built stack and this image disagree: %s\n' "${drift[*]}" >&2
    printf 'serve.sh: rerun ./setup.sh to build what the image pins\n' >&2
  fi
fi

model=$(resolve "${MODEL_FILE:-$STRIX_MAIN_MODEL}")

# Draft: empty = the pinned sidecar draft; a file = that sidecar draft; builtin = the nextn head
# inside the main GGUF, so the spec block stays but carries no --spec-draft-model; none = no MTP
# draft, ngram-mod unaffected. Compose passes DRAFT_MODEL empty when .env leaves it blank, so the
# fallback has to use :- (an unset-only fallback would never fire).
draft=${DRAFT_MODEL:-${STRIX_DFLASH_MODEL:-}}
[[ $draft == none ]] && draft=''
[[ -n $draft && $draft != builtin ]] && draft=$(resolve "$draft")
mmproj=${MMPROJ_FILE:-}
mmproj_default=0
if [[ -z $mmproj ]]; then
  mmproj=${STRIX_MMPROJ_MODEL:-mmproj-BF16.gguf}
  mmproj_default=1
fi
[[ $mmproj == none ]] && mmproj=''
[[ -n $mmproj ]] && mmproj=$(resolve "$mmproj")

[[ -f $model ]] || die "no such model: $model (MODEL_FILE)"
[[ -z $draft || $draft == builtin || -f $draft ]] || die "no such draft model: $draft (DRAFT_MODEL)"
if [[ -n $mmproj && ! -f $mmproj ]]; then
  if ((mmproj_default)); then
    printf 'serve.sh: note: no projector at %s, serving text-only (./setup.sh fetches it)\n' "$mmproj" >&2
    mmproj=''
  else
    die "no such projector: $mmproj (MMPROJ_FILE; fetch it with ./setup.sh, disable with MMPROJ_FILE=none)"
  fi
fi

draft_n_max=${MTP_N_MAX:-3}

# ngram-mod is draftless speculation (~16 MB n-gram hash pool, shared by all slots): NGRAM_MOD=0
# turns it off, and it keeps drafting when the MTP draft is off.
ngram_mod=${NGRAM_MOD:-1}
ngram_mod_n_match=${NGRAM_MOD_N_MATCH:-}
ngram_mod_n_min=${NGRAM_MOD_N_MIN:-}
ngram_mod_n_max=${NGRAM_MOD_N_MAX:-}

# draft-mtp needs a draft (sidecar GGUF or the nextn head inside the main one); ngram-mod never does.
spec_types=()
draft_on=0
if ((draft_n_max > 0)) && [[ -n $draft ]]; then
  spec_types+=(draft-mtp)
  draft_on=1
fi
if [[ $ngram_mod != 0 ]]; then
  spec_types+=(ngram-mod)
fi

args=(
  -m "$model"
  --alias "${MODEL_ALIAS:-Qwen 3.8 Flash Next}"
  -dev ROCm0
  -ngl 999
  -fa on
  -fit off
  # --load-mode none with --lazy-mode on-direct is what keeps the 27.5 GB per-layer-embedding
  # table out of the resident set: the rows are pread() on demand instead of being faulted in
  # through an mmap that would also hold a second copy of every weight during load.
  --load-mode none
  --lazy-mode on-direct
  -ctk f16 -ctv f16
  -c "${CTX_SIZE:-65536}"
  -b "${BATCH_SIZE:-16384}"
  -ub "${UBATCH_SIZE:-16384}"
  --parallel "${PARALLEL:-1}"
  --jinja
)
if ((${#spec_types[@]})); then
  args+=(--spec-type "$(
    IFS=,
    printf '%s' "${spec_types[*]}"
  )")
  if ((draft_on)); then
    args+=(--spec-draft-n-max "$draft_n_max")
    if [[ $draft != builtin ]]; then
      args+=(--spec-draft-model "$draft" --spec-draft-device ROCm0 --spec-draft-ngl 99)
    fi
  fi
  # Unset ngram knobs are not passed, so llama.cpp keeps its own defaults (24 / 48 / 64).
  if [[ $ngram_mod != 0 ]]; then
    if [[ -n $ngram_mod_n_match ]]; then args+=(--spec-ngram-mod-n-match "$ngram_mod_n_match"); fi
    if [[ -n $ngram_mod_n_min ]]; then args+=(--spec-ngram-mod-n-min "$ngram_mod_n_min"); fi
    if [[ -n $ngram_mod_n_max ]]; then args+=(--spec-ngram-mod-n-max "$ngram_mod_n_max"); fi
  fi
fi
if [[ -n $mmproj ]]; then
  # Qwen-VL needs >=1024 image tokens for grounding; below that llama-server warns and accuracy suffers.
  args+=(--mmproj "$mmproj" --mmproj-device ROCm0 --image-min-tokens 1024)
fi

exec "$STRIX_GENERIC_WRAPPER" "${args[@]}" "$@"
