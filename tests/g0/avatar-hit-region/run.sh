#!/usr/bin/env bash
# G0-SHELL-03: exercise the production 24-rectangle avatar mask, not only the
# compositor probe's one-rectangle fixture.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"

WINDOW_PIDS=()
SHELL_PID=""
trap 'kill "$SHELL_PID" 2>/dev/null || true; stop_all' EXIT INT TERM

start_compositor
start_core
export QT_QPA_PLATFORM=wayland
if [[ -z "${DITTO_REFERENCE_MACHINE:-}" ]]; then export QT_QUICK_BACKEND=software; fi

shell_log="$RUNTIME_DIR/avatar-hit-shell.log"
quickshell --no-color -p "$WORKSPACE/shell/shell.qml" >"$shell_log" 2>&1 &
SHELL_PID=$!
for _ in $(seq 1 100); do grep -aq 'hit mask rectangles=24' "$shell_log" && break; sleep 0.1; done
grep -aq 'hit mask rectangles=24' "$shell_log" || { tail -40 "$shell_log" >&2; exit 1; }

start_window ditto-avatar-under
start_window ditto-avatar-other
compositor_place_window ditto-avatar-under 1600 700 320 320
compositor_place_window ditto-avatar-other 100 100 300 200
compositor_focus_window ditto-avatar-other

# Output is 1920x1080. The production surface is 220x250, anchored 32 px from
# the right and 64 px from the bottom: origin (1668, 766). Local (10, 10) is
# outside every generated mask rectangle; local (110, 132) is opaque.
before_hits="$(grep -ac 'ditto-avatar-hit' "$shell_log" || true)"
compositor_move_cursor 1678 776
compositor_click
sleep 0.5
through_focus="$(compositor_focused_app_id)"
through_hits="$(grep -ac 'ditto-avatar-hit' "$shell_log" || true)"

compositor_move_cursor 1778 898
compositor_click
sleep 0.5
opaque_hits="$(grep -ac 'ditto-avatar-hit' "$shell_log" || true)"

jq -n \
  --arg environment "$(environment_label)" \
  --arg focus "$through_focus" \
  --argjson before "$before_hits" --argjson through "$through_hits" --argjson opaque "$opaque_hits" \
  '{environment: $environment, mask_rectangles: 24,
    transparent_click: {focused_app: $focus, avatar_hits_before: $before, avatar_hits_after: $through},
    opaque_click: {avatar_hits_after: $opaque},
    passed_through: ($focus == "ditto-avatar-under" and $through == $before),
    received_on_opaque: ($opaque > $through)}' \
  | tee "$ARTIFACTS/avatar-hit-region-$(run_id).json"

[[ "$through_focus" == ditto-avatar-under && "$through_hits" == "$before_hits" && "$opaque_hits" -gt "$through_hits" ]]
echo 'production avatar mask passed both click directions'
