#!/usr/bin/env bash
# G2-PLAT-01 (D-40) on Wayfire: savable region layout with real windows.
#   ① editor left half, terminal right half, in one ChangeSet: geometry read
#      back from Wayfire within 2 px of the work-area share
#   ② "a bit narrower": only the terminal rule changes; the editor stays
#   ③ undo restores the terminal
#   ④ a terminal opened later goes to its region (event-driven, no change)
#   ⑤ a tiled strategy refuses region rules; applications survive throughout
# Headless Wayfire with the real Shell (its panel's exclusive zone shapes the
# work area). Development evidence.
set -euo pipefail
export DITTO_ARTIFACTS="${DITTO_ARTIFACTS:-$(cd "$(dirname "$0")/../../.." && pwd)/artifacts/g2}"
source "$(cd "$(dirname "$0")/../../g1" && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
WINDOW_PIDS=()
trap shell_fixture_stop EXIT INT TERM
g1_begin g2-layout "G2-PLAT-01 region layout (development)"
g1_preflight
evidence="$(g1_evidence_dir)"
for tool in quickshell node jq foot kate; do command -v "$tool" >/dev/null || { check environment environment "missing $tool"; g1_finish; }; done

start_compositor >/dev/null
if ! shell_fixture_start; then
  cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
  check fixture fail "the desktop fixture did not come up"; g1_finish
fi
start_reference_app terminal
start_reference_app editor
term="$(reference_app_id terminal)" editor="$(reference_app_id editor)"

head_rev() { relay desktop.profiles.get '{}' | jq -r .result.profile.head_revision; }
propose() { relay desktop.changes.propose "$(jq -cn --arg base "$(head_rev)" --argjson ops "$1" '{base_revision:$base, ops:$ops}')"; }
layout() { relay desktop.layout.get '{}' | jq -c .result; }
# Every region window within 2 px of its rule's share of its output's work
# area. The work area comes from Wayfire itself (list-outputs).
within() { # <layout-json> <rule_id> <expected [x,y,w,h]>
  jq -e --arg rule "$2" --argjson want "$3" '[.region_windows[] | select(.rule_id==$rule) | .geometry]
    | length > 0 and all(. as $g | [range(4)] | all(($g[.] - $want[.]) | fabs <= 2))' <<<"$1" >/dev/null
}
area="$(python3 - "$WAYFIRE_SOCKET" <<'PYEOF'
import json, socket, struct, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
body = json.dumps({"method": "window-rules/list-outputs", "data": {}}).encode()
s.sendall(struct.pack("<I", len(body)) + body)
n = struct.unpack("<I", s.recv(4))[0]; data = b""
while len(data) < n: data += s.recv(n - len(data))
out = json.loads(data)[0]; g, w = out["geometry"], out["workarea"]
print(json.dumps([w["x"] - g["x"], w["y"] - g["y"], w["width"], w["height"]]))
PYEOF
)"
echo "$area" >"$evidence/workarea.json"
share() { python3 -c "import json,sys; a=json.loads(sys.argv[1]); r=[float(v) for v in sys.argv[2:]]; print(json.dumps([a[0]+round(r[0]*a[2]), a[1]+round(r[1]*a[3]), round(r[2]*a[2]), round(r[3]*a[3])]))" "$area" "$@"; }

# ① left / right
rules="$(jq -cn --arg t "$term" --arg e "$editor" '[
  {rule_id:"editor-left", match:{app_id:$e}, region:{x:0,y:0,width:0.5,height:1}},
  {rule_id:"terminal-right", match:{app_id:$t}, region:{x:0.5,y:0,width:0.5,height:1}}]')"
result="$(propose "[{\"op\":\"set_value\",\"path\":\"/layout/regions\",\"after\":$rules}]")"
echo "$result" >"$evidence/place.json"
now="$(layout)"; echo "$now" >"$evidence/layout-placed.json"
if jq -e '.result.state=="committed" and .result.result=="succeeded"' <<<"$result" >/dev/null \
  && within "$now" editor-left "$(share 0 0 0.5 1)" && within "$now" terminal-right "$(share 0.5 0 0.5 1)"; then
  check place pass "editor left, terminal right, read back from Wayfire (work area $area)" "$(jq -c .region_windows <<<"$now")"
else
  check place fail "placement not confirmed" "$(jq -c '{state:.result.state,result:.result.result,items:.result.items}' <<<"$result")"
fi
editor_before="$(jq -c '[.region_windows[]|select(.rule_id=="editor-left")|.geometry]' <<<"$now")"

# ② narrower terminal, editor untouched
result="$(propose '[{"op":"set_value","path":"/layout/regions/1/region","after":{"x":0.6,"y":0,"width":0.4,"height":1}}]')"
change="$(jq -r .result.change_id <<<"$result")"
now="$(layout)"
if jq -e '.result.state=="committed"' <<<"$result" >/dev/null && within "$now" terminal-right "$(share 0.6 0 0.4 1)" \
  && [[ "$(jq -c '[.region_windows[]|select(.rule_id=="editor-left")|.geometry]' <<<"$now")" == "$editor_before" ]]; then
  check narrower pass "the terminal rule narrowed to 40%; the editor did not move" "$(jq -c .region_windows <<<"$now")"
else
  check narrower fail "narrowing not confirmed" "$now"
fi

# ③ undo
relay desktop.changes.undo "{\"change_id\":\"$change\",\"idempotency_key\":\"layout-undo\"}" >"$evidence/undo.json"
now="$(layout)"
within "$now" terminal-right "$(share 0.5 0 0.5 1)" && check undo pass "undo put the terminal back to its half" \
  || check undo fail "after undo" "$now"

# ④ a terminal opened later
foot --app-id="$term" sh -c 'sleep infinity' >"$RUNTIME_DIR/foot2.log" 2>&1 &
WINDOW_PIDS+=($!)
ok=""
for _ in $(seq 1 50); do
  now="$(layout)"
  if [[ "$(jq '[.region_windows[]|select(.rule_id=="terminal-right")]|length' <<<"$now")" == 2 ]] && within "$now" terminal-right "$(share 0.5 0 0.5 1)"; then ok=1; break; fi
  sleep 0.2
done
[[ -n "$ok" ]] && check new-window pass "a terminal opened afterwards went to the right half" "$(jq -c .region_windows <<<"$now")" \
  || check new-window fail "the new terminal was not placed" "$now"

# ⑤ tiling refuses region rules
floating="$(relay desktop.profiles.get '{}' | jq -r '.result.document.entries[]|select(.package=="ditto.layout.floating")|.entry_id')"
tile_version="$(relay desktop.plugins.list '{}' | jq -r '.result.packages[]|select(.package_id=="ditto.layout.simple-tile")|.version' | head -n1)"
result="$(propose "[{\"op\":\"add_entry\",\"entry\":{\"package\":\"ditto.layout.simple-tile\",\"version\":\"$tile_version\",\"host\":\"core_builtin\"},\"slot\":\"layout.strategy\"},{\"op\":\"remove_entry\",\"entry_id\":\"$floating\"}]")"
echo "$result" >"$evidence/tiling.json"
jq -e '.result.state=="aborted" and ([.result.items[]? | select(.key=="regions" and .status=="failed")] | length == 1)' <<<"$result" >/dev/null \
  && check tiling-refused pass "switching to tiling while region rules exist is refused at prepare" "$(jq -c '{state:.result.state,items:[.result.items[]|select(.key=="regions")]}' <<<"$result")" \
  || check tiling-refused fail "not refused for the region rules" "$(jq -c . <<<"$result")"
apps_alive && check apps pass "foot and Kate ran throughout" || check apps fail "a reference application ended"
cp "$RUNTIME_DIR/core.log" "$evidence/core.log" 2>/dev/null || true
g1_finish
