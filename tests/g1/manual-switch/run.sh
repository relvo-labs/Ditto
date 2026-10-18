#!/usr/bin/env bash
# EX1-01: cross-plugin switching and saving by GUI alone, no model.
#   ① Dock B replaces Dock A          ② search launcher replaces grid launcher
#   ③ floating → basic tiling         ④ saved as a new profile 「手動測試開發」
#   ⑤ duplicated as 「手動測試簡報」, appearance changed
#   ⑥ the two compared                ⑦ back to 「手動測試開發」
# Throughout: the reference applications are never terminated, Kate's
# unsaved buffer hash does not change, and afterwards no shortcut or command
# has two owners.
#
# Every GUI action is synthetic keyboard input delivered by the compositor
# (tests/g1/lib/gui.py: Tab to a control by its accessible name, Enter or
# Space, Ctrl+V for text). Every result is read back through Core by a
# relay driver that Core launched as `dittoctl` (tests/g1/lib/relay.mjs);
# the Shell is never asked whether a step worked. Opening the settings window
# itself uses the Shell's control socket (`command composition.open`), the
# same Shell-owned command the panel menu runs.
#
# The run is a headless fixture: Core in normal (non-development) mode with
# the real Shell and the built-in packages. On the reference machine
# (DITTO_REFERENCE_MACHINE=1) it uses Firefox, foot and Kate; elsewhere foot
# and Kate, and the browser half is noted. The person-run, recorded pass the
# gate also asks for is the `operator` check at the end.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g0/lib/reference-apps.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
GUI=(python3 "$WORKSPACE/tests/g1/lib/gui.py")
READ=(python3 "$HERE/readback.py")

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

g1_begin manual-switch "EX1-01"
g1_preflight
work="$(g1_evidence_dir)"
steps="$ARTIFACTS/manual-switch-$RUN_ID.jsonl"
: >"$steps"
g1_note "per-step change ids and revisions: $steps"

missing=()
for tool in quickshell node wl-copy wl-paste qdbus; do command -v "$tool" >/dev/null || missing+=("$tool"); done
[[ -d "$WORKSPACE/target/ditto-packages" ]] || missing+=("target/ditto-packages (scripts/build-builtin-packages.sh)")
if (( ${#missing[@]} > 0 )); then
  check manual-switch environment "missing: ${missing[*]}"
  g1_finish
fi

start_compositor
compositor_pointer_injection >/dev/null 2>&1 || true
export QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software
QUICKSHELL="$(readlink -f "$(command -v quickshell)")"
NODE="$(readlink -f "$(command -v node)")"
export DITTO_G1_RELAY="$RUNTIME_DIR/relay-$$.sock"
"$BINARIES/ditto-core" serve --compositor "$DITTO_COMPOSITOR" \
  --builtin-packages "$WORKSPACE/target/ditto-packages" \
  --launch "quickshell 0.2.0 $QUICKSHELL -p $WORKSPACE/shell/shell.qml" \
  --launch "dittoctl 0.2.0 $NODE $WORKSPACE/tests/g1/lib/relay.mjs $DITTO_G1_RELAY" \
  >"$RUNTIME_DIR/core.log" 2>&1 &
CORE_PID=$!
ready=""
for _ in $(seq 1 200); do
  if grep -aq 'ditto-relay ready' "$RUNTIME_DIR/core.log" && grep -aq '"role":"shell"' "$RUNTIME_DIR/core.log" \
    && [[ -S "$DITTO_RUNTIME_DIR/shell.sock" ]]; then ready=1; break; fi
  kill -0 "$CORE_PID" 2>/dev/null || break
  sleep 0.1
done
if [[ -z "$ready" ]]; then
  cp "$RUNTIME_DIR/core.log" "$work/core.log" 2>/dev/null || true
  check manual-switch fail "the fixture did not come up (Core, Shell boot sync, relay); log in $work/core.log"
  g1_finish
fi

# Reference applications, and Kate's unsaved buffer.
if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
  start_all_reference_apps
else
  REFERENCE_APP_ROLES=() REFERENCE_APP_IDS=() REFERENCE_APP_PIDS=()
  start_reference_app terminal
  start_reference_app editor
  g1_note "development run: foot and Kate only; Firefox runs on the reference machine"
fi
kate_open_unsaved "Ditto EX1-01 未儲存緩衝 $RUN_ID"
sleep 1
kate_before="$(kate_unsaved_hash)"

apps_alive() {
  local pid
  for pid in "${REFERENCE_APP_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || return 1; done
}

open_center() {
  python3 - "$DITTO_RUNTIME_DIR/shell.sock" "$1" <<'PYEOF'
import socket, sys
connection = socket.socket(socket.AF_UNIX)
connection.connect(sys.argv[1])
connection.sendall(f"command {sys.argv[2]}\n".encode())
connection.close()
PYEOF
  # The settings window must hold the keyboard focus: the compositor gives
  # it to a new toplevel, and to the window under test again after Kate.
  for _ in $(seq 1 50); do
    "${GUI[@]}" focus 2>/dev/null | grep -q '"open": true' && break
    sleep 0.1
  done
  compositor_focus_window quickshell >/dev/null 2>&1 || compositor_focus_window org.quickshell >/dev/null 2>&1 || true
  sleep 0.5
}

# step <id> <criterion> <readback args...>: record one readback as a check
# and a line of the per-step file.
step() {
  local id="$1" criterion="$2" answer status
  shift 2
  answer="$("${READ[@]}" "$@")"
  if [[ "$(jq -r .ok <<<"$answer")" == true ]] && apps_alive; then
    status=pass
  else
    status=fail
    apps_alive || answer="$(jq -c '. + {apps_alive: false}' <<<"$answer")"
  fi
  check "$id" "$status" "$criterion — $(jq -r .detail <<<"$answer")" "$answer"
  jq -c --arg step "$id" --arg status "$status" '{step: $step, status: $status} + .' <<<"$answer" >>"$steps"
  grim "$work/$id.png" 2>/dev/null || true
}

# gui <id> <tab-to args...> -- <press args>: one keyboard action; a control
# that Tab cannot reach fails the step it belongs to.
gui_fail=""
gui() {
  if ! "${GUI[@]}" tab-to "$@" >>"$work/gui.log" 2>&1; then
    gui_fail="Tab could not reach '$1' ($(tail -1 "$work/gui.log"))"
    return 1
  fi
}

run_step() {
  local id="$1"
  shift
  echo "[$id] focused view before: $(compositor_focused_app_id 2>/dev/null); $("${GUI[@]}" focus 2>/dev/null)" >>"$work/gui.log"
  gui_fail=""
  if ! "$@"; then
    check "$id" fail "${gui_fail:-the GUI action failed}"
    printf '{"step":"%s","status":"fail","detail":%s}\n' "$id" "$(jq -Rn --arg d "${gui_fail:-GUI action failed}" '$d')" >>"$steps"
    return 1
  fi
}

choose_and_apply() {
  local group="$1" option="$2"
  gui "$option" --group "$group" && "${GUI[@]}" press space && sleep 0.5 \
    && gui "套用" --group "$group" && "${GUI[@]}" press
}

# ① swaps to whichever Dock is not in use. Choosing the Dock already in use
# leaves nothing to apply, so 「套用」 is (rightly) not shown; since #71 the
# default Profile starts on the pill Dock (#92).
# Only a known Dock counts as "Dock A": an unbound slot or a failed readback
# would turn ① into adding a Dock, not replacing one, so ① fails instead.
dock_now="$("${READ[@]}" slot-package ui.dock 2>&1)" || dock_now="readback failed: $dock_now"
case "$dock_now" in
  ditto.dock.pill) dock_target=ditto.dock.bottom dock_label="視窗列 Dock" ;;
  ditto.dock.bottom) dock_target=ditto.dock.pill dock_label="膠囊式 Dock" ;;
  *) dock_target="" dock_label="" ;;
esac

open_center composition.open
before="$("${READ[@]}" last-change)"
if [[ -z "$dock_target" ]]; then
  check dock-swap fail "① the Dock in use is not a known Dock ($dock_now); there is no Dock A to replace"
  printf '{"step":"dock-swap","status":"fail","detail":%s}\n' "$(jq -Rn --arg d "unknown Dock A: $dock_now" '$d')" >>"$steps"
else
  run_step dock-swap choose_and_apply Dock "$dock_label" \
    && step dock-swap "① $dock_target replaces the Dock in use ($dock_now)" swap "$before" ui.dock "$dock_target"
fi

before="$("${READ[@]}" last-change)"
run_step launcher-swap choose_and_apply "啟動器" "搜尋式啟動器" \
  && step launcher-swap "② search launcher replaces grid launcher" swap "$before" ui.launcher ditto.launcher.search

before="$("${READ[@]}" last-change)"
run_step layout-tile choose_and_apply "布局策略" "基本平鋪" \
  && step layout-tile "③ floating → basic tiling, read back from the compositor" layout "$before" ditto.layout.simple-tile simple-tile

active_name="$("${GUI[@]}" relay desktop.profiles.get '{}' | jq -r .result.profile.name)"
duplicate_as() {
  local source="$1" name="$2"
  gui "複製" --group "$source" && "${GUI[@]}" press \
    && gui "複本的名稱" --group "$source" && "${GUI[@]}" paste "$name" \
    && gui "複製" --group "$source" && "${GUI[@]}" press && sleep 1 \
    && gui "使用這個組合" --group "$name" && "${GUI[@]}" press
}
expected="$(jq -cn --arg dock "$dock_target" '{"ui.dock":$dock,"ui.launcher":"ditto.launcher.search","layout.strategy":"ditto.layout.simple-tile"}')"
run_step save-dev duplicate_as "$active_name" "手動測試開發" \
  && step save-dev "④ the composition saved as a new profile 「手動測試開發」 and in use" saved-as "手動測試開發" "$expected"

run_step duplicate-presentation duplicate_as "手動測試開發" "手動測試簡報" \
  && step duplicate-presentation "⑤ 「手動測試開發」 duplicated as 「手動測試簡報」 and in use" saved-as "手動測試簡報" "$expected"

open_center personalization.open
before="$("${READ[@]}" last-change)"
larger_text() { gui "較大" --group "文字大小" && "${GUI[@]}" press space; }
run_step presentation-appearance larger_text \
  && step presentation-appearance "⑤ 「手動測試簡報」 appearance changed (larger text)" appearance "$before" "手動測試簡報" /appearance/tokens/font_scale 1.15

open_center composition.open
compare() { gui "與目前使用的比較" --group "手動測試開發" && "${GUI[@]}" press; }
run_step compare compare \
  && step compare "⑥ 「手動測試開發」 and 「手動測試簡報」 compared: they differ in appearance only" compared "手動測試開發" "手動測試簡報" /appearance

switch_back() { gui "使用這個組合" --group "手動測試開發" && "${GUI[@]}" press; }
run_step back-to-dev switch_back \
  && step back-to-dev "⑦ back to 「手動測試開發」: its Dock, launcher and layout are in force" saved-as "手動測試開發" "$expected"

owners="$("${READ[@]}" owners)"
if [[ "$(jq -r .ok <<<"$owners")" == true ]]; then
  check no-duplicate-owners pass "desktop.shortcuts.list and desktop.commands.list: no duplicate owners" "$owners"
else
  check no-duplicate-owners fail "duplicate owners after the switches" "$owners"
fi

if apps_alive; then
  check apps-survive pass "reference applications (${REFERENCE_APP_IDS[*]}) were never terminated"
else
  check apps-survive fail "a reference application was terminated during the script"
fi
kate_after="$(kate_unsaved_hash)"
if [[ -n "$kate_before" && "$kate_before" == "$kate_after" ]]; then
  check kate-buffer pass "Kate's unsaved buffer hash is unchanged ($kate_before)"
else
  check kate-buffer fail "Kate's unsaved buffer hash changed or could not be read ($kate_before → $kate_after)"
fi

cp "$RUNTIME_DIR/core.log" "$work/core.log" 2>/dev/null || true
check person-recorded operator "a person who did not implement it runs the seven steps by hand and records it (plan/03/01 EX1-01)"
g1_finish
