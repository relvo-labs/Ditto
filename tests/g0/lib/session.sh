#!/usr/bin/env bash
# Shared helpers for the G0 verification scripts. A run started from here is a
# development-container run: it exercises the code paths, and it is not the
# reference-machine evidence any exit criterion asks for.
set -euo pipefail

BINARIES="${DITTO_BINARIES:-/workspace/target/debug}"
ARTIFACTS="${DITTO_ARTIFACTS:-/workspace/artifacts/g0}"
WORKSPACE="${DITTO_WORKSPACE:-/workspace}"

run_id() {
  local commit
  commit="$(git -C "$WORKSPACE" rev-parse --short=3 HEAD 2>/dev/null || echo "000")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)-${commit}"
}

environment_label() {
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    echo "reference-machine"
  else
    echo "development-container"
  fi
}

start_compositor() {
  RUNTIME_DIR="$(mktemp -d /tmp/ditto-g0.XXXXXX)"
  chmod 700 "$RUNTIME_DIR"
  export XDG_RUNTIME_DIR="$RUNTIME_DIR"
  export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1
  unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
  sway --config "$WORKSPACE/tools/dev-wayland/sway.conf" >"$RUNTIME_DIR/sway.log" 2>&1 &
  COMPOSITOR_PID=$!
  for _ in $(seq 1 100); do
    local sockets=("$RUNTIME_DIR"/sway-ipc.*.sock)
    if [[ -S "${sockets[0]}" ]]; then
      export SWAYSOCK="${sockets[0]}"
      break
    fi
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || { cat "$RUNTIME_DIR/sway.log"; return 1; }
    sleep 0.2
  done
  [[ -n "${SWAYSOCK:-}" ]] || { cat "$RUNTIME_DIR/sway.log"; echo 'compositor IPC socket did not appear' >&2; return 1; }
  local wayland_sockets=("$RUNTIME_DIR"/wayland-*)
  for socket in "${wayland_sockets[@]}"; do
    [[ -S "$socket" ]] && export WAYLAND_DISPLAY="${socket##*/}" && break
  done
  [[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo 'Wayland socket did not appear' >&2; return 1; }
}

start_core() {
  export DITTO_DEV_TOKEN="${DITTO_DEV_TOKEN:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  "$BINARIES/ditto-core" serve --compositor sway --development >"$RUNTIME_DIR/core.log" 2>&1 &
  CORE_PID=$!
  for _ in $(seq 1 100); do
    [[ -S "$XDG_RUNTIME_DIR/ditto/core.sock" ]] && return 0
    kill -0 "$CORE_PID" 2>/dev/null || { cat "$RUNTIME_DIR/core.log"; return 1; }
    sleep 0.1
  done
  cat "$RUNTIME_DIR/core.log"
  echo 'Core socket did not appear' >&2
  return 1
}

start_window() {
  local app_id="$1"
  foot --app-id="$app_id" sh -c 'sleep infinity' >"$RUNTIME_DIR/$app_id.log" 2>&1 &
  WINDOW_PIDS+=("$!")
  for _ in $(seq 1 100); do
    if swaymsg --raw --type get_tree | jq -e --arg id "$app_id" '[.. | objects | select(.app_id? == $id)] | length == 1' >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "window $app_id did not appear" >&2
  return 1
}

window_id_for() {
  local app_id="$1"
  local con_id
  con_id="$(swaymsg --raw --type get_tree | jq -r --arg id "$app_id" 'first(.. | objects | select(.app_id? == $id) | .id)')"
  echo "sway-con-$con_id"
}

stop_all() {
  local pid
  for pid in "${WINDOW_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
  [[ -n "${CORE_PID:-}" ]] && kill "$CORE_PID" 2>/dev/null || true
  [[ -n "${COMPOSITOR_PID:-}" ]] && kill "$COMPOSITOR_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
