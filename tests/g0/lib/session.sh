#!/usr/bin/env bash
# Shared helpers for the G0 verification scripts. A run started from here is a
# development-environment run by default: it exercises the code paths, and it
# is not the reference-machine evidence any exit criterion asks for.
set -euo pipefail

DEFAULT_WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKSPACE="${DITTO_WORKSPACE:-$DEFAULT_WORKSPACE}"
BINARIES="${DITTO_BINARIES:-$WORKSPACE/target/debug}"
ARTIFACTS="${DITTO_ARTIFACTS:-$WORKSPACE/artifacts/g0}"
DITTO_COMPOSITOR="${DITTO_COMPOSITOR:-wayfire}"

# The compositor-neutral queries live with the probe, so the fixtures and the
# probe ask the compositor the same questions in the same way.
source "$WORKSPACE/tools/compositor-probe/functional/compositor.sh"

run_id() {
  local commit
  commit="$(git -C "$WORKSPACE" rev-parse --short=3 HEAD 2>/dev/null || echo "000")"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)-${commit}"
}

environment_label() {
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    echo "reference-machine"
  elif [[ -n "${DITTO_ENVIRONMENT_LABEL:-}" ]]; then
    echo "$DITTO_ENVIRONMENT_LABEL"
  else
    echo "development-environment"
  fi
}

# A session bus, for the parts of a desktop that have no other way to be
# reached: the input method, portals, the secret service. The fixture starts
# its own rather than borrowing the caller's, so a run never reaches into the
# developer's live session.
start_session_bus() {
  command -v dbus-daemon >/dev/null || return 0
  local address_file="$RUNTIME_DIR/ditto-fixture-dbus-$$.address"
  dbus-daemon --session --nofork --print-address=3 3>"$address_file" \
    >"$RUNTIME_DIR/ditto-fixture-dbus-$$.log" 2>&1 &
  DBUS_PID=$!
  local _
  for _ in $(seq 1 50); do
    [[ -s "$address_file" ]] && break
    kill -0 "$DBUS_PID" 2>/dev/null || { DBUS_PID=""; return 0; }
    sleep 0.1
  done
  [[ -s "$address_file" ]] || { DBUS_PID=""; return 0; }
  DBUS_SESSION_BUS_ADDRESS="$(tr -d '\n' <"$address_file")"
  export DBUS_SESSION_BUS_ADDRESS
}

start_compositor() {
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    # Native snaps (the frozen browser) can only reach Wayland sockets in the
    # real user runtime. Reference jobs are serialized by the runner, so they
    # use that runtime and unique compositor sockets instead of a /tmp island.
    RUNTIME_DIR="${DITTO_REFERENCE_RUNTIME:-/run/user/$(id -u)}"
    [[ -d "$RUNTIME_DIR" && -O "$RUNTIME_DIR" ]] || {
      echo "invalid reference runtime: $RUNTIME_DIR" >&2
      return 1
    }
  else
    RUNTIME_DIR="$(mktemp -d "${DITTO_FIXTURE_RUNTIME_PARENT:-/tmp}/ditto-g0.XXXXXX")"
    chmod 700 "$RUNTIME_DIR"
  fi
  export XDG_RUNTIME_DIR="$RUNTIME_DIR"
  # The shared reference runtime may already hold a logged-in Ditto session's
  # Core and Shell sockets. The fixture's own pair lives in a directory of its
  # own, so it neither fails to bind nor talks to the live desktop.
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    export DITTO_RUNTIME_DIR="$RUNTIME_DIR/ditto-g0-fixture-$$"
  else
    export DITTO_RUNTIME_DIR="$RUNTIME_DIR/ditto"
  fi
  # The fixture may run beside the logged-in Ditto session (including in the
  # VM regression job). Its socket and store must both be isolated; otherwise
  # the session's Core holds the database lock and the fixture cannot start.
  export DITTO_DATA_DIR="$DITTO_RUNTIME_DIR/store"
  if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$RUNTIME_DIR/bus}"
  else
    start_session_bus
  fi
  export WLR_BACKENDS="${WLR_BACKENDS:-headless}" WLR_RENDERER="${WLR_RENDERER:-pixman}"
  export WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1
  unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
  local log="$RUNTIME_DIR/ditto-g0-$DITTO_COMPOSITOR-$$.log"
  COMPOSITOR_LOG="$log"
  export COMPOSITOR_LOG
  local socket_marker="$RUNTIME_DIR/ditto-g0-socket-marker-$$"
  touch "$socket_marker"

  case "$DITTO_COMPOSITOR" in
    sway)
      sway --config "$WORKSPACE/tools/dev-wayland/sway.conf" >"$log" 2>&1 &
      COMPOSITOR_PID=$!
      for _ in $(seq 1 100); do
        local sockets=("$RUNTIME_DIR"/sway-ipc.*.sock)
        if [[ -S "${sockets[0]}" ]]; then
          export SWAYSOCK="${sockets[0]}"
          break
        fi
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || { cat "$log"; return 1; }
        sleep 0.2
      done
      [[ -n "${SWAYSOCK:-}" ]] || { cat "$log"; echo 'compositor IPC socket did not appear' >&2; return 1; }
      ;;
    wayfire)
      # The socket path is fixed here instead of being read back from the
      # compositor, because the probe is not a child of Wayfire and would not
      # inherit WAYFIRE_SOCKET.
      export _WAYFIRE_SOCKET="$RUNTIME_DIR/ditto-wayfire-ipc-$$.sock"
      export WAYFIRE_SOCKET="$_WAYFIRE_SOCKET"
      wayfire --config "$WORKSPACE/tools/dev-wayland/wayfire.ini" >"$log" 2>&1 &
      COMPOSITOR_PID=$!
      for _ in $(seq 1 100); do
        [[ -S "$WAYFIRE_SOCKET" ]] && break
        kill -0 "$COMPOSITOR_PID" 2>/dev/null || { cat "$log"; return 1; }
        sleep 0.2
      done
      [[ -S "$WAYFIRE_SOCKET" ]] || { cat "$log"; echo 'compositor IPC socket did not appear' >&2; return 1; }
      ;;
    *)
      echo "unknown compositor: $DITTO_COMPOSITOR" >&2
      return 1
      ;;
  esac

  local socket
  socket="$(find "$RUNTIME_DIR" -maxdepth 1 -newer "$socket_marker" -type s -name 'wayland-*' -print -quit)"
  rm -f -- "$socket_marker"
  [[ -n "$socket" ]] && export WAYLAND_DISPLAY="${socket##*/}"
  [[ -n "${WAYLAND_DISPLAY:-}" ]] || { echo 'Wayland socket did not appear' >&2; return 1; }
}

start_core() {
  export DITTO_DEV_TOKEN="${DITTO_DEV_TOKEN:-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  local core_args=(serve --compositor "$DITTO_COMPOSITOR" --development)
  if [[ -d "$WORKSPACE/target/ditto-packages" ]]; then
    core_args+=(--builtin-packages "$WORKSPACE/target/ditto-packages")
  fi
  "$BINARIES/ditto-core" "${core_args[@]}" >"$RUNTIME_DIR/core.log" 2>&1 &
  CORE_PID=$!
  for _ in $(seq 1 100); do
    [[ -S "$DITTO_RUNTIME_DIR/core.sock" ]] && return 0
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
  compositor_wait_for_window "$app_id" && return 0
  echo "window $app_id did not appear" >&2
  return 1
}

window_id_for() {
  compositor_window_id "$1"
}

stop_all() {
  local pid
  for pid in "${WINDOW_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
  [[ -n "${CORE_PID:-}" ]] && kill "$CORE_PID" 2>/dev/null || true
  [[ -n "${COMPOSITOR_PID:-}" ]] && kill "$COMPOSITOR_PID" 2>/dev/null || true
  [[ -n "${DBUS_PID:-}" ]] && kill "$DBUS_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  if [[ "${DITTO_RUNTIME_DIR:-}" == */ditto-g0-fixture-* && -d "$DITTO_RUNTIME_DIR" ]]; then
    # The package store keeps installed files read-only.
    chmod -R u+w -- "$DITTO_RUNTIME_DIR" 2>/dev/null || true
    rm -rf -- "$DITTO_RUNTIME_DIR"
  fi
}
