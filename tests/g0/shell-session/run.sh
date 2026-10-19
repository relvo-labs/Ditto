#!/usr/bin/env bash
# The session checks that do not need a physical machine: layer-shell anchoring
# and exclusive zones, the hit mask, the hot-path rule, the recall path, and the
# character surviving the loss of the desktop service. Frame time and memory are
# not measured here; those belong to the reference machine.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"
source "$WORKSPACE/tests/g0/shell-session/checks.sh"

WINDOW_PIDS=()
SHELL_PID=""
trap '[[ -z "$SHELL_PID" ]] || kill "$SHELL_PID" 2>/dev/null || true; stop_all' EXIT INT TERM

start_compositor
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software DITTO_FRAME_PROBE=1
unset DITTO_DEV_TOKEN

# The launcher binds identity to the executable it started, so it needs the
# real path. Quickshell is not at a fixed location: on the workstation it lives
# beside the Qt it was built against.
QUICKSHELL="${DITTO_QUICKSHELL:-$(command -v quickshell)}"
[[ -x "$QUICKSHELL" ]] || { echo 'quickshell is not on PATH; set DITTO_QUICKSHELL' >&2; exit 1; }
QUICKSHELL="$(readlink -f "$QUICKSHELL")"
NODE="$(command -v node)" || { echo 'node is required for the launcher-authenticated pin driver' >&2; exit 1; }
NODE="$(readlink -f "$NODE")"
[[ -d "$WORKSPACE/target/ditto-packages" ]] || {
  echo 'built-in packages are missing; run scripts/build-builtin-packages.sh first' >&2
  exit 1
}

"$BINARIES/ditto-core" serve --compositor "${DITTO_COMPOSITOR:-wayfire}" \
  --builtin-packages "$WORKSPACE/target/ditto-packages" \
  --launch "quickshell 0.2.0 $QUICKSHELL -p $WORKSPACE/shell/shell.qml" \
  --launch "dittoctl 0.2.0 $NODE $WORKSPACE/tests/g0/shell-session/pin-legacy.mjs $RUNTIME_DIR" \
  >"$RUNTIME_DIR/core.log" 2>&1 &
CORE_PID=$!
for _ in $(seq 1 150); do
  grep -aq 'ditto-shell started' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done
grep -aq 'ditto-shell started' "$RUNTIME_DIR/core.log" || { cat "$RUNTIME_DIR/core.log"; echo 'the shell did not start' >&2; exit 1; }
read -r SHELL_PID _ <"$DITTO_RUNTIME_DIR/shell.pid"
[[ "$SHELL_PID" =~ ^[0-9]+$ ]] || { echo 'the launched Shell PID is missing' >&2; exit 1; }

for _ in $(seq 1 100); do
  grep -aq '"role":"shell"' "$RUNTIME_DIR/core.log" && break
  sleep 0.1
done
grep -aq '"role":"shell"' "$RUNTIME_DIR/core.log" || { echo 'the Shell participant did not finish its boot sync' >&2; exit 1; }

# D-48 defaults to the assistant. Pin the legacy character through Core's
# controlled launcher, after boot sync; the dev-token helper cannot connect
# here. Record the floor BEFORE releasing the driver: the new mask can load
# during the ChangeSet, before its committed reply reaches the driver.
for _ in $(seq 1 150); do
  [[ -f "$RUNTIME_DIR/legacy-pin.ready" ]] && break
  sleep 0.1
done
[[ -f "$RUNTIME_DIR/legacy-pin.ready" ]] || { cat "$RUNTIME_DIR/core.log"; echo 'legacy pin driver did not authenticate' >&2; exit 1; }
pin_floor="$(wc -l <"$RUNTIME_DIR/core.log")"
touch "$RUNTIME_DIR/legacy-pin.start"
for _ in $(seq 1 450); do
  [[ -f "$RUNTIME_DIR/legacy-pin.json" ]] && break
  sleep 0.1
done
[[ -f "$RUNTIME_DIR/legacy-pin.json" ]] || {
  echo 'legacy pin failed: driver produced no result before the deadline' >&2
  exit 1
}
jq -e '.status == "pinned"' "$RUNTIME_DIR/legacy-pin.json" >/dev/null || {
  cat "$RUNTIME_DIR/legacy-pin.json" >&2
  echo 'legacy pin failed: no committed ChangeSet with matching Profile readback' >&2
  exit 1
}
wait_session_mask "$RUNTIME_DIR/core.log" "$pin_floor"
echo "check 1: pinned legacy character applied a new hit mask (24 rectangles, after log line $pin_floor)"

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

kill "$CORE_PID"
wait "$CORE_PID" || true
CORE_PID=""
stopped_at="$(date +%s%3N)"
survival_floor="$(wc -l <"$RUNTIME_DIR/core.log")"
sleep 3
require_session_survival "$RUNTIME_DIR/core.log" "$survival_floor" "$stopped_at" "$SHELL_PID"
echo 'check 5: the pinned legacy character still produces frames after Core exits; its animation continues without Core'
if [[ "$(environment_label)" == reference-machine ]]; then
  echo 'reference-machine functional evidence; frame time and PSS remain separate measurements'
else
  echo 'development evidence; EX-04 frame time and EX-05 memory are measured on the reference machine'
fi
