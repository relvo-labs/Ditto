#!/usr/bin/env bash
# EX1-04: cleanup under stress leaves nothing behind. After warm-up, three
# groups of 100:
#   ① Dock A/B swapped back and forth;
#   ② the tasks service plugin disabled and enabled;
#   ③ one isolate realm mounted and unmounted (L-04).
# Every 10 cycles a snapshot of Core's bindings, leases and subscriptions,
# hostd's fibers, effects and registrations, and the Shell's mounted
# providers. First and last counts must be identical; hostd and Shell PSS
# medians may grow ≤10%, with no monotonic trend at the ten points
# (Mann-Kendall p ≥ 0.05). Shell PSS and ① need a Shell; ③ needs the realm
# fixture from HOST. In this fixture ② runs for real.
#
#   DITTO_STRESS_CYCLES (default 100), DITTO_STRESS_WARMUP (default 10)
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap g1_fixture_stop EXIT INT TERM

g1_begin cleanup-stress "EX1-04 ①②③"
g1_preflight
evidence="$(g1_evidence_dir)"
cycles="${DITTO_STRESS_CYCLES:-100}"
warmup="${DITTO_STRESS_WARMUP:-10}"
[[ "$cycles" == 100 ]] || g1_note "DITTO_STRESS_CYCLES=$cycles: not the 100 the gate asks for"

node="$(command -v node || true)"
hostd="$WORKSPACE/packages/host-runtime/dist/ditto-hostd.mjs"
packages="${DITTO_BUILTIN_PACKAGES:-$WORKSPACE/target/ditto-packages}"
if [[ -z "$node" || ! -f "$hostd" || ! -f "$packages/ditto.svc.tasks-1.0.0.dittopkg" ]]; then
  check tasks-toggle fail "needs node, $hostd (pnpm --filter @ditto/host-runtime build) and $packages (scripts/build-builtin-packages.sh)"
else
  node="$(readlink -f "$node")"
  FIXTURE_ROOT="$(mktemp -d /tmp/ditto-g1.XXXXXX)"
  work="$FIXTURE_ROOT/work"
  mkdir -p "$work"
  export DITTO_RUNTIME_DIR="$FIXTURE_ROOT/run" DITTO_DATA_DIR="$FIXTURE_ROOT/store" DITTO_SYSTEM=none WAYFIRE_SOCKET='' SWAYSOCK=''
  unset DITTO_DEV_TOKEN
  "$BINARIES/ditto-core" serve --compositor fixture --builtin-packages "$packages" \
    --hostd "hostd 0.2.0 $node $hostd" \
    --launch "dittoctl 0.2.0 $node $WORKSPACE/tests/g1/cleanup-stress/driver.mjs $work tasks-toggle $cycles $warmup" \
    >"$FIXTURE_ROOT/core.log" 2>&1 &
  CORE_PID=$!
  for _ in $(seq 1 $((cycles * 20 + 600))); do
    [[ -f "$work/result.json" ]] && break
    kill -0 "$CORE_PID" 2>/dev/null || break
    sleep 0.1
  done
  cp "$FIXTURE_ROOT/core.log" "$evidence/core-tasks-toggle.log"
  cp "$work/result.json" "$evidence/tasks-toggle.json" 2>/dev/null || echo '{"ok":false,"error":"the driver wrote no result"}' >"$evidence/tasks-toggle.json"
  judged="$(python3 "$WORKSPACE/tests/g1/cleanup-stress/judge.py" "$evidence/tasks-toggle.json")"
  status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$judged")"
  detail="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["detail"])' "$judged")"
  check tasks-toggle "$status" "② tasks service disabled/enabled: $detail" \
    "$(python3 -c 'import json,sys; e=json.loads(sys.argv[1]).get("evidence") or {}; e["snapshots"]=sys.argv[2]; print(json.dumps(e))' "$judged" "$evidence/tasks-toggle.json")"
  g1_fixture_stop
fi

check dock-swap environment "① Dock A/B swaps need a Shell participant and its mounted-provider count (logged-in Ditto session)"
check shell-pss environment "Shell PSS needs a running Shell (logged-in Ditto session)"
if [[ -d "$WORKSPACE/packages/plugin-fixtures/realm-cycle" ]]; then
  check realm-cycle not_implemented "the realm fixture exists but this runner does not drive it yet"
else
  check realm-cycle not_implemented "③ needs a fixture plugin that mounts and unmounts one isolate realm (HOST, L-04)"
fi

g1_finish
