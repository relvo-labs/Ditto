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
# Visibility is read back through Core (dittoctl probe outputs/windows), not
# through the compositor, because Core's readback is what the gate is about.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

variant="${1:---automated}"
case "$variant" in
  --automated | --physical) ;;
  *) echo "usage: tests/g1/output-hotplug/run.sh [--automated|--physical]" >&2; exit 2 ;;
esac

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

g1_begin "output-hotplug${variant/--automated/}" "EX1-13 ⑤ (${variant#--})"
g1_preflight

snapshot() {
  "$BINARIES/dittoctl" --json probe outputs >"$1.outputs.json"
  "$BINARIES/dittoctl" --json probe windows >"$1.windows.json"
  "$BINARIES/dittoctl" --json probe workspaces >"$1.workspaces.json"
  python3 "$HERE/visible.py" "$1.outputs.json" "$1.windows.json" "$1.workspaces.json"
}

output_count() {
  python3 -c 'import json, sys; print(len((json.load(open(sys.argv[1])).get("result") or {}).get("outputs", [])))' "$1.outputs.json"
}

# The character's position comes from the Shell's own report; nothing reads
# it back yet, so that half of the criterion is never claimed here.
avatar_check() {
  local listing
  listing="$(g1_capabilities)"
  if has_capability "$listing" desktop.panels.list && [[ -n "${DITTO_G1_AVATAR_READBACK:-}" ]]; then
    check avatar-visible not_implemented "avatar readback after hotplug is not written yet"
  else
    check avatar-visible not_implemented "no readback of the character's output (Shell report through desktop.panels.list)"
  fi
}

record_visibility() {
  local id="$1" before="$2" after="$3" detail="$4"
  local evidence
  evidence="$(python3 -c 'import json, sys; print(json.dumps({"before": json.loads(sys.argv[1]), "after": json.loads(sys.argv[2])}))' "$before" "$after")"
  if python3 -c 'import json, sys; sys.exit(0 if json.loads(sys.argv[1])["all_visible"] else 1)' "$after"; then
    check "$id" pass "$detail: every window is on a remaining output" "$evidence"
  else
    check "$id" fail "$detail: windows left off-screen or without geometry" "$evidence"
  fi
}

# Raw readbacks stay beside the result document.
work="$ARTIFACTS/$G1_NAME-$RUN_ID.d"
mkdir -p "$work"
g1_note "raw readbacks: $work"

if in_ditto_session; then
  export DITTO_RUNTIME_DIR="${DITTO_RUNTIME_DIR:-$XDG_RUNTIME_DIR/ditto}"
  snapshot "$work/before" >"$work/before.visible.json" || { check windows-visible fail "Core readback failed"; g1_finish; }
  if (( $(output_count "$work/before") < 2 )); then
    check windows-visible environment "only one output is connected; EX1-13 ⑤ needs the second monitor (plan/03/05 §7)"
    avatar_check
    g1_finish
  fi
  second="${DITTO_SECOND_OUTPUT:-$(python3 -c 'import json, sys; o = json.load(open(sys.argv[1]))["result"]["outputs"]; print(sorted(o, key=lambda x: (x["x"], x["y"]))[-1]["name"])' "$work/before.outputs.json")}"
  if [[ "$variant" == --automated ]]; then
    if ! command -v wlr-randr >/dev/null; then
      check windows-visible environment "wlr-randr is not installed; the automated variant needs it (zwlr_output_manager_v1)"
    else
      wlr-randr --output "$second" --off
      sleep "${DITTO_HOTPLUG_SETTLE:-3}"
      after="$(snapshot "$work/after")"
      wlr-randr --output "$second" --on || true
      record_visibility windows-visible "$(cat "$work/before.visible.json")" "$after" "wlr-randr --output $second --off"
    fi
  else
    if [[ ! -t 0 ]]; then
      check windows-visible operator "the physical variant needs an operator at a terminal"
    else
      read -r -p "Unplug the cable of $second now, then press Enter. " _
      sleep "${DITTO_HOTPLUG_SETTLE:-3}"
      after="$(snapshot "$work/after")"
      record_visibility windows-visible "$(cat "$work/before.visible.json")" "$after" "physical unplug of $second"
      read -r -p "Plug it back in and press Enter. " _
    fi
  fi
  avatar_check
  g1_finish
fi

if [[ "$variant" == --physical ]]; then
  check windows-visible environment "the physical variant runs only in a logged-in Ditto session on the reference machine"
  g1_finish
fi

# Development variant: headless Wayfire, Core in development mode, one window
# moved onto a second output created over IPC, then that output destroyed.
g1_note "headless development variant: an IPC-created output stands in for the second monitor (C-18); not EX1-13 ⑤ evidence"
start_compositor
start_core
ipc() { python3 "$WORKSPACE/tools/compositor-probe/functional/wayfire-ipc.py" "$@"; }
created="$(ipc wayfire/create-headless-output '{"width":1280,"height":720}')" || {
  check windows-visible environment "this Wayfire has no wayfire/create-headless-output"
  g1_finish
}
second="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["output"]["name"])' "$created")"
second_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["output"]["id"])' "$created")"
start_window ditto-g1-hotplug
view="$(window_id_for ditto-g1-hotplug)"
view="${view#wayfire-view-}"
# View geometry is output-local; moving to another output takes output_id.
ipc window-rules/configure-view "{\"id\":$view,\"output_id\":$second_id}" >/dev/null
sleep 1
before="$(snapshot "$work/before")"
# Without a window on the second output the unplug proves nothing. Core's
# window readback names no output, so the compositor's own answer decides it.
on_second="$(ipc window-rules/view-info "{\"id\":$view}" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("info", {}).get("output-name", ""))')"
if [[ "$on_second" != "$second" ]]; then
  check windows-visible fail "setup: the test window is not on $second before the unplug" "$before"
  avatar_check
  g1_finish
fi
ipc wayfire/destroy-headless-output "{\"output\":\"$second\"}" >/dev/null
sleep 2
after="$(snapshot "$work/after")"
# Wayfire itself moves views off a destroyed output (C-18); a pass here says
# the compositor and Core's readback agree, not that Ditto moved anything.
record_visibility windows-visible "$before" "$after" "headless output $second destroyed over IPC"
avatar_check
g1_finish
