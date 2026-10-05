#!/usr/bin/env bash
# EX1-05 ④, the Shell half: a Core in `--mode rescue` with the real Shell and
# no hostd, in its own headless desktop. Prints one JSON object: what the
# tasks panel and the notification area show (the Shell's read-only
# `services` control line) once both report their service as unavailable,
# and Core's own rescue status. run.sh judges it.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"

WINDOW_PIDS=()
trap shell_fixture_stop EXIT INT TERM

start_compositor >/dev/null
if ! shell_fixture_start --mode rescue; then
  jq -cn --arg log "$(tail -20 "$RUNTIME_DIR/core.log" 2>/dev/null)" '{error: "the rescue-mode desktop did not come up", core_log_tail: $log}'
  exit 0
fi

services='{}'
for _ in $(seq 1 100); do
  services="$(shell_line services 2>/dev/null || echo '{}')"
  if jq -e '.tasks.unavailable == true and .notification_policy.unavailable == true and (.tasks.text | length) > 0' <<<"$services" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
status="$(relay desktop.rescue.status '{}' | jq -c '.result | {mode, unavailable: [.unavailable[]? | .capability_id]}' 2>/dev/null || echo null)"
# The verification relay is Node by design; anything else would be Ditto's.
node_children="$(pgrep -P "$CORE_PID" -a 2>/dev/null | grep node | grep -vc 'tests/g1/lib/relay.mjs' || true)"
jq -cn --argjson services "$services" --argjson status "$status" --arg node "$node_children" \
  '{services: $services, rescue_status: $status, node_children_of_core_besides_the_relay: ($node | tonumber)}'
