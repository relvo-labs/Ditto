#!/usr/bin/env bash
# Row C-07, both directions. A hit mask is only correct if it does two things:
# the opaque area receives the click, and the transparent area lets it through
# to whatever is underneath. Testing one direction alone would pass a surface
# that swallows everything, or one that receives nothing.
#
# The test needs pointer injection, so the caller checks for it first. Output is
# one JSON object on stdout; every failure path still produces evidence.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/compositor.sh"
runtime="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}"

under=ditto-c07-under
other=ditto-c07-other
log="$runtime/c07-overlay.log"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
}
trap cleanup EXIT

fail() {
  jq -nc --arg reason "$1" '{supported: false, probed: true, reason: $reason}'
  exit 0
}

# The window under the surface covers both the opaque square and the
# transparent area, so the two clicks differ only by the input region.
foot --app-id="$under" sh -c 'sleep 60' >"$runtime/c07-under.log" 2>&1 &
pids+=("$!")
compositor_wait_for_window "$under" || fail "the window under the surface never appeared"
compositor_place_window "$under" 0 0 400 400 || fail "this compositor cannot place the window under the surface"

# A second window holds the focus, so a click that reaches the window below is
# visible as a focus change rather than as the absence of one.
foot --app-id="$other" sh -c 'sleep 60' >"$runtime/c07-other.log" 2>&1 &
pids+=("$!")
compositor_wait_for_window "$other" || fail "the second window never appeared"
compositor_place_window "$other" 600 400 300 200 >/dev/null 2>&1

: >"$log"
QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
  quickshell --no-color -p "$here/hit-region-probe.qml" >"$log" 2>&1 &
pids+=("$!")
for _ in $(seq 1 100); do grep -aq C07_READY "$log" && break; sleep 0.1; done
grep -aq C07_READY "$log" || fail "the masked surface did not start: $(grep -a ERROR "$log" | head -1)"

hits() { grep -ac C07_HIT "$log"; }

# Direction one: a click on the transparent area must reach the window below.
compositor_move_cursor 700 450 && compositor_click
sleep 0.4
before_focus="$(compositor_focused_app_id)"
before_hits="$(hits)"
compositor_move_cursor 150 150 && compositor_click
sleep 0.6
through_focus="$(compositor_focused_app_id)"
through_hits="$(hits)"

# Direction two: a click on the opaque area must be received by the surface.
compositor_move_cursor 50 50 && compositor_click
sleep 0.6
opaque_hits="$(hits)"

jq -nc \
  --arg under "$under" --arg other "$other" \
  --arg before_focus "$before_focus" --arg through_focus "$through_focus" \
  --argjson before_hits "${before_hits:-0}" \
  --argjson through_hits "${through_hits:-0}" \
  --argjson opaque_hits "${opaque_hits:-0}" \
  '{passed_through: ($through_focus == $under and $through_hits == $before_hits),
    received_on_opaque: ($opaque_hits > $through_hits)}
   | {supported: (.passed_through and .received_on_opaque), probed: true}
     + .
     + {focus_before: $before_focus, focus_after_transparent_click: $through_focus,
        hits_before: $before_hits, hits_after_transparent_click: $through_hits,
        hits_after_opaque_click: $opaque_hits,
        requirement: "a click on the transparent area reaches the window below and is not received by the surface; a click on the opaque area is received by the surface"}'
