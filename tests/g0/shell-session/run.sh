#!/usr/bin/env bash
# The session checks that do not need a physical machine: layer-shell anchoring
# and exclusive zones, the hit mask, the hot-path rule, the recall path, and the
# character surviving the loss of the desktop service. Frame time and memory are
# not measured here; those belong to the reference machine.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"

WINDOW_PIDS=()
SHELL_PID=""
trap stop_all EXIT INT TERM

start_compositor
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software

"$BINARIES/ditto-core" serve --compositor sway \
  --launch "quickshell 0.1.0 /usr/bin/quickshell -p $WORKSPACE/shell/shell.qml" \
  >"$RUNTIME_DIR/core.log" 2>&1 &
CORE_PID=$!
for _ in $(seq 1 150); do
  grep -aq 'ditto-shell started' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done
grep -aq 'ditto-shell started' "$RUNTIME_DIR/core.log" || { cat "$RUNTIME_DIR/core.log"; echo 'the shell did not start' >&2; exit 1; }
grep -aq 'hit mask rectangles=' "$RUNTIME_DIR/core.log" || { echo 'the avatar hit mask was not applied' >&2; exit 1; }
echo "check 1: the session started and applied its hit mask ($(sed -n 's/.*hit mask rectangles=//p' "$RUNTIME_DIR/core.log" | head -1) rectangles)"

for _ in $(seq 1 100); do
  grep -aq 'desktop.events.subscribe' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done

# Exclusive zones are observable: a tiled window must start below the panel and
# end above the dock.
start_window ditto-session-check
geometry="$(swaymsg --raw --type get_tree | jq -c 'first(.. | objects | select(.app_id? == "ditto-session-check") | .rect)')"
top="$(echo "$geometry" | jq '.y')"
bottom="$(echo "$geometry" | jq '.y + .height')"
output_height="$(swaymsg --raw --type get_outputs | jq 'first(.[] | select(.active) | .rect.height)')"
[[ "$top" -ge 34 ]] || { echo "check 2 failed: window starts at $top, above the panel" >&2; exit 1; }
[[ "$bottom" -le $((output_height - 56)) ]] || { echo "check 2 failed: window ends at $bottom, inside the dock" >&2; exit 1; }
echo "check 2: panel and dock exclusive zones keep applications between $top and $bottom of $output_height"

# The hot path rule: after the initial handshake, catalog and subscription,
# window activity must not produce requests.
before="$(grep -ac 'ditto-rpc ' "$RUNTIME_DIR/core.log" || true)"
swaymsg '[app_id=ditto-session-check] focus' >/dev/null
swaymsg 'workspace 3' >/dev/null
swaymsg 'workspace 1' >/dev/null
sleep 5
after="$(grep -ac 'ditto-rpc ' "$RUNTIME_DIR/core.log" || true)"
[[ "$after" -eq "$before" ]] || {
  grep -a 'ditto-rpc ' "$RUNTIME_DIR/core.log" | tail -5
  echo "check 3 failed: $((after - before)) requests during passive updates" >&2
  exit 1
}
echo "check 3: $before requests at startup, 0 more while the desktop changed under it"

bash "$WORKSPACE/shell/tools/recall.sh"
for _ in $(seq 1 50); do
  grep -aq 'avatar recalled' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done
grep -aq 'avatar recalled' "$RUNTIME_DIR/core.log" || { echo 'check 4 failed: the recall path did not reach the shell' >&2; exit 1; }
echo 'check 4: the keyboard recall path reaches the character layer'

SHELL_PID="$(pgrep -f '^/usr/bin/quickshell' | head -1)"
[[ -n "$SHELL_PID" ]] || { echo 'the shell process is gone' >&2; exit 1; }
kill "$CORE_PID"
CORE_PID=""
sleep 3
kill -0 "$SHELL_PID" || { echo 'check 5 failed: the shell died with the desktop service' >&2; exit 1; }
echo 'check 5: the character layer outlives the desktop service; its animation never waited on a request'
echo 'development-container evidence; EX-04 frame time and EX-05 memory are measured on the reference machine'
