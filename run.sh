#!/usr/bin/env bash
# Serve Qwen3.8-Next-Flash with llama-server, configuration from .env.
#
#   ./run.sh                 start in the background and print how to watch / stop it
#   ./run.sh --no-detach     run in the foreground; Ctrl-C stops the server
#
# The container is always recreated, so .env changes take effect on the next run.
set -euo pipefail

here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

usage() {
  cat <<'EOF'
Usage: ./run.sh [--no-detach] [--use-docker | --use-podman]

Starts the llama-server container with the settings from .env. The container is
recreated every time, so changed .env values are always applied. Loading the
weights takes a while; the API answers once /health reports "ok".

      --no-detach     run in the foreground; Ctrl-C stops the server
      --use-docker    use Docker even when podman is available
      --use-podman    use podman even when Docker is available
  -h, --help          show this help
EOF
}

die() {
  printf 'run.sh: %s\n' "$*" >&2
  exit 1
}

detach=1
engine=''
while (($#)); do
  case $1 in
    -h | --help) usage; exit 0 ;;
    --no-detach) detach=0 ;;
    --use-docker) engine=docker ;;
    --use-podman) engine=podman ;;
    *) die "unknown option: $1 (see ./run.sh -h)" ;;
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

[[ -f $here/.env ]] || printf 'note: no .env found, using defaults (cp .env.example .env to configure)\n'

port=${STRIX_PORT:-8080}
if [[ -z ${STRIX_PORT:-} && -f $here/.env ]]; then
  port=$(sed -n 's/^STRIX_PORT=//p' "$here/.env" | head -n 1)
  port=${port:-8080}
fi

if ((detach)); then
  "${compose[@]}" up -d --force-recreate server
  cat <<EOF

server is starting in the background (weights stay cold until first use).

  logs:   ${compose[*]} logs -f server
  health: curl -s localhost:${port}/health
  stop:   ${compose[*]} stop server
EOF
else
  printf 'serving in the foreground; Ctrl-C stops the server\n\n'
  exec "${compose[@]}" up --force-recreate server
fi
