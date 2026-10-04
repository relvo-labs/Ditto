#!/usr/bin/env bash
# EX1-12 ④⑤: the session stays locked.
#   ④ locked, then SIGKILL the lock client and the Shell → the session stays
#     locked and shows no desktop content; typing the password unlocks.
#   ⑤ while locked, a ChangeSet replacing the Dock is rejected or deferred and
#     the lock surface does not change.
#
# The compositor half of ④ is matrix row C-19 (tools/compositor-probe/g1,
# headless development evidence). This runner checks Ditto's own lock client
# in a logged-in "Ditto (Wayfire)" session. Unlocking with the password and
# the one-off recording stay with the operator (plan/03/01 EX1-12).
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

WINDOW_PIDS=()
MARKER_PID=""
trap 'kill "$MARKER_PID" 2>/dev/null || true' EXIT INT TERM

g1_begin lock "EX1-12 ④⑤"
g1_preflight

# A fully green terminal: after locking, any green on screen is desktop content.
MARKER=00ff00

latest_c19="$(ls -t "$WORKSPACE"/artifacts/g1-dev/compositor-probe/c19-*.json 2>/dev/null | head -1 || true)"
if [[ -n "$latest_c19" ]]; then
  g1_note "compositor evidence for ④ (C-19, headless, development): $latest_c19"
fi

if ! in_ditto_session; then
  check lock-client-killed environment "④ needs a logged-in Ditto session with Core's lock client; C-19 covers the compositor alone"
  check lock-changeset-refused environment "⑤ needs a logged-in Ditto session"
  check lock-password-unlock operator "unlock with the password and record it once (EX1-12 ④)"
  g1_finish
fi

export DITTO_RUNTIME_DIR="${DITTO_RUNTIME_DIR:-$XDG_RUNTIME_DIR/ditto}"
listing="$(g1_capabilities)"
missing="$(missing_capabilities "$listing" desktop.session.lock desktop.session.state)"
command -v grim >/dev/null || { check lock-client-killed environment "grim is not installed"; g1_finish; }

session_state() {
  g1_call desktop.session.state '{}' | python3 -c '
import json, sys
record = json.load(sys.stdin)
state = record.get("result") or {}
print("locked" if state.get("locked") else "unlocked", "client" if state.get("lock_client_running") else "no-client")'
}

# ⑤: a ChangeSet replacing the Dock while locked. Preflight refuses it
# (`session_locked`); the head, its content hash and the lock surface stay.
propose_dock_swap_while_locked() {
  local profile before_head before_hash ops answer after after_hash surface_before surface_after evidence
  profile="$(g1_call desktop.profiles.get '{}')"
  before_head="$(jq -r .result.profile.head_revision <<<"$profile")"
  before_hash="$(jq -r .result.revision.document_sha256 <<<"$profile")"
  ops="$(jq -c '.result.document as $d | ($d.slots["ui.dock"]) as $dock
    | ([$d.entries[] | select(.entry_id == $dock) | .package][0]) as $current
    | (if $current == "ditto.dock.pill" then "ditto.dock.bottom" else "ditto.dock.pill" end) as $other
    | [{op: "add_entry", entry: {package: $other, version: "1.0.0", host: "qml"}, slot: "ui.dock"},
       {op: "remove_entry", entry_id: $dock}]' <<<"$profile")"
  surface_before="$(grim -t ppm - 2>/dev/null | sha256sum | cut -c1-16 || true)"
  answer="$(g1_call desktop.changes.propose "$(jq -cn --arg base "$before_head" --argjson ops "$ops" '{base_revision: $base, ops: $ops}')")"
  sleep 2
  surface_after="$(grim -t ppm - 2>/dev/null | sha256sum | cut -c1-16 || true)"
  after="$(g1_call desktop.profiles.get '{}')"
  after_hash="$(jq -r .result.revision.document_sha256 <<<"$after")"
  evidence="$(jq -cn --argjson answer "$answer" --arg before "$before_head" --arg after "$(jq -r .result.profile.head_revision <<<"$after")" \
    --arg hash_before "$before_hash" --arg hash_after "$after_hash" --arg surface_before "$surface_before" --arg surface_after "$surface_after" \
    '{answer: $answer, head: {before: $before, after: $after}, document_sha256: {before: $hash_before, after: $hash_after},
      lock_surface_sha256: {before: $surface_before, after: $surface_after}}')"
  if jq -e '.answer.error.name == "preflight_rejected"
      and ([.answer.error.data.reasons[]? | .detail.why] | index("session_locked")) != null
      and .head.before == .head.after and .document_sha256.before == .document_sha256.after' <<<"$evidence" >/dev/null; then
    if [[ -n "$surface_before" && "$surface_before" == "$surface_after" ]]; then
      check lock-changeset-refused pass "the Dock swap was refused before validation (session_locked); head, content hash and lock surface unchanged" "$evidence"
    elif [[ -z "$surface_before" ]]; then
      check lock-changeset-refused environment "refused as required, but no screenshot could be taken to compare the lock surface" "$evidence"
    else
      check lock-changeset-refused fail "refused, but the lock surface changed" "$evidence"
    fi
  else
    check lock-changeset-refused fail "the Dock swap was not refused for session_locked, or the profile moved" "$evidence"
  fi
  LOCK_CHANGESET_CHECKED=1
}
LOCK_CHANGESET_CHECKED=""

if [[ -n "$missing" ]]; then
  check lock-client-killed not_implemented "Core does not serve: $missing"
elif ! g1_can_call; then
  check lock-client-killed not_implemented "dittoctl has no 'probe call <capability> <json>' to request the lock"
else
  foot --app-id=ditto-g1-lock-marker -o "colors.background=$MARKER" -o "colors.foreground=$MARKER" \
    sh -c 'sleep infinity' >/dev/null 2>&1 &
  MARKER_PID=$!
  sleep 2
  shots="$ARTIFACTS/lock-$RUN_ID"
  before="$(screen_fraction "$MARKER" "$shots-before.png")"
  g1_call desktop.session.lock '{}' >/dev/null
  state=""
  for _ in $(seq 1 100); do
    state="$(session_state 2>/dev/null || true)"
    [[ "$state" == "locked client" ]] && break
    sleep 0.1
  done
  locked="$(screen_fraction "$MARKER" "$shots-locked.png")"
  # ⑤ while locked, before anything is killed: the Dock swap is refused and
  # the lock surface does not change.
  if [[ "$state" == "locked client" ]]; then
    propose_dock_swap_while_locked
  fi
  mapfile -t lock_pids < <(scope_pids ditto-lock.scope)
  mapfile -t shell_pids < <(scope_pids ditto-shell.scope; scope_pids ditto-quickshell.scope)
  killed=("${lock_pids[@]}" "${shell_pids[@]}")
  if [[ "$state" != "locked client" || ${#lock_pids[@]} -eq 0 ]]; then
    check lock-client-killed fail "the session did not reach 'locked' with a running lock client (state: ${state:-none}, ditto-lock.scope pids: ${#lock_pids[@]})"
  else
    kill -KILL "${killed[@]}" 2>/dev/null || true
    sleep 2
    after="$(screen_fraction "$MARKER" "$shots-after-kill.png")"
    after_state="$(session_state 2>/dev/null || echo unknown)"
    evidence="$(python3 -c 'import json, sys
before, locked, after, state, shots, *pids = sys.argv[1:]
print(json.dumps({"marker_fraction": {"before": before, "locked": locked, "after_kill": after},
                  "state_after_kill": state, "screenshots": shots + "-*.png",
                  "killed_pids": [int(p) for p in pids]}))' "$before" "$locked" "$after" "$after_state" "$shots" "${killed[@]}")"
    if [[ "$before" == error* || "$after" == error* ]]; then
      # grim may be refused while locked; that is not proof either way.
      check lock-client-killed environment "no screenshot could be taken, so desktop exposure is undetermined" "$evidence"
    elif python3 -c "import sys; sys.exit(0 if float('$before') > 0.01 and float('$after') == 0 and float('$locked') == 0 else 1)" &&
      [[ "$after_state" == locked* ]]; then
      check lock-client-killed pass "no desktop pixel visible after SIGKILL of lock client and Shell; still locked" "$evidence"
    else
      check lock-client-killed fail "desktop content visible or session unlocked after the kill (G1-R6)" "$evidence"
    fi
  fi
fi

if [[ -z "$LOCK_CHANGESET_CHECKED" ]]; then
  check lock-changeset-refused fail "the session never reached 'locked', so ⑤ could not be tried"
fi

check lock-password-unlock operator "unlock with the password and record it once (EX1-12 ④)"
g1_finish
