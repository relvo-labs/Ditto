#!/usr/bin/env bash
# Exercise xdg_activation_v1 with a real pointer serial: click the launcher,
# issue a token for the target, activate it, then read focus back from the
# compositor-neutral adapter.
set -euo pipefail

workspace="${DITTO_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}"
source "$workspace/tools/compositor-probe/functional/compositor.sh"
here="$(cd "$(dirname "$0")" && pwd)"
protocols="${WAYLAND_PROTOCOLS_DIR:-$(pkg-config --variable=pkgdatadir wayland-protocols)}"
build="$(mktemp -d)"
log="$build/client.log"
client_pid=""
trap 'kill "$client_pid" 2>/dev/null || true; rm -rf -- "$build"' EXIT

wayland-scanner client-header "$protocols/stable/xdg-shell/xdg-shell.xml" "$build/xdg-shell-client-protocol.h"
wayland-scanner private-code "$protocols/stable/xdg-shell/xdg-shell.xml" "$build/xdg-shell-protocol.c"
wayland-scanner client-header "$protocols/staging/xdg-activation/xdg-activation-v1.xml" "$build/xdg-activation-v1-client-protocol.h"
wayland-scanner private-code "$protocols/staging/xdg-activation/xdg-activation-v1.xml" "$build/xdg-activation-v1-protocol.c"
cc -std=c11 -Wall -Wextra -Werror -I"$build" \
  "$here/activation-probe.c" "$build/xdg-shell-protocol.c" \
  "$build/xdg-activation-v1-protocol.c" \
  $(pkg-config --cflags --libs wayland-client) -o "$build/activation-probe"

"$build/activation-probe" >"$log" 2>&1 &
client_pid=$!
for _ in $(seq 1 100); do
  grep -q '^READY$' "$log" && break
  kill -0 "$client_pid" 2>/dev/null || { cat "$log" >&2; exit 1; }
  sleep 0.05
done
grep -q '^READY$' "$log" || { cat "$log" >&2; exit 1; }
compositor_wait_for_window ditto-activation-launcher
compositor_wait_for_window ditto-activation-target
compositor_place_window ditto-activation-launcher 100 100 320 180
compositor_place_window ditto-activation-target 500 100 320 180
compositor_focus_window ditto-activation-launcher
compositor_move_cursor 200 180
compositor_click
for _ in $(seq 1 100); do
  grep -q '^TOKEN_DONE$' "$log" && break
  sleep 0.05
done
token_done=false
grep -q '^TOKEN_DONE$' "$log" && token_done=true
focused="$(compositor_focused_app_id)"
supported=false
[[ "$token_done" == true && "$focused" == ditto-activation-target ]] && supported=true
jq -nc --argjson token_done "$token_done" --arg focused "$focused" --argjson supported "$supported" \
  '{probed:true,supported:$supported,token_done:$token_done,focused_app_id:$focused,requirement:"a pointer-authorized launcher token focuses the target"}'
[[ "$supported" == true ]]
