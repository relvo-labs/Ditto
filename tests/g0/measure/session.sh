#!/usr/bin/env bash
# Start and stop a measurable G0 desktop as three distinct user services. This
# gives ditto-measure stable cgroup ownership instead of discovering processes
# by name. Restarting these units is not the same as a display-manager login.
set -euo pipefail

workspace="${DITTO_WORKSPACE:-$(cd "$(dirname "$0")/../../.." && pwd)}"
binaries="${DITTO_BINARIES:-$workspace/target/debug}"
state_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ditto-g0-measure"
state_file="$state_dir/session.env"
units=(ditto-shell.service ditto-core.service ditto-wayfire.service)

user_bus() {
  export XDG_RUNTIME_DIR="${DITTO_SYSTEMD_RUNTIME_DIR:-/run/user/$(id -u)}"
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  systemctl --user show-environment >/dev/null 2>&1 || {
    echo 'the systemd user manager is not reachable' >&2
    return 1
  }
}

stop_session() {
  user_bus
  local unit runtime=""
  [[ -f "$state_file" ]] && runtime="$(sed -n 's/^RUNTIME_DIR=//p' "$state_file")"
  for unit in "${units[@]}"; do
    systemctl --user stop "$unit" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  done
  if [[ "$runtime" == /run/user/"$(id -u)"/ditto-g0-measure.* && -d "$runtime" ]]; then
    rm -rf -- "$runtime"
  fi
  rm -f -- "$state_file"
}

start_session() {
  user_bus
  mkdir -p "$state_dir"
  stop_session
  local systemd_runtime="$XDG_RUNTIME_DIR"
  local runtime token wayfire_bin quickshell_bin
  runtime="$(mktemp -d "$systemd_runtime/ditto-g0-measure.XXXXXX")"
  chmod 700 "$runtime"
  token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  wayfire_bin="$(command -v wayfire)"
  quickshell_bin="$(command -v quickshell)"
  printf 'RUNTIME_DIR=%s\n' "$runtime" >"$state_file"

  systemd-run --user --quiet --unit=ditto-wayfire.service --collect \
    --property=KillMode=control-group \
    --setenv=XDG_RUNTIME_DIR="$runtime" \
    --setenv=WLR_BACKENDS=headless --setenv=WLR_RENDERER="${WLR_RENDERER:-gles2}" \
    --setenv=WLR_HEADLESS_OUTPUTS=1 --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
    --setenv=_WAYFIRE_SOCKET="$runtime/wayfire-ipc.sock" \
    --setenv=WAYFIRE_SOCKET="$runtime/wayfire-ipc.sock" \
    --setenv=PATH="$PATH" --setenv=LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
    "$wayfire_bin" --config "$workspace/tools/dev-wayland/wayfire.ini"

  local _ wayland_display=""
  for _ in $(seq 1 150); do
    if [[ -S "$runtime/wayfire-ipc.sock" ]]; then
      for socket in "$runtime"/wayland-*; do
        [[ -S "$socket" ]] && wayland_display="${socket##*/}" && break
      done
    fi
    [[ -n "$wayland_display" ]] && break
    systemctl --user is-active --quiet ditto-wayfire.service || {
      journalctl --user -u ditto-wayfire.service -n 80 --no-pager >&2
      return 1
    }
    sleep 0.1
  done
  [[ -n "$wayland_display" ]] || { echo 'measurement Wayland socket did not appear' >&2; return 1; }

  systemd-run --user --quiet --unit=ditto-core.service --collect \
    --property=KillMode=control-group \
    --setenv=XDG_RUNTIME_DIR="$runtime" --setenv=WAYLAND_DISPLAY="$wayland_display" \
    --setenv=WAYFIRE_SOCKET="$runtime/wayfire-ipc.sock" --setenv=DITTO_DEV_TOKEN="$token" \
    --setenv=PATH="$PATH" --setenv=LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
    "$binaries/ditto-core" serve --compositor wayfire --development
  for _ in $(seq 1 100); do
    [[ -S "$runtime/ditto/core.sock" ]] && break
    systemctl --user is-active --quiet ditto-core.service || {
      journalctl --user -u ditto-core.service -n 80 --no-pager >&2
      return 1
    }
    sleep 0.1
  done
  [[ -S "$runtime/ditto/core.sock" ]] || { echo 'measurement Core socket did not appear' >&2; return 1; }

  systemd-run --user --quiet --unit=ditto-shell.service --collect \
    --property=KillMode=control-group \
    --setenv=XDG_RUNTIME_DIR="$runtime" --setenv=WAYLAND_DISPLAY="$wayland_display" \
    --setenv=WAYFIRE_SOCKET="$runtime/wayfire-ipc.sock" --setenv=DITTO_DEV_TOKEN="$token" \
    --setenv=QT_QPA_PLATFORM=wayland --setenv=PATH="$PATH" \
    --setenv=LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
    "$quickshell_bin" --no-color -p "$workspace/shell/shell.qml"
  for _ in $(seq 1 100); do
    journalctl --user -u ditto-shell.service --no-pager 2>/dev/null | grep -aq 'ditto-shell started' && break
    systemctl --user is-active --quiet ditto-shell.service || {
      journalctl --user -u ditto-shell.service -n 80 --no-pager >&2
      return 1
    }
    sleep 0.1
  done
  systemctl --user is-active --quiet ditto-shell.service || return 1
  export XDG_RUNTIME_DIR="$systemd_runtime"
  echo "measurement session started in $runtime"
}

case "${1:-}" in
  start) start_session ;;
  stop) stop_session ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
