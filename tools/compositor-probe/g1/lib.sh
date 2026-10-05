#!/usr/bin/env bash
# Headless Wayfire for the G1 probes, started the way tests/g0/lib/session.sh
# starts it (own runtime dir, own session bus, fixed IPC socket path), but with
# this directory's wayfire.ini. Results are development evidence (headless).
set -euo pipefail

G1_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../tests/g0/lib/session.sh
source "$G1_PROBE_DIR/../../../tests/g0/lib/session.sh"

export PATH="$HOME/wayfire/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/wayfire/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
G1_ARTIFACTS="${DITTO_G1_DEV_ARTIFACTS:-$WORKSPACE/artifacts/g1-dev/compositor-probe}"
WINDOW_PIDS=()

g1_start_compositor() {
  RUNTIME_DIR="$(mktemp -d /tmp/ditto-g1-probe.XXXXXX)"
  chmod 700 "$RUNTIME_DIR"
  export XDG_RUNTIME_DIR="$RUNTIME_DIR"
  start_session_bus
  export WLR_BACKENDS=headless WLR_RENDERER="${WLR_RENDERER:-pixman}"
  export WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1
  unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
  COMPOSITOR_LOG="$RUNTIME_DIR/wayfire.log"
  export COMPOSITOR_LOG
  export _WAYFIRE_SOCKET="$RUNTIME_DIR/wayfire-ipc.sock"
  export WAYFIRE_SOCKET="$_WAYFIRE_SOCKET"
  local marker="$RUNTIME_DIR/socket-marker"
  touch "$marker"
  wayfire --config "$G1_PROBE_DIR/wayfire.ini" >"$COMPOSITOR_LOG" 2>&1 &
  COMPOSITOR_PID=$!
  for _ in $(seq 1 100); do
    [[ -S "$WAYFIRE_SOCKET" ]] && break
    kill -0 "$COMPOSITOR_PID" 2>/dev/null || { cat "$COMPOSITOR_LOG" >&2; return 1; }
    sleep 0.2
  done
  [[ -S "$WAYFIRE_SOCKET" ]] || { echo 'compositor IPC socket did not appear' >&2; return 1; }
  local socket
  socket="$(find "$RUNTIME_DIR" -maxdepth 1 -newer "$marker" -type s -name 'wayland-*' -print -quit)"
  [[ -n "$socket" ]] || { echo 'Wayland socket did not appear' >&2; return 1; }
  export WAYLAND_DISPLAY="${socket##*/}"
}

g1_stop() {
  stop_all
  [[ -n "${RUNTIME_DIR:-}" && "$RUNTIME_DIR" == /tmp/ditto-g1-probe.* ]] && rm -rf -- "$RUNTIME_DIR"
}
