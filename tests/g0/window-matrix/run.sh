#!/usr/bin/env bash
# EX-01: every capability x reference-application cell must end with either a
# readback-verified success or an explicit `unsupported`. A success whose
# readback disagrees is a failure, and so is a silent success.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

RUN_ID="$(run_id)"
OUTPUT="$ARTIFACTS/window-matrix-$RUN_ID.jsonl"
mkdir -p "$ARTIFACTS"
: >"$OUTPUT"

start_compositor
start_core

# The reference application set is frozen per platform (plan/02/02 §2.1). The
# development container only has a terminal, so a run here covers one role.
APPS="${DITTO_MATRIX_APPS:-foot}"
declare -a TARGETS=()
index=0
for app in $APPS; do
  index=$((index + 1))
  start_window "ditto-matrix-$index"
  TARGETS+=("ditto-matrix-$index")
done

probe() {
  "$BINARIES/dittoctl" --json "$@" 2>>"$RUNTIME_DIR/dittoctl.log" || true
}

record() {
  local role="$1" app_id="$2"
  shift 2
  probe "$@" | jq -c --arg run "$RUN_ID" --arg role "$role" --arg app "$app_id" \
    --arg env "$(environment_label)" --arg compositor "$(sway --version)" \
    '. + {run_id: $run, role: $role, app_id: $app, environment: $env, compositor: $compositor}' >>"$OUTPUT"
}

record fixture-free - probe capabilities
record fixture-free - probe outputs
record fixture-free - probe workspaces
record fixture-free - probe windows

for app_id in "${TARGETS[@]}"; do
  window="$(window_id_for "$app_id")"
  record terminal "$app_id" probe window "$window"
  record terminal "$app_id" probe window "$window" --focus
  record terminal "$app_id" probe window "$window" --move 120 140
  record terminal "$app_id" probe window "$window" --resize 640 480
  record terminal "$app_id" probe window "$window" --state fullscreen
  record terminal "$app_id" probe window "$window" --state normal
done

# A floating window is the only shape a wlroots compositor gives coordinates to;
# both shapes are recorded so the gap shows up as a matrix cell, not as a note.
floating="${TARGETS[0]}"
swaymsg "[app_id=$floating] floating enable" >/dev/null
floating_window="$(window_id_for "$floating")"
record terminal-floating "$floating" probe window "$floating_window" --move 120 140
record terminal-floating "$floating" probe window "$floating_window" --resize 640 480

workspace="$(swaymsg --raw --type get_workspaces | jq -r 'first(.[] | select(.focused == false) | .name) // first(.[] | .name)')"
record fixture-free - probe workspaces --activate "$workspace"
record fixture-free - probe workspaces --get "$workspace"

last="$(window_id_for "${TARGETS[0]}")"
record terminal "${TARGETS[0]}" probe window "$last" --close

python3 "$(cd "$(dirname "$0")" && pwd)/classify.py" "$OUTPUT"
echo "matrix written to $OUTPUT"
