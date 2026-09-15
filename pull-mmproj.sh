#!/bin/sh
# Fetch the vision projector that serve.sh loads by default, into STRIX_MODEL_DIR (see .env).
#
# The projector is not part of the upstream installer's pinned set, so it is pinned here:
# unsloth/Qwen3.8-Flash-Next-GGUF/mmproj-F16.gguf, SHA-256 verified, partial files resumed. The
# repository also publishes mmproj-BF16.gguf, which is unstable in practice - not pinned here.
# Called by ./pull-models.sh and ./pull-models-podman.sh; safe to run on its own. Needs wget.
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
file=mmproj-F16.gguf
url=https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/$file
size=904004000
sha256=1f7b7f0b984cf065c604360c29c8098362ed61b290db0ff12c6f360bb1a8a980

model_dir=${STRIX_MODEL_DIR:-}
if [ -z "$model_dir" ] && [ -f "$here/.env" ]; then
  model_dir=$(sed -n 's/^STRIX_MODEL_DIR=//p' "$here/.env" | head -n 1)
fi
model_dir=${model_dir:-$here/models}
case $model_dir in
  ./*) model_dir=$here/${model_dir#./} ;;
  /*) ;;
  *) model_dir=$here/$model_dir ;;
esac
target=$model_dir/$file

sum() { sha256sum "$1" | cut -d' ' -f1; }

if [ -f "$target" ] && [ "$(sum "$target")" = "$sha256" ]; then
  printf 'projector     ok: %s (present, hash verified)\n' "$target"
  exit 0
fi
if [ -f "$target" ] && [ "$(wc -c < "$target")" -ge "$size" ]; then
  printf 'pull-mmproj.sh: %s is complete but does not match the pinned hash - delete it and rerun\n' "$target" >&2
  exit 1
fi

mkdir -p "$model_dir"
if [ -f "$target" ]; then
  printf 'projector     -> %s (resuming the partial download)\n' "$target"
else
  printf 'projector     -> %s (862 MiB)\n' "$target"
fi
wget -c -O "$target" "$url"
[ "$(sum "$target")" = "$sha256" ] || {
  printf 'pull-mmproj.sh: hash mismatch for %s - delete it and rerun\n' "$target" >&2
  exit 1
}
printf 'projector     ok: %s\n' "$target"
