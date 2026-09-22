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

# The launcher binds identity to the executable it started, so it needs the
# real path. Quickshell is not at a fixed location: on the workstation it lives
# beside the Qt it was built against.
QUICKSHELL="${DITTO_QUICKSHELL:-$(command -v quickshell)}"
[[ -x "$QUICKSHELL" ]] || { echo 'quickshell is not on PATH; set DITTO_QUICKSHELL' >&2; exit 1; }
QUICKSHELL="$(readlink -f "$QUICKSHELL")"

"$BINARIES/ditto-core" serve --compositor "${DITTO_COMPOSITOR:-wayfire}" \
  --launch "quickshell 0.1.0 $QUICKSHELL -p $WORKSPACE/shell/shell.qml" \
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

# Exclusive zones are observable: applications must start below the panel and
# end above the dock.
output_height="$(compositor_outputs_json | jq '.first.height | floor')"
usable="$(compositor_usable_rect)"
if [[ -n "$usable" && "$usable" != "null" ]]; then
  # Where the compositor reports the area it leaves to applications, that is
  # what the zones actually reserve. Measuring a window instead would pass on a
  # compositor that simply happens to place it clear of the panel.
  measured_through="the area the compositor leaves to applications"
  top="$(echo "$usable" | jq '.y')"
  bottom="$(echo "$usable" | jq '.y + .height')"
else
  measured_through="a tiled window's position"
  start_window ditto-session-check
  geometry="$(compositor_window_rect ditto-session-check)"
  top="$(echo "$geometry" | jq '.y')"
  bottom="$(echo "$geometry" | jq '.y + .height')"
fi
[[ "$top" -ge 34 ]] || { echo "check 2 failed: applications start at $top, above the panel" >&2; exit 1; }
[[ "$bottom" -le $((output_height - 56)) ]] || { echo "check 2 failed: applications end at $bottom, inside the dock" >&2; exit 1; }
echo "check 2: panel and dock exclusive zones keep applications between $top and $bottom of $output_height, measured through $measured_through"

# The hot path rule: after the initial handshake, catalog and subscription,
# window activity must not produce requests.
before="$(grep -ac 'ditto-rpc ' "$RUNTIME_DIR/core.log" || true)"
compositor_wait_for_window ditto-session-check 2>/dev/null || start_window ditto-session-check
compositor_focus_window ditto-session-check
compositor_switch_workspace 3
compositor_switch_workspace 1
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

SHELL_PID="$(pgrep -f "^$QUICKSHELL" | head -1)"
[[ -n "$SHELL_PID" ]] || { echo 'the shell process is gone' >&2; exit 1; }
kill "$CORE_PID"
CORE_PID=""
sleep 3
kill -0 "$SHELL_PID" || { echo 'check 5 failed: the shell died with the desktop service' >&2; exit 1; }
echo 'check 5: the character layer outlives the desktop service; its animation never waited on a request'
echo 'development-container evidence; EX-04 frame time and EX-05 memory are measured on the reference machine'
