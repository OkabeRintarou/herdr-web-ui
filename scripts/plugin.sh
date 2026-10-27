#!/bin/sh
# Entry point for herdr plugin build/startup/actions: build | start | stop | status
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REL="$ROOT/_build/prod/rel/herdr_liveview/bin/herdr_liveview"
SOCKET=${HERDR_SOCKET_PATH:-"$HOME/.config/herdr/herdr.sock"}

# One instance per herdr session, keyed by its socket path.
SID=$(printf '%s' "$SOCKET" | cksum | cut -d' ' -f1)
STATE="${HERDR_PLUGIN_STATE_DIR:-$ROOT/.state}/$SID"

mix_run() {
  if command -v mise >/dev/null 2>&1; then
    mise trust -q "$ROOT/mise.toml" >/dev/null 2>&1 || true
    (cd "$ROOT" && MIX_ENV=prod mise exec -- mix "$@")
  else
    (cd "$ROOT" && MIX_ENV=prod mix "$@")
  fi
}

secret() {
  file="$STATE/$1"
  if [ ! -s "$file" ]; then
    (umask 077 && head -c 64 /dev/urandom | base64 | tr -d '\n/+=' >"$file")
  fi
  cat "$file"
}

setup_env() {
  mkdir -p "$STATE/tmp"
  chmod 700 "$STATE"

  if [ -n "${HERDR_LIVEVIEW_PORT:-}" ]; then
    printf '%s' "$HERDR_LIVEVIEW_PORT" >"$STATE/port"
  elif [ ! -s "$STATE/port" ]; then
    printf '%s' $((4610 + SID % 100)) >"$STATE/port"
  fi

  export PORT=$(cat "$STATE/port")
  export SECRET_KEY_BASE=$(secret secret_key_base)
  export HERDR_LIVEVIEW_TOKEN=$(secret token)
  export HERDR_SOCKET_PATH="$SOCKET"
  export PHX_SERVER=true
  export RELEASE_NODE="herdr_liveview_$SID"
  export RELEASE_DISTRIBUTION=sname
  export RELEASE_TMP="$STATE/tmp"
}

running() {
  "$REL" pid >/dev/null 2>&1
}

print_url() {
  echo "herdr liveview: http://127.0.0.1:$PORT/?token=$HERDR_LIVEVIEW_TOKEN"
}

case "${1:-}" in
  build)
    mix_run deps.get --only prod
    mix_run assets.setup
    mix_run compile
    mix_run assets.deploy
    mix_run release --overwrite
    ;;
  start)
    [ -x "$REL" ] || { echo "release missing: run the plugin build first" >&2; exit 1; }
    setup_env
    if ! running; then
      "$REL" daemon
    fi
    print_url
    ;;
  stop)
    setup_env
    if running; then
      "$REL" stop
      # `stop` returns before the node is gone; a following `start` would see it as running.
      i=0
      while running && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    fi
    echo "herdr liveview stopped"
    ;;
  status)
    setup_env
    if running; then print_url; else echo "herdr liveview is not running"; fi
    ;;
  *)
    echo "usage: $0 build|start|stop|status" >&2
    exit 2
    ;;
esac
