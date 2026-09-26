#!/usr/bin/env bash
# Second probe layer: ask the compositor to actually do the thing and read the
# result back. Must run inside a live session (WAYLAND_DISPLAY set). Rows that
# this environment cannot exercise are reported as not probed, with the reason,
# rather than being left to look like a pass.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
workspace="${DITTO_WORKSPACE:-$(cd "$here/../../.." && pwd)}"
label="${1:?usage: run.sh <compositor-label>}"
: "${WAYLAND_DISPLAY:?a live Wayland session is required}"
runtime="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}"
results="$(mktemp)"

# Everything the compositor is asked about goes through this layer, so the same
# probe runs against more than one compositor without either of them being
# described in the other's terms.
source "$here/compositor.sh"

app_id=ditto-probe
foot --app-id="$app_id" sh -c 'sleep 120' >"$runtime/probe-window.log" 2>&1 &
window_pid=$!
x11_pid=""
trap 'kill "$window_pid" "$x11_pid" 2>/dev/null || true; rm -f "$results"' EXIT

compositor_wait_for_window "$app_id" || true

export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software DITTO_PROBE_APP_ID="$app_id"
toplevel_output="$(timeout 40 quickshell --no-color -p "$here/toplevel-probe.qml" 2>&1 || true)"
toplevel_json="$(sed -n 's/.*PROBE_JSON //p' <<<"$toplevel_output" | head -1)"
[[ -n "$toplevel_json" ]] || toplevel_json='{"enumeration":{"supported":false,"reason":"the probe produced no result"}}'

# C-13 repeats the neutral C-02/C-03 probe against a real XWayland client. The
# server is associated by its inherited WAYLAND_DISPLAY, not by a global :N,
# so a developer's unrelated desktop XWayland cannot be selected accidentally.
xwayland_json='{"probed":false,"reason":"no XWayland display or xterm in this environment"}'
if command -v xterm >/dev/null && x11_display="$(compositor_xwayland_display 2>/dev/null)"; then
  DISPLAY="$x11_display" xterm -class DittoX11 -title DittoX11 -e sleep 120 \
    >"$runtime/probe-x11.log" 2>&1 &
  x11_pid=$!
  if compositor_wait_for_window DittoX11; then
    x11_output="$(DITTO_PROBE_APP_ID=DittoX11 timeout 40 quickshell --no-color -p "$here/toplevel-probe.qml" 2>&1 || true)"
    x11_result="$(sed -n 's/.*PROBE_JSON //p' <<<"$x11_output" | head -1)"
    if [[ -n "$x11_result" ]]; then
      xwayland_json="$(jq -nc --argjson result "$x11_result" \
        '{probed:true, supported: (($result.enumeration.supported == true) and ([ $result.control[].observed ] | all)), c02:$result.enumeration, c03:$result.control}')"
    else
      xwayland_json='{"probed":true,"supported":false,"reason":"the XWayland toplevel probe produced no result"}'
    fi
  else
    xwayland_json='{"probed":true,"supported":false,"reason":"xterm did not map as an XWayland toplevel"}'
  fi
fi

# C-01: a panel with an exclusive zone must reserve its area. The comparison is
# against the same measurement before the panel exists, so window decorations
# are not mistaken for the zone. Where the compositor reports the area it leaves
# to applications, that is the measurement; where it does not, the position of a
# tiled window is. Which one was used is recorded with the result, because a
# compositor that places windows freely would otherwise look like a failure.
baseline_top="$(compositor_window_top "$app_id")"
baseline_usable="$(compositor_usable_top)"
cat >"$runtime/layer-probe.qml" <<'QML'
import QtQuick
import Quickshell
ShellRoot {
    PanelWindow {
        anchors { top: true; left: true; right: true }
        implicitHeight: 40
        exclusiveZone: 40
        color: "#101018"
        Component.onCompleted: console.log("LAYER_PROBE_READY")
    }
}
QML
quickshell --no-color -p "$runtime/layer-probe.qml" >"$runtime/layer-probe.log" 2>&1 &
layer_pid=$!
for _ in $(seq 1 100); do grep -aq LAYER_PROBE_READY "$runtime/layer-probe.log" && break; sleep 0.1; done
sleep 1
window_top="$(compositor_window_top "$app_id")"
usable_top="$(compositor_usable_top)"
layer_error="$(grep -a 'ERROR' "$runtime/layer-probe.log" | head -1 || true)"
kill "$layer_pid" 2>/dev/null || true
layer_json="$(jq -nc --argjson top "${window_top:-0}" --argjson baseline "${baseline_top:-0}" \
  --argjson usable "${usable_top:-null}" --argjson usable_baseline "${baseline_usable:-null}" \
  --arg error "${layer_error:-}" \
  '(if $usable == null or $usable_baseline == null
    then {measured_through: "tiled window position", shift: ($top - $baseline)}
    else {measured_through: "output work area", shift: ($usable - $usable_baseline)}
    end) as $measure
   | {supported: ($measure.shift == 40)}
     + $measure
     + {window_top: $top, baseline_top: $baseline, window_shift: ($top - $baseline),
        usable_top: $usable, baseline_usable_top: $usable_baseline,
        probe_error: (if $error == "" then null else $error end),
        requirement: "the 40 px exclusive zone must be reserved: exactly 40 px off the measured edge"}')"

outputs_json="$(compositor_outputs_json)"
workspaces_json="$(compositor_workspaces_json)"

# C-07 needs a pointer this environment can drive. Where there is none the row
# keeps its reason and no verdict, which is what it had before any compositor
# could be probed for it.
if [[ "$(compositor_pointer_injection)" == "yes" ]]; then
  hit_region_json="$(bash "$here/hit-region.sh" 2>/dev/null | tail -1)"
  [[ -n "$hit_region_json" ]] || hit_region_json='{"probed": false, "reason": "the hit region probe produced no result"}'
else
  hit_region_json='{"probed": false, "reason": "no pointer injection in this environment"}'
fi
neutral_workspaces="$(wayland-info 2>/dev/null | grep -c ext_workspace_manager_v1 || true)"
screencopy_globals="$(wayland-info 2>/dev/null | grep -Ec 'zwlr_screencopy_manager_v1|ext_image_copy_capture_manager_v1' || true)"
idle_globals="$(wayland-info 2>/dev/null | grep -Ec 'ext_idle_notifier_v1|zwp_idle_inhibit_manager_v1' || true)"
presentation_file="$runtime/ditto-presentation-probe-$$.jsonl"
if wayland-info 2>/dev/null | grep -q 'wp_presentation' \
    && command -v cc >/dev/null && command -v wayland-scanner >/dev/null \
    && pkg-config --exists wayland-client wayland-protocols; then
  if bash "$workspace/tools/presentation-probe/run.sh" 3 "$presentation_file" >/dev/null 2>&1; then
    presentation_json="$(jq -sc '{supported: (length == 3), probed: true, samples: length,
      timestamps_ns: map(.timestamp_ns), clock_id: (first.clock_id)}' "$presentation_file")"
  else
    presentation_json='{"supported": false, "probed": true, "reason": "presentation feedback client failed"}'
  fi
else
  presentation_json='{"supported": false, "probed": false, "reason": "wp_presentation or probe build dependencies unavailable"}'
fi
session_lock_json='{"supported":false,"probed":false,"reason":"ext_session_lock_v1 or probe build dependencies unavailable"}'
if wayland-info 2>/dev/null | grep -q 'ext_session_lock_manager_v1' \
    && command -v cc >/dev/null && command -v wayland-scanner >/dev/null \
    && pkg-config --exists wayland-client wayland-protocols; then
  if lock_result="$(bash "$workspace/tools/session-lock-probe/run.sh" 2>/dev/null)"; then
    session_lock_json="$lock_result"
  else
    session_lock_json='{"supported":false,"probed":true,"reason":"minimal lock flow failed"}'
  fi
fi
activation_json='{"supported":false,"probed":false,"reason":"xdg_activation_v1, pointer injection, or probe build dependencies unavailable"}'
if wayland-info 2>/dev/null | grep -q 'xdg_activation_v1' \
    && [[ "$(compositor_pointer_injection)" == yes ]] \
    && command -v cc >/dev/null && command -v wayland-scanner >/dev/null \
    && pkg-config --exists wayland-client wayland-protocols; then
  if activation_result="$(bash "$workspace/tools/activation-probe/run.sh" 2>/dev/null)"; then
    activation_json="$activation_result"
  else
    activation_json='{"supported":false,"probed":true,"reason":"pointer-authorized activation flow failed"}'
  fi
fi

jq -nc \
  --arg label "$label" \
  --argjson toplevel "$toplevel_json" \
  --argjson layer "$layer_json" \
  --argjson outputs "$outputs_json" \
  --argjson workspaces "$workspaces_json" \
  --argjson neutral "${neutral_workspaces:-0}" \
  --argjson screencopy "${screencopy_globals:-0}" \
  --argjson idle "${idle_globals:-0}" \
  --argjson hit_region "$hit_region_json" \
  --argjson presentation "$presentation_json" \
  --argjson xwayland "$xwayland_json" \
  --argjson session_lock "$session_lock_json" \
  --argjson activation "$activation_json" \
  '{
     compositor_label: $label,
     results: [
       {row: "C-01", protocol: "zwlr_layer_shell_v1", probe: "panel with an exclusive zone", evidence: $layer},
       {row: "C-02", protocol: "zwlr_foreign_toplevel_management_v1", probe: "enumerate windows and read their metadata", evidence: $toplevel.enumeration},
       {row: "C-03", protocol: "zwlr_foreign_toplevel_management_v1", probe: "request each window state and read it back", evidence: ($toplevel.control // [])},
       {row: "C-04", protocol: "none", probe: "no neutral protocol carries window coordinates", evidence: {supported: false, reason: "coordinates need the compositor IPC; see the window matrix run"}},
       {row: "C-05", protocol: "ext_workspace_manager_v1", probe: "enumerate and switch workspaces", evidence: ($workspaces + {neutral_protocol_advertised: ($neutral > 0), probed_through: "compositor IPC", reason: "the neutral protocol is advertised but no client implements it in G0"})},
       {row: "C-06", protocol: "wl_output", probe: "enumerate outputs", evidence: $outputs},
       {row: "C-07", protocol: "wl_surface.set_input_region", probe: "click the transparent area and the opaque area", evidence: $hit_region},
       {row: "C-08", protocol: "text_input_v3 + input_method_v2", probe: "type Chinese in three applications", evidence: {probed: false, reason: "requires the separate input-method diagnostic plus physical-keyboard checks in QML, terminal, and editor"}},
       {row: "C-09", protocol: "xdg_activation_v1", probe: "focus follows a pointer-authorized launcher token", evidence: $activation},
       {row: "C-10", protocol: "ext_session_lock_v1", probe: "minimal lock flow", evidence: $session_lock},
       {row: "C-11", protocol: "wlr_screencopy / portal", probe: "enumerate backends", evidence: {probed: true, supported: ($screencopy > 0), advertised_matching_globals: $screencopy}},
       {row: "C-12", protocol: "wp_presentation", probe: "presentation feedback timestamps", evidence: $presentation},
       {row: "C-13", protocol: "XWayland", probe: "repeat C-02 and C-03 with an X11 application", evidence: $xwayland},
       {row: "C-14", protocol: "ext_idle_notify_v1", probe: "enumerate", evidence: {probed: true, supported: ($idle > 0), advertised_matching_globals: $idle}}
     ]
   }'
