#!/usr/bin/env bash
# Entrypoint for the `server` service: the tuned Qwen3.8-Next-Flash launch, with the weights
# overridable from the environment (MODEL_FILE, DRAFT_MODEL, MMPROJ_FILE - see README section 8).
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
[[ -r $config ]] || die "$config not found - build the stack first (./pull-models.sh)"
# shellcheck disable=SC1090
source "$config"
[[ -x ${STRIX_GENERIC_WRAPPER:-} ]] || die "$config does not define an executable STRIX_GENERIC_WRAPPER"

model=$(resolve "${MODEL_FILE:-$STRIX_MAIN_MODEL}")
draft=${DRAFT_MODEL:-${STRIX_DFLASH_MODEL-}}
[[ $draft == none ]] && draft=''
mmproj=${MMPROJ_FILE:-${STRIX_MMPROJ_MODEL-}}
[[ -n $mmproj ]] && mmproj=$(resolve "$mmproj")

[[ -f $model ]] || die "no such model: $model (MODEL_FILE)"
[[ -z $draft || -f $draft ]] || die "no such draft model: $draft (DRAFT_MODEL)"
[[ -z $mmproj || -f $mmproj ]] || die "no such projector: $mmproj (MMPROJ_FILE)"

draft_n_max=${MTP_N_MAX:-3}

args=(
  -m "$model"
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
if ((draft_n_max > 0)) && [[ -n $draft ]]; then
  args+=(
    --spec-type draft-mtp
    --spec-draft-model "$draft"
    --spec-draft-device ROCm0
    --spec-draft-ngl 99
    --spec-draft-n-max "$draft_n_max"
  )
fi
if [[ -n $mmproj ]]; then
  args+=(--mmproj "$mmproj" --mmproj-device ROCm0)
fi

exec "$STRIX_GENERIC_WRAPPER" "${args[@]}" "$@"
