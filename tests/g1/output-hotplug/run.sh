#!/usr/bin/env bash
# EX1-13 ⑤: unplugging the second monitor brings windows and the character
# back into the visible area (DES-08). plan/03/05 §7 requires both variants:
#
#   run.sh --automated   disable the second output with wlr-randr in a
#                        logged-in Ditto session; without a session it runs a
#                        headless development variant instead (a second output
#                        created and destroyed over Wayfire IPC, matrix C-18)
#   run.sh --physical    operator-guided: the script asks for the cable to be
#                        pulled and reads the result back
#
# Everything is read back through Core: windows from `dittoctl probe
# outputs/windows/workspaces` (each window names its output), the character
# from the Shell's report through `desktop.panels.list`. Before the unplug the
# character is put on the second output with a ChangeSet, so its return to
# the primary output is observed, not assumed; in a logged-in session that
# change is undone at the end.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

variant="${1:---automated}"
case "$variant" in
  --automated | --physical) ;;
  *) echo "usage: tests/g1/output-hotplug/run.sh [--automated|--physical]" >&2; exit 2 ;;
esac

WINDOW_PIDS=()
SHELL_PID=""
AVATAR_CHANGE=""
cleanup() {
  # Only the logged-in session keeps its Profile; the headless store is thrown away.
  if [[ -n "$AVATAR_CHANGE" ]] && in_ditto_session; then
    "$BINARIES/dittoctl" --json probe call desktop.changes.undo "{\"change_id\":\"$AVATAR_CHANGE\"}" >/dev/null 2>&1 || true
  fi
  [[ -n "$SHELL_PID" ]] && kill "$SHELL_PID" 2>/dev/null || true
  stop_all
}
trap cleanup EXIT INT TERM

g1_begin "output-hotplug${variant/--automated/}" "EX1-13 ⑤ (${variant#--})"
g1_preflight

snapshot() {
  "$BINARIES/dittoctl" --json probe outputs >"$1.outputs.json"
  "$BINARIES/dittoctl" --json probe windows >"$1.windows.json"
  "$BINARIES/dittoctl" --json probe workspaces >"$1.workspaces.json"
  "$BINARIES/dittoctl" --json probe call desktop.panels.list '{}' >"$1.panels.json" 2>/dev/null || echo '{}' >"$1.panels.json"
  python3 "$HERE/visible.py" "$1.outputs.json" "$1.windows.json" "$1.workspaces.json"
}

output_count() {
  python3 -c 'import json, sys; print(len((json.load(open(sys.argv[1])).get("result") or {}).get("outputs", [])))' "$1.outputs.json"
}

# placement <panels.json> <field>: one field of the reported placement.
placement() {
  python3 -c 'import json, sys; p = ((json.load(open(sys.argv[1])).get("result") or {}).get("avatar") or {}); v = p.get(sys.argv[2]); print("" if v is None else json.dumps(v).strip("\""))' "$1" "$2"
}

# Wait until the Shell reports the character on <output> (or on any output
# when empty), at most <seconds>.
wait_for_placement() {
  local output="$1" seconds="${2:-10}" panels="$work/wait.panels.json" _
  for _ in $(seq 1 $((seconds * 4))); do
    "$BINARIES/dittoctl" --json probe call desktop.panels.list '{}' >"$panels" 2>/dev/null || true
    local on
    on="$(placement "$panels" output 2>/dev/null || true)"
    if [[ -n "$on" && ( -z "$output" || "$on" == "$output" ) ]]; then return 0; fi
    sleep 0.25
  done
  return 1
}

# Put the character on <output> through a ChangeSet: the same path as the
# personalization center. Sets AVATAR_CHANGE; prints the change record.
avatar_to() {
  local head record
  head="$(g1_head | cut -d' ' -f1)"
  record="$(g1_call desktop.changes.propose "{\"base_revision\":\"$head\",\"ops\":[{\"op\":\"set_value\",\"path\":\"/avatar/output\",\"after\":\"$1\"}]}" 2>/dev/null || true)"
  AVATAR_CHANGE="$(python3 -c 'import json, sys; r = json.loads(sys.argv[1] or "{}").get("result") or {}; print(r.get("change_id", "") if r.get("state") == "committed" else "")' "$record")"
  echo "$record"
}

record_visibility() {
  local id="$1" before="$2" after="$3" detail="$4"
  local evidence
  evidence="$(python3 -c 'import json, sys; print(json.dumps({"before": json.loads(sys.argv[1]), "after": json.loads(sys.argv[2]), "core_log": sys.argv[3].splitlines()}))' "$before" "$after" "${5:-}")"
  if python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1])["all_visible"] else 1)' "$after"; then
    check "$id" pass "$detail: every window is on a remaining output, inside it" "$evidence"
  else
    check "$id" fail "$detail: windows left off-screen, on a missing output or without geometry" "$evidence"
  fi
}

# avatar_check <before-prefix> <after-prefix> <second> <detail>
avatar_check() {
  local before="$1" after="$2" second="$3" detail="$4" verdict evidence
  if ! has_capability "$(g1_capabilities)" desktop.panels.list; then
    check avatar-visible not_implemented "Core does not serve desktop.panels.list"
    return
  fi
  verdict="$(python3 "$HERE/avatar.py" "$after.outputs.json" "$after.panels.json" expect_primary)"
  evidence="$(python3 -c 'import json, sys; print(json.dumps({"before": json.load(open(sys.argv[1])).get("result"), "after": json.loads(sys.argv[2])}))' "$before.panels.json" "$verdict")"
  if [[ "$(placement "$before.panels.json" output)" != "$second" ]]; then
    check avatar-visible fail "setup: the character was not on $second before the unplug" "$evidence"
  elif python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1])["visible"] else 1)' "$verdict"; then
    check avatar-visible pass "$detail: the character left $second for the primary output and is inside it" "$evidence"
  else
    check avatar-visible fail "$detail: $(python3 -c 'import json, sys; print("; ".join(json.loads(sys.argv[1])["problems"]))' "$verdict")" "$evidence"
  fi
}

# Raw readbacks stay beside the result document.
work="$ARTIFACTS/$G1_NAME-$RUN_ID.d"
mkdir -p "$work"
g1_note "raw readbacks: $work"

if in_ditto_session; then
  export DITTO_RUNTIME_DIR="${DITTO_RUNTIME_DIR:-$XDG_RUNTIME_DIR/ditto}"
  snapshot "$work/start" >"$work/start.visible.json" || { check windows-visible fail "Core readback failed"; g1_finish; }
  if (( $(output_count "$work/start") < 2 )); then
    check windows-visible environment "only one output is connected; EX1-13 ⑤ needs the second monitor (plan/03/05 §7)"
    check avatar-visible environment "only one output is connected; the character cannot leave an output that is not there"
    g1_finish
  fi
  second="${DITTO_SECOND_OUTPUT:-$(python3 -c 'import json, sys; o = json.load(open(sys.argv[1]))["result"]["outputs"]; print(sorted(o, key=lambda x: (x["x"], x["y"], x["name"]))[-1]["name"])' "$work/start.outputs.json")}"
  avatar_to "$second" >"$work/avatar-to-second.json"
  wait_for_placement "$second" 10 || g1_note "the Shell did not report the character on $second within 10 s"
  before="$(snapshot "$work/before")"
  if [[ "$variant" == --automated ]]; then
    if ! command -v wlr-randr >/dev/null; then
      check windows-visible environment "wlr-randr is not installed; the automated variant needs it (zwlr_output_manager_v1)"
      check avatar-visible environment "wlr-randr is not installed"
    else
      wlr-randr --output "$second" --off
      sleep "${DITTO_HOTPLUG_SETTLE:-3}"
      after="$(snapshot "$work/after")"
      wlr-randr --output "$second" --on || true
      record_visibility windows-visible "$before" "$after" "wlr-randr --output $second --off"
      avatar_check "$work/before" "$work/after" "$second" "wlr-randr --output $second --off"
    fi
  else
    if [[ ! -t 0 ]]; then
      check windows-visible operator "the physical variant needs an operator at a terminal"
      check avatar-visible operator "the physical variant needs an operator at a terminal"
    else
      read -r -p "Unplug the cable of $second now, then press Enter. " _
      sleep "${DITTO_HOTPLUG_SETTLE:-3}"
      after="$(snapshot "$work/after")"
      record_visibility windows-visible "$before" "$after" "physical unplug of $second"
      avatar_check "$work/before" "$work/after" "$second" "physical unplug of $second"
      read -r -p "Plug it back in and press Enter. " _
    fi
  fi
  g1_finish
fi

if [[ "$variant" == --physical ]]; then
  check windows-visible environment "the physical variant runs only in a logged-in Ditto session on the reference machine"
  check avatar-visible environment "the physical variant runs only in a logged-in Ditto session on the reference machine"
  g1_finish
fi

# Development variant: headless Wayfire, Core in development mode and the
# Shell beside it; one window and the character moved onto a second output
# created over IPC, then that output destroyed.
g1_note "headless development variant: an IPC-created output stands in for the second monitor (C-18); not EX1-13 ⑤ evidence"
start_compositor
start_core
ipc() { python3 "$WORKSPACE/tools/compositor-probe/functional/wayfire-ipc.py" "$@"; }
created="$(ipc wayfire/create-headless-output '{"width":1280,"height":720}')" || {
  check windows-visible environment "this Wayfire has no wayfire/create-headless-output"
  check avatar-visible environment "this Wayfire has no wayfire/create-headless-output"
  g1_finish
}
second="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["output"]["name"])' "$created")"
second_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["output"]["id"])' "$created")"

# The Shell, as the G0 fixtures start it: a development Core hands it the
# shared token through DITTO_DEV_TOKEN.
shell_started=false
if command -v quickshell >/dev/null; then
  export QT_QPA_PLATFORM=wayland
  [[ -z "${DITTO_REFERENCE_MACHINE:-}" ]] && export QT_QUICK_BACKEND=software
  quickshell --no-color -p "$WORKSPACE/shell/shell.qml" >"$RUNTIME_DIR/shell.log" 2>&1 &
  SHELL_PID=$!
  for _ in $(seq 1 150); do grep -aq 'ditto-shell started' "$RUNTIME_DIR/shell.log" && break; sleep 0.1; done
  grep -aq 'ditto-shell started' "$RUNTIME_DIR/shell.log" && shell_started=true
fi

start_window ditto-g1-hotplug
view="$(window_id_for ditto-g1-hotplug)"
view="${view#wayfire-view-}"
# View geometry is output-local; moving to another output takes output_id.
ipc window-rules/configure-view "{\"id\":$view,\"output_id\":$second_id}" >/dev/null
avatar_ready=false
if $shell_started && wait_for_placement "" 15; then
  avatar_to "$second" >"$work/avatar-to-second.json"
  wait_for_placement "$second" 10 && avatar_ready=true
fi
sleep 1
before="$(snapshot "$work/before")"
# Without a window on the second output the unplug proves nothing; Core's
# readback names the output each window is on.
on_second="$(python3 -c 'import json, sys; w = (json.load(open(sys.argv[1])).get("result") or {}).get("windows", []); print(next((x.get("output", "") for x in w if x.get("app_id") == "ditto-g1-hotplug"), ""))' "$work/before.windows.json")"
if [[ "$on_second" != "$second" ]]; then
  check windows-visible fail "setup: Core's readback does not put the test window on $second before the unplug" "$before"
fi
ipc wayfire/destroy-headless-output "{\"output\":\"$second\"}" >/dev/null
# Core waits for Wayfire's own moves (outputs::SETTLE, 0.5 s) before it acts.
sleep "${DITTO_HOTPLUG_SETTLE:-3}"
after="$(snapshot "$work/after")"
core_log="$(grep -a '"event":"outputs\.' "$RUNTIME_DIR/core.log" || true)"
if [[ "$on_second" == "$second" ]]; then
  # Wayfire itself moves views off a destroyed output (C-18); Core reads them
  # back and moves only what is still off-screen. Its log says which it did.
  record_visibility windows-visible "$before" "$after" "headless output $second destroyed over IPC" "$core_log"
fi
if ! $shell_started; then
  check avatar-visible environment "quickshell is not on PATH or the Shell did not start (see $RUNTIME_DIR/shell.log)"
elif ! $avatar_ready; then
  check avatar-visible fail "setup: the Shell never reported the character on $second" \
    "$(python3 -c 'import json, sys; print(json.dumps({"change": json.load(open(sys.argv[1])) if sys.argv[1] else None}))' "$work/avatar-to-second.json" 2>/dev/null || echo null)"
else
  avatar_check "$work/before" "$work/after" "$second" "headless output $second destroyed over IPC"
fi
g1_finish
