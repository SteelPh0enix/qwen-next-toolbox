#!/bin/sh
# Fetch the Qwen3.8-Next-Flash weights the installer pins, into STRIX_MODEL_DIR (see .env).
#
# The file list and SHA-256 sums belong to the upstream installer
# (/opt/strix-halo/install.sh), so the download goes through it rather than duplicating
# the pins here. Build steps are incremental no-ops once the stack is built, and the run
# ends by writing the launchers into state/.
#
#   ./pull-models.sh                  # start or resume (~96 GiB total)
#   ./pull-models.sh --jobs 8         # extra flags go to the installer
#
# Interrupt it whenever you like: `hf` resumes partial files and every finished file is
# hash-verified before it is accepted. Needs ~110 GiB free on the model disk.
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)

model_dir=${STRIX_MODEL_DIR:-}
if [ -z "$model_dir" ] && [ -f "$here/.env" ]; then
  model_dir=$(sed -n 's/^STRIX_MODEL_DIR=//p' "$here/.env" | head -n 1)
fi

printf 'weights            -> %s\n' "${model_dir:-$here/models}"
printf 'builds, launchers  -> %s/state\n\n' "$here"

docker compose --project-directory "$here" --profile setup run --rm setup \
  bash /opt/strix-halo/install-flash-next.sh --skip-packages --model-dir /models "$@"

printf '\nlaunchers written to %s/state/.local/bin/\nstart with: docker compose up -d server\n' "$here"
