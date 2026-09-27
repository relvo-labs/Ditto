#!/usr/bin/env bash
# EX1-07: Cordis services outlive every client.
# With the tasks and notification-policy services enabled:
#   ① SIGKILL the Agent stand-in → a tasks file change still reaches the
#     panel within 2 s; the notification policy still suppresses by its rules;
#   ② SIGKILL the Shell → the restarted Shell gets the latest tasks state from
#     its snapshot, and policy decisions made meanwhile are recorded;
#   ③ hostd's PID is the same through ① and ②.
#
# The fixture here is Core (fixture compositor, own store) with the real hostd,
# the Agent stand-in and an observer driver, all started by Core's launcher.
# The "panel" in ① is a subscriber reading desktop.tasks.list — the same
# capability the QML panel reads — so ① here is development evidence of the
# service path, not of the panel. The notification half of ① and all of ②
# need a session (notifications through ditto-system, a Shell to kill) and
# are recorded as environment until the logged-in variant exists.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap g1_fixture_stop EXIT INT TERM

g1_begin cordis-independent "EX1-07 ①②③"
g1_preflight
evidence="$(g1_evidence_dir)"

node="$(command -v node || true)"
hostd="$WORKSPACE/packages/host-runtime/dist/ditto-hostd.mjs"
packages="${DITTO_BUILTIN_PACKAGES:-$WORKSPACE/target/ditto-packages}"
if [[ -z "$node" ]]; then
  check standin-killed environment "node is not on PATH"
  g1_finish
fi
node="$(readlink -f "$node")"
missing=()
[[ -f "$hostd" ]] || missing+=("$hostd (pnpm --filter @ditto/host-runtime build)")
[[ -f "$packages/ditto.svc.tasks-1.0.0.dittopkg" ]] || missing+=("$packages/ditto.svc.tasks-1.0.0.dittopkg (scripts/build-builtin-packages.sh)")
if [[ ${#missing[@]} -gt 0 ]]; then
  check standin-killed fail "build first: ${missing[*]}"
  g1_finish
fi

FIXTURE_ROOT="$(mktemp -d /tmp/ditto-g1.XXXXXX)"
work="$FIXTURE_ROOT/work"
mkdir -p "$work"
export DITTO_RUNTIME_DIR="$FIXTURE_ROOT/run" DITTO_DATA_DIR="$FIXTURE_ROOT/store" DITTO_SYSTEM=none WAYFIRE_SOCKET='' SWAYSOCK=''
unset DITTO_DEV_TOKEN
"$BINARIES/ditto-core" serve --compositor fixture --builtin-packages "$packages" \
  --hostd "hostd 0.2.0 $node $hostd" \
  --launch "agent 0.2.0 $node $WORKSPACE/tests/g1/fixtures/agent-standin/standin.mjs hold" \
  --launch "dittoctl 0.2.0 $node $WORKSPACE/tests/g1/cordis-independent/driver.mjs $work" \
  >"$FIXTURE_ROOT/core.log" 2>&1 &
CORE_PID=$!

wait_for() {
  local path="$1" seconds="$2" _
  for _ in $(seq 1 $((seconds * 10))); do
    [[ -e "$path" ]] && return 0
    kill -0 "$CORE_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}
descendant() {
  # The newest process under Core whose command line has this text.
  local pattern="$1" pid
  for pid in $(pgrep -f -- "$pattern" || true); do
    [[ "$(ps -o ppid= -p "$pid" | tr -d ' ')" == "$CORE_PID" ]] && { echo "$pid"; return 0; }
  done
  return 0
}

if ! wait_for "$work/ready.json" 45; then
  cp "$FIXTURE_ROOT/core.log" "$evidence/core.log"
  reason="setup did not finish"
  [[ -f "$work/result.json" ]] && reason="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("error"))' "$work/result.json")"
  check standin-killed fail "fixture setup: $reason (core.log saved)" "{\"log\": \"$evidence/core.log\"}"
  check hostd-pid-stable fail "not reached"
  g1_finish
fi

standin="$(descendant agent-standin/standin.mjs)"
hostd_before="$(descendant ditto-hostd.mjs)"
if [[ -z "$standin" || -z "$hostd_before" ]]; then
  cp "$FIXTURE_ROOT/core.log" "$evidence/core.log"
  check standin-killed fail "could not find the stand-in ($standin) or hostd ($hostd_before) under Core"
  g1_finish
fi
kill -KILL "$standin"
touch "$work/killed"
wait_for "$work/result.json" 20 || true
hostd_after="$(descendant ditto-hostd.mjs)"
cp "$FIXTURE_ROOT/core.log" "$evidence/core.log"
cp "$work/result.json" "$evidence/result.json" 2>/dev/null || echo '{"ok":false,"error":"no result"}' >"$evidence/result.json"

verdict="$(python3 - "$evidence/result.json" <<'PYEOF'
import json, sys
result = json.load(open(sys.argv[1]))
if not result.get("ok"):
    print("fail", result.get("error")); raise SystemExit
latency = result.get("event_latency_ms")
problems = []
if latency is None:
    problems.append("no tasks event showed the new line within 5 s")
elif latency > 2000:
    problems.append(f"the event took {latency} ms (> 2000)")
if not result.get("tasks_available_after_kill"):
    problems.append("desktop.tasks.list became unavailable")
if not result.get("listed_after_kill"):
    problems.append("desktop.tasks.list does not list the new line")
print("fail" if problems else "pass", "; ".join(problems) or f"tasks event {latency} ms after the external write; still available and listed")
PYEOF
)"
check standin-killed "${verdict%% *}" "① after SIGKILL of the Agent stand-in: ${verdict#* }" "{\"result\": \"$evidence/result.json\", \"standin_pid\": $standin}"
check notification-policy environment "① notification suppression needs notifications through ditto-system (DITTO_SYSTEM=none in this fixture)"
check shell-killed environment "② needs a Shell to kill and restart (logged-in Ditto session)"
if [[ -n "$hostd_after" && "$hostd_before" == "$hostd_after" ]]; then
  check hostd-pid-stable pass "③ hostd PID $hostd_before before and after ①" "{\"before\": $hostd_before, \"after\": $hostd_after}"
else
  check hostd-pid-stable fail "③ hostd PID changed: $hostd_before → ${hostd_after:-gone}"
fi
g1_note "① and ③ here cover the stand-in kill only; ③ over ② needs the session variant"
g1_fixture_stop

g1_finish
