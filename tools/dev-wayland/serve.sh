#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(mktemp -d /tmp/ditto-wayland.XXXXXX)"
chmod 700 "$runtime_dir"
export XDG_RUNTIME_DIR="$runtime_dir"
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1
export QT_QPA_PLATFORM=wayland
export QT_QUICK_BACKEND=software
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK

sway --config /workspace/tools/dev-wayland/sway.conf >"$runtime_dir/sway.log" 2>&1 &
sway_pid=$!
cleanup() {
  kill "$sway_pid" 2>/dev/null || true
  wait "$sway_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 75); do
  sockets=("$runtime_dir"/sway-ipc.*.sock)
  if [[ -S "${sockets[0]}" ]]; then
    export SWAYSOCK="${sockets[0]}"
    break
  fi
  if ! kill -0 "$sway_pid" 2>/dev/null; then
    cat "$runtime_dir/sway.log"
    exit 1
  fi
  sleep 0.2
done
if [[ -z "${SWAYSOCK:-}" ]]; then
  cat "$runtime_dir/sway.log"
  exit 1
fi

wayland_sockets=("$runtime_dir"/wayland-*)
for socket in "${wayland_sockets[@]}"; do
  if [[ -S "$socket" ]]; then
    export WAYLAND_DISPLAY="${socket##*/}"
    break
  fi
done
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
  cat "$runtime_dir/sway.log"
  exit 1
fi

foot --app-id=ditto-wayland-demo sh -c 'sleep infinity' >"$runtime_dir/foot.log" 2>&1 &
quickshell --no-color --path /workspace/tools/dev-wayland/quickshell/shell.qml >"$runtime_dir/quickshell.log" 2>&1 &
echo 'Wayland desktop starting; VNC is mapped to 127.0.0.1:5900 on the host.'
wayvnc 0.0.0.0 5900
