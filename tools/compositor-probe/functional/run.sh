#!/usr/bin/env bash
# Second probe layer: ask the compositor to actually do the thing and read the
# result back. Must run inside a live session (WAYLAND_DISPLAY set). Rows that
# this environment cannot exercise are reported as not probed, with the reason,
# rather than being left to look like a pass.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
workspace="${DITTO_WORKSPACE:-/workspace}"
label="${1:?usage: run.sh <compositor-label>}"
: "${WAYLAND_DISPLAY:?a live Wayland session is required}"
runtime="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}"
results="$(mktemp)"

app_id=ditto-probe
foot --app-id="$app_id" sh -c 'sleep 120' >"$runtime/probe-window.log" 2>&1 &
window_pid=$!
trap 'kill "$window_pid" 2>/dev/null || true; rm -f "$results"' EXIT

for _ in $(seq 1 100); do
  swaymsg --raw --type get_tree 2>/dev/null | jq -e --arg id "$app_id" '[.. | objects | select(.app_id? == $id)] | length == 1' >/dev/null && break
  sleep 0.1
done

export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software DITTO_PROBE_APP_ID="$app_id"
toplevel_output="$(timeout 40 quickshell --no-color -p "$here/toplevel-probe.qml" 2>&1 || true)"
toplevel_json="$(sed -n 's/.*PROBE_JSON //p' <<<"$toplevel_output" | head -1)"
[[ -n "$toplevel_json" ]] || toplevel_json='{"enumeration":{"supported":false,"reason":"the probe produced no result"}}'

# C-01: a panel with an exclusive zone must push tiled windows out of its area.
# The comparison is against the same window before the panel exists, so window
# decorations are not mistaken for the zone.
baseline_top="$(swaymsg --raw --type get_tree | jq --arg id "$app_id" 'first(.. | objects | select(.app_id? == $id) | .rect.y)')"
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
window_top="$(swaymsg --raw --type get_tree | jq --arg id "$app_id" 'first(.. | objects | select(.app_id? == $id) | .rect.y)')"
layer_error="$(grep -a 'ERROR' "$runtime/layer-probe.log" | head -1 || true)"
kill "$layer_pid" 2>/dev/null || true
layer_json="$(jq -nc --argjson top "${window_top:-0}" --argjson baseline "${baseline_top:-0}" \
  --arg error "${layer_error:-}" \
  '{supported: (($top - $baseline) == 40), window_top: $top, baseline_top: $baseline, shift: ($top - $baseline),
    probe_error: (if $error == "" then null else $error end),
    requirement: "a tiled window must move down by exactly the 40 px exclusive zone"}')"

outputs_json="$(swaymsg --raw --type get_outputs | jq -c '{count: length, first: (.[0] | {name, width: .rect.width, height: .rect.height, scale})}')"
workspaces_json="$(swaymsg --raw --type get_workspaces | jq -c '{count: length}')"
neutral_workspaces="$(wayland-info 2>/dev/null | grep -c ext_workspace_manager_v1 || true)"

jq -nc \
  --arg label "$label" \
  --argjson toplevel "$toplevel_json" \
  --argjson layer "$layer_json" \
  --argjson outputs "$outputs_json" \
  --argjson workspaces "$workspaces_json" \
  --argjson neutral "${neutral_workspaces:-0}" \
  '{
     compositor_label: $label,
     results: [
       {row: "C-01", protocol: "zwlr_layer_shell_v1", probe: "panel with an exclusive zone", evidence: $layer},
       {row: "C-02", protocol: "zwlr_foreign_toplevel_management_v1", probe: "enumerate windows and read their metadata", evidence: $toplevel.enumeration},
       {row: "C-03", protocol: "zwlr_foreign_toplevel_management_v1", probe: "request each window state and read it back", evidence: ($toplevel.control // [])},
       {row: "C-04", protocol: "none", probe: "no neutral protocol carries window coordinates", evidence: {supported: false, reason: "coordinates need the compositor IPC; see the window matrix run"}},
       {row: "C-05", protocol: "ext_workspace_manager_v1", probe: "enumerate and switch workspaces", evidence: ($workspaces + {neutral_protocol_advertised: ($neutral > 0), probed_through: "compositor IPC", reason: "the neutral protocol is advertised but no client implements it in G0"})},
       {row: "C-06", protocol: "wl_output", probe: "enumerate outputs", evidence: $outputs},
       {row: "C-07", protocol: "wl_surface.set_input_region", probe: "click the transparent area and the opaque area", evidence: {probed: false, reason: "no pointer injection in this environment"}},
       {row: "C-08", protocol: "text_input_v3 + input_method_v2", probe: "type Chinese in three applications", evidence: {probed: false, reason: "no input method installed in this environment"}},
       {row: "C-09", protocol: "xdg_activation_v1", probe: "focus follows a launch", evidence: {probed: false, reason: "not exercised yet"}},
       {row: "C-10", protocol: "ext_session_lock_v1", probe: "minimal lock flow", evidence: {probed: false, reason: "inventory only in G0"}},
       {row: "C-11", protocol: "wlr_screencopy / portal", probe: "enumerate backends", evidence: {probed: false, reason: "inventory only in G0"}},
       {row: "C-12", protocol: "wp_presentation", probe: "one presentation timestamp", evidence: {probed: false, reason: "cross-check belongs to the reference machine"}},
       {row: "C-13", protocol: "XWayland", probe: "repeat C-02 and C-03 with an X11 application", evidence: {probed: false, reason: "no X11 application in this environment"}},
       {row: "C-14", protocol: "ext_idle_notify_v1", probe: "enumerate", evidence: {probed: false, reason: "inventory only in G0"}}
     ]
   }'
