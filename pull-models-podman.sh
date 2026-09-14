#!/bin/sh
# Fetch the Qwen3.8-Next-Flash weights the installer pins, into STRIX_MODEL_DIR (see .env).
# Podman compatibility script courtesy of https://github.com/Rose22/
#
# The file list and SHA-256 sums belong to the upstream installer
# (/opt/strix-halo/install-flash-next.sh), so the download goes through it rather than
# duplicating the pins here. Build steps are incremental no-ops once the stack is built,
# and the run ends by writing the launchers into state/.
#
#   ./pull-models.sh                  # start or resume (~96 GiB total)
#   ./pull-models.sh --jobs 8         # extra flags go to the installer
#
# Interrupt it whenever you like: `hf` resumes partial files and every finished file is
# hash-verified before it is accepted. Needs ~110 GiB free on the model disk.
#
# Uses podman. Set COMPOSE_BIN=podman-compose to force a specific compose backend.
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)

# --- pick a compose backend -------------------------------------------------
compose_bin=${COMPOSE_BIN:-}
if [ -n "$compose_bin" ]; then
  : # user override, trust it
elif podman compose version >/dev/null 2>&1; then
  compose_bin="podman compose"
elif command -v podman-compose >/dev/null 2>&1; then
  compose_bin="podman-compose"
else
  printf 'error: no compose backend found.\n' >&2
  printf 'install podman-compose (pacman -S podman-compose) or podman >= 4 with docker-compose enabled.\n' >&2
  exit 1
fi

model_dir=${STRIX_MODEL_DIR:-}
if [ -z "$model_dir" ] && [ -f "$here/.env" ]; then
  model_dir=$(sed -n 's/^STRIX_MODEL_DIR=//p' "$here/.env" | head -n 1)
fi

printf 'weights            -> %s\n' "${model_dir:-$here/models}"
printf 'builds, launchers  -> %s/state\n' "$here"
printf 'compose backend    -> %s\n\n' "$compose_bin"

# podman-compose doesn't understand --project-directory, so run from the project dir
cd "$here"

# shellcheck disable=SC2086
$compose_bin --profile setup run --rm setup \
  bash /opt/strix-halo/install-flash-next.sh --skip-packages --model-dir /models "$@"

printf '\nlaunchers written to %s/state/.local/bin/\nstart with: %s up -d server\n' \
  "$here" "$compose_bin"
