#!/usr/bin/env bash
set -euo pipefail

runtime_dir="$(mktemp -d /tmp/ditto-wayland.XXXXXX)"
chmod 700 "$runtime_dir"
export XDG_RUNTIME_DIR="$runtime_dir"
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK

log_file="$runtime_dir/sway.log"
sway --config /workspace/tools/dev-wayland/sway.conf --debug >"$log_file" 2>&1 &
sway_pid=$!
client_pid=""
quickshell_pid=""
cleanup() {
  if [[ -n "$quickshell_pid" ]]; then kill "$quickshell_pid" 2>/dev/null || true; fi
  if [[ -n "$client_pid" ]]; then kill "$client_pid" 2>/dev/null || true; fi
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
    cat "$log_file"
    exit 1
  fi
  sleep 0.2
done
if [[ -z "${SWAYSOCK:-}" ]]; then
  cat "$log_file"
  echo 'Sway IPC socket did not appear' >&2
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
  cat "$log_file"
  echo 'Wayland socket did not appear' >&2
  exit 1
fi

outputs="$(swaymsg --raw --type get_outputs)"
jq -e 'any(.[]; .active == true and .rect.width == 1280 and .rect.height == 720)' <<<"$outputs" >/dev/null

foot --app-id=ditto-wayland-smoke sh -c 'sleep 30' >"$runtime_dir/foot.log" 2>&1 &
client_pid=$!
for _ in $(seq 1 75); do
  tree="$(swaymsg --raw --type get_tree)"
  if jq -e '[.. | objects | select(.app_id? == "ditto-wayland-smoke")] | length > 0' <<<"$tree" >/dev/null; then
    break
  fi
  if ! kill -0 "$client_pid" 2>/dev/null; then
    cat "$runtime_dir/foot.log"
    exit 1
  fi
  sleep 0.2
done
jq -e '[.. | objects | select(.app_id? == "ditto-wayland-smoke")] | length == 1' <<<"$tree" >/dev/null

swaymsg '[app_id="ditto-wayland-smoke"] focus' >/dev/null
tree="$(swaymsg --raw --type get_tree)"
jq -e '[.. | objects | select(.app_id? == "ditto-wayland-smoke" and .focused == true)] | length == 1' <<<"$tree" >/dev/null

swaymsg 'workspace 2' >/dev/null
workspaces="$(swaymsg --raw --type get_workspaces)"
jq -e 'any(.[]; .name == "2" and .focused == true)' <<<"$workspaces" >/dev/null

export QT_QPA_PLATFORM=wayland
export QT_QUICK_BACKEND=software
QSG_INFO=1 quickshell --no-color --verbose --path /workspace/tools/dev-wayland/quickshell/shell.qml >"$runtime_dir/quickshell.log" 2>&1 &
quickshell_pid=$!
for _ in $(seq 1 75); do
  if grep -q 'Configuration Loaded' "$runtime_dir/quickshell.log"; then
    break
  fi
  if ! kill -0 "$quickshell_pid" 2>/dev/null; then
    cat "$runtime_dir/quickshell.log"
    exit 1
  fi
  sleep 0.2
done
if ! grep -q 'Configuration Loaded' "$runtime_dir/quickshell.log"; then
  cat "$runtime_dir/quickshell.log"
  echo 'Quickshell QML configuration did not load' >&2
  exit 1
fi
kill -0 "$quickshell_pid"

probe="$(bash /workspace/tools/compositor-probe/run.sh sway-dev)"
jq -e '.coverage == "globals_only" and (.globals | any(.interface == "wl_compositor"))' <<<"$probe" >/dev/null

echo "PASS: headless Sway, 1280x720 output, Wayland client, focus, workspace switch, Quickshell QML panel"
echo "compositor=$(sway --version) qt=$(qmake6 -query QT_VERSION) quickshell=$(quickshell --version 2>&1 | head -1) renderer=pixman/Qt-software"
