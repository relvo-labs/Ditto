#!/usr/bin/env bash
# EX-01: every capability x reference-application cell must end with either a
# readback-verified success or an explicit `unsupported`. A success whose
# readback disagrees is a failure, and so is a silent success.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"
source "$(cd "$(dirname "$0")/.." && pwd)/lib/reference-apps.sh"

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

RUN_ID="$(run_id)"
OUTPUT="$ARTIFACTS/window-matrix-$RUN_ID.jsonl"
mkdir -p "$ARTIFACTS"
: >"$OUTPUT"

start_compositor
start_core

# Reference evidence always covers the frozen browser, terminal and editor.
# A development run intentionally uses one terminal fixture and is labelled as
# such; DITTO_MATRIX_APPS can no longer turn that fixture into reference data.
declare -a TARGETS=() ROLES=()
if [[ -n "${DITTO_REFERENCE_MACHINE:-}" ]]; then
  start_all_reference_apps
  TARGETS=("${REFERENCE_APP_IDS[@]}")
  ROLES=("${REFERENCE_APP_ROLES[@]}")
else
  start_window ditto-matrix-terminal
  TARGETS=(ditto-matrix-terminal)
  ROLES=(terminal-fixture)
fi

probe() {
  "$BINARIES/dittoctl" --json "$@" 2>>"$RUNTIME_DIR/dittoctl.log" || true
}

record() {
  local role="$1" app_id="$2" cell
  shift 2
  cell="$(probe "$@")"
  # A probe that printed nothing never reached a Core answer. It is recorded as
  # a cell of its own so the classifier fails it instead of the run shrinking.
  if [[ -z "$cell" ]]; then
    cell="$(jq -cn --arg request "$*" --arg message "$(tail -1 "$RUNTIME_DIR/dittoctl.log" 2>/dev/null)" \
      '{capability: ("no response: " + $request), ok: false, readback_verified: false,
        error: {name: "no_response", message: $message}}')"
  fi
  jq -c --arg run "$RUN_ID" --arg role "$role" --arg app "$app_id" \
    --arg env "$(environment_label)" --arg compositor "$(compositor_label)" \
    '. + {run_id: $run, role: $role, app_id: $app, environment: $env, compositor: $compositor}' \
    <<<"$cell" >>"$OUTPUT"
}

record fixture-free - probe capabilities
record fixture-free - probe outputs
record fixture-free - probe workspaces
record fixture-free - probe windows

for index in "${!TARGETS[@]}"; do
  app_id="${TARGETS[$index]}"
  role="${ROLES[$index]}"
  window="$(window_id_for "$app_id")"
  record "$role" "$app_id" probe window "$window"
  record "$role" "$app_id" probe window "$window" --focus
  record "$role" "$app_id" probe window "$window" --move 120 140
  record "$role" "$app_id" probe window "$window" --resize 640 480
  record "$role" "$app_id" probe window "$window" --state fullscreen
  record "$role" "$app_id" probe window "$window" --state normal
  # All four states are asked for, not only the two every compositor has. A
  # compositor without a maximize or minimize state answers `unsupported`, and
  # that answer is the matrix cell; leaving the request out would hide the
  # difference between the compositors instead of recording it.
  record "$role" "$app_id" probe window "$window" --state maximized
  record "$role" "$app_id" probe window "$window" --state normal
  record "$role" "$app_id" probe window "$window" --state minimized
  record "$role" "$app_id" probe window "$window" --state normal
done

# An untiled window is the only shape a wlroots compositor gives coordinates to;
# both shapes are recorded so the gap shows up as a matrix cell, not as a note.
floating="${TARGETS[0]}"
compositor_make_floating "$floating"
floating_window="$(window_id_for "$floating")"
record "${ROLES[0]}-floating" "$floating" probe window "$floating_window" --move 120 140
record "${ROLES[0]}-floating" "$floating" probe window "$floating_window" --resize 640 480

# The workspace to switch to is chosen from what Core reports, not from the
# compositor's own listing: the id has to be one the capability accepts, and its
# shape differs per compositor.
workspace="$(probe probe workspaces | jq -r 'first(.result.workspaces[] | select(.active | not) | .id) // first(.result.workspaces[] | .id)')"
record fixture-free - probe workspaces --activate "$workspace"
record fixture-free - probe workspaces --get "$workspace"

for index in "${!TARGETS[@]}"; do
  last="$(window_id_for "${TARGETS[$index]}")"
  record "${ROLES[$index]}" "${TARGETS[$index]}" probe window "$last" --close
done

python3 "$(cd "$(dirname "$0")" && pwd)/classify.py" "$OUTPUT"
echo "matrix written to $OUTPUT"
