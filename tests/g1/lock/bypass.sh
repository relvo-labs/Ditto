#!/usr/bin/env bash
# QA-04 / AT-17. Run in a disposable logged-in Ditto Wayfire seat.
# Keeps the lock client alive for the four scenarios. run.sh separately kills
# both the lock client and Shell; password unlock + recording remains manual.
set -euo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
LOCK_TEST_DIR="$WORKSPACE/tests/g1/lock"
MARKER_PID=""
trap '[[ -z "$MARKER_PID" ]] || kill "$MARKER_PID" 2>/dev/null || true' EXIT
g1_begin lock-bypass AT-17
g1_preflight
if ! in_ditto_session; then
  for scenario in shell-crash replace-ui plugin-update rescue; do
    check "$scenario" environment "未執行（需 VM／參考機 Ditto Wayfire 登入座位）"
  done
  g1_finish
fi
for tool in foot grim jq python3; do
  if ! command -v "$tool" >/dev/null; then
    check prerequisites environment "missing $tool"
    g1_finish
  fi
done
work="$(g1_evidence_dir)"
capture() {
  local destination="$1"
  if ! timeout 5 grim -t ppm "$destination" 2>/dev/null; then return 3; fi
  python3 "$LOCK_TEST_DIR/pixels.py" < "$destination"
}
locked_state() {
  g1_call desktop.session.state '{}' | jq -e '.result.locked == true' >/dev/null
}
foot --app-id=ditto-qa04-lock-marker -o colors.background=00ff00 -o colors.foreground=00ff00 \
  sh -c 'sleep 600' >/dev/null 2>&1 &
MARKER_PID=$!
sleep 2
before="$(capture "$work/marker-before.ppm" || true)"
if ! python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > .01 else 1)' "$before"; then
  check marker environment "desktop marker could not be observed before locking"
  g1_finish
fi
g1_call desktop.session.lock '{}' > "$work/lock.json"
secured=""
for _ in $(seq 1 100); do
  fraction="$(capture "$work/secured.ppm" || true)"
  if locked_state && [[ "$fraction" == 0.0 ]]; then secured=1; break; fi
  sleep .1
done
if [[ -z "$secured" ]]; then
  check initial-lock environment "no confirmed lock with readable, opaque capture"
  g1_finish
fi

assert_opaque() {
  local scenario="$1" value index
  for index in $(seq 1 20); do
    if ! locked_state; then check "$scenario" fail "Core no longer reports locked"; return; fi
    if ! value="$(capture "$work/$scenario-$index.ppm")"; then
      check "$scenario" environment "capture denied: desktop exposure undetermined"; return
    fi
    if [[ "$value" != 0.0 ]]; then check "$scenario" fail "desktop marker exposed"; return; fi
    sleep .1
  done
  check "$scenario" pass "20 captures contain no marker; Core remains locked (recording still required for transient exposure)"
}

mapfile -t shell_pids < <(scope_pids ditto-shell.scope; scope_pids ditto-quickshell.scope)
if [[ ${#shell_pids[@]} -eq 0 ]]; then
  check shell-crash environment "no Shell PID to kill"
else
  kill -KILL "${shell_pids[@]}"
  assert_opaque shell-crash
fi

propose_locked() {
  local scenario="$1" ops="$2" profile base answer after
  profile="$(g1_call desktop.profiles.get '{}')"
  base="$(jq -r '.result.profile.head_revision' <<< "$profile")"
  answer="$(g1_call desktop.changes.propose "$(jq -cn --arg base "$base" --argjson ops "$ops" '{base_revision:$base,ops:$ops}')")"
  printf '%s\n' "$answer" > "$work/$scenario-proposal.json"
  after="$(g1_call desktop.profiles.get '{}')"
  if ! jq -e '.error.name == "preflight_rejected" and any(.error.data.reasons[]?; .detail.why == "session_locked")' <<< "$answer" >/dev/null \
    || [[ "$(jq -r '.result.profile.head_revision' <<< "$after")" != "$base" ]] \
    || [[ "$(jq -r '.result.revision.document_sha256' <<< "$after")" != "$(jq -r '.result.revision.document_sha256' <<< "$profile")" ]]; then
    check "$scenario" fail "proposal was not refused for session_locked, or profile changed"
  else
    assert_opaque "$scenario"
  fi
}
profile="$(g1_call desktop.profiles.get '{}')"
dock="$(jq -r '.result.document.slots["ui.dock"]' <<< "$profile")"
ops="$(jq -c --arg dock "$dock" '.result.document.entries[] | select(.entry_id == $dock)
  | (if .package == "ditto.dock.pill" then "ditto.dock.bottom" else "ditto.dock.pill" end) as $other
  | [{op:"add_entry",entry:{package:$other,version:"1.1.0",host:"qml"},slot:"ui.dock"},{op:"remove_entry",entry_id:$dock}]' <<< "$profile")"
propose_locked replace-ui "$ops"
# An explicit version-change attempt must be refused even if the target
# package has not been installed; it must include the lock rejection reason.
ops="$(jq -c --arg dock "$dock" '[.result.document.entries[] | select(.entry_id == $dock)
  | {op:"upgrade_entry",entry_id:$dock,from_version:.version,to_version:"99.0.0"}]' <<< "$profile")"
propose_locked plugin-update "$ops"
if timeout 15 systemctl --user start ditto-rescue.service; then
  if systemctl --user is-active --quiet ditto-rescue.service; then assert_opaque rescue
  else check rescue environment "rescue trigger returned but rescue unit is not active"; fi
else
  check rescue environment "could not start the actual rescue service"
fi
check password-unlock operator "以密碼解鎖並錄影；連續錄影亦須確認四個轉換期間沒有桌面內容"
g1_finish
