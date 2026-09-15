#!/usr/bin/env bash
# Entrypoint for the `server` service: the tuned Qwen3.8-Next-Flash launch, with the weights
# overridable from the environment (MODEL_FILE, DRAFT_MODEL, MMPROJ_FILE, MODEL_ALIAS - see
# README section 9).
# Projector: empty MMPROJ_FILE = mmproj-F16.gguf, fetched by ./setup.sh --mmproj;
# MMPROJ_FILE=none drops --mmproj. Projector support crashes llama-server on this stack, so
# .env ships none.
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

model=$(resolve "${MODEL_FILE:-$STRIX_MAIN_MODEL}")

# Draft: a file = sidecar MTP draft; builtin = the nextn head inside the main GGUF, so the spec
# block stays but carries no --spec-draft-model; none/empty = no MTP draft, ngram-mod unaffected.
draft=${DRAFT_MODEL-${STRIX_DFLASH_MODEL:-}}
[[ $draft == none ]] && draft=''
[[ -n $draft && $draft != builtin ]] && draft=$(resolve "$draft")
mmproj=${MMPROJ_FILE:-${STRIX_MMPROJ_MODEL:-mmproj-F16.gguf}}
[[ $mmproj == none ]] && mmproj=''
[[ -n $mmproj ]] && mmproj=$(resolve "$mmproj")

[[ -f $model ]] || die "no such model: $model (MODEL_FILE)"
[[ -z $draft || $draft == builtin || -f $draft ]] || die "no such draft model: $draft (DRAFT_MODEL)"
[[ -z $mmproj || -f $mmproj ]] || die "no such projector: $mmproj (MMPROJ_FILE; fetch it with ./setup.sh --mmproj, disable with MMPROJ_FILE=none)"

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
  args+=(--spec-type "$(IFS=,; printf '%s' "${spec_types[*]}")")
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
  args+=(--mmproj "$mmproj" --mmproj-device ROCm0)
fi

exec "$STRIX_GENERIC_WRAPPER" "${args[@]}" "$@"
