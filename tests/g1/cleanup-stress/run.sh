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
# (Mann-Kendall p ≥ 0.05). ① runs against the real Shell in a headless
# desktop (its PSS judged); ② and ③ run each against its own Core and hostd (hostd started with
# the same Node flags as the systemd unit); ③ uses the realm_cycle fixture
# (packages/plugin-fixtures/stress/realm_cycle), see driver.mjs.
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
realm_fixture="$WORKSPACE/packages/plugin-fixtures/stress/realm_cycle"

# stress_group <check-id> <criterion> <packages dir | realm>: one fresh Core
# and hostd, the driver repeating <check-id>'s cycle, judge.py on its
# snapshots. `realm` adds the packed realm_cycle fixture to the built-ins.
stress_group() {
  local id="$1" criterion="$2" builtin="$3" work judged status detail
  FIXTURE_ROOT="$(mktemp -d /tmp/ditto-g1.XXXXXX)"
  work="$FIXTURE_ROOT/work"
  mkdir -p "$work"
  if [[ "$builtin" == realm ]]; then
    builtin="$FIXTURE_ROOT/packages"
    mkdir -p "$builtin"
    cp "$packages"/*.dittopkg "$builtin/"
    if ! (cd "$WORKSPACE/packages/plugin-fixtures" && "$node" ../host-sdk/scripts/pack-each.mjs "$realm_fixture" --out "$builtin") >"$evidence/pack-$id.log" 2>&1; then
      check "$id" fail "$criterion: packing the realm_cycle fixture failed" "{\"log\": \"$evidence/pack-$id.log\"}"
      g1_fixture_stop
      return
    fi
  fi
  export DITTO_RUNTIME_DIR="$FIXTURE_ROOT/run" DITTO_DATA_DIR="$FIXTURE_ROOT/store" DITTO_SYSTEM=none WAYFIRE_SOCKET='' SWAYSOCK=''
  unset DITTO_DEV_TOKEN
  "$BINARIES/ditto-core" serve --compositor fixture --builtin-packages "$builtin" \
    --hostd "$(g1_hostd_spec "$node" "$hostd")" \
    --launch "dittoctl 0.2.0 $node $WORKSPACE/tests/g1/cleanup-stress/driver.mjs $work $id $cycles $warmup" \
    >"$FIXTURE_ROOT/core.log" 2>&1 &
  CORE_PID=$!
  for _ in $(seq 1 $((cycles * 20 + 600))); do
    [[ -f "$work/result.json" ]] && break
    kill -0 "$CORE_PID" 2>/dev/null || break
    sleep 0.1
  done
  cp "$FIXTURE_ROOT/core.log" "$evidence/core-$id.log"
  cp "$work/result.json" "$evidence/$id.json" 2>/dev/null || echo '{"ok":false,"error":"the driver wrote no result"}' >"$evidence/$id.json"
  judged="$(python3 "$WORKSPACE/tests/g1/cleanup-stress/judge.py" "$evidence/$id.json")"
  status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$judged")"
  detail="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["detail"])' "$judged")"
  check "$id" "$status" "$criterion: $detail" \
    "$(python3 -c 'import json,sys; e=json.loads(sys.argv[1]).get("evidence") or {}; e["snapshots"]=sys.argv[2]; print(json.dumps(e))' "$judged" "$evidence/$id.json")"
  g1_fixture_stop
}

if [[ -z "$node" || ! -f "$hostd" || ! -f "$packages/ditto.svc.tasks-1.0.0.dittopkg" ]]; then
  needs="needs node, $hostd (pnpm --filter @ditto/host-runtime build) and $packages (scripts/build-builtin-packages.sh)"
  check tasks-toggle fail "$needs"
  check realm-cycle fail "$needs"
else
  node="$(readlink -f "$node")"
  stress_group tasks-toggle "② tasks service disabled/enabled" "$packages"
  if [[ -f "$realm_fixture/dist/index.mjs" ]]; then
    stress_group realm-cycle "③ realm_cycle candidate mounted in an isolate realm and taken down" realm
  else
    check realm-cycle fail "③ needs $realm_fixture/dist (pnpm --filter @ditto/plugin-fixtures build)"
  fi
fi

# ① against the real Shell, in a headless desktop of its own (Wayfire, Core
# in normal mode supervising the Shell, the verification relay). The judge is
# the same, on the Shell's PSS and PID: counts identical first→last, Shell
# PSS median growth ≤10 %, no monotonic trend.
dock_swap() {
  (
    source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
    WINDOW_PIDS=()
    trap shell_fixture_stop EXIT
    start_compositor >/dev/null
    if ! shell_fixture_start; then
      cp "$RUNTIME_DIR/core.log" "$evidence/core-dock-swap.log" 2>/dev/null || true
      echo '{"ok": false, "error": "the desktop fixture did not come up"}' >"$evidence/dock-swap.json"
      exit 0
    fi
    python3 "$WORKSPACE/tests/g1/cleanup-stress/dock_cycle.py" "$evidence/dock-swap.json" "$cycles" "$warmup"
    cp "$RUNTIME_DIR/core.log" "$evidence/core-dock-swap.log" 2>/dev/null || true
  )
  local judged
  judged="$(python3 "$WORKSPACE/tests/g1/cleanup-stress/judge.py" "$evidence/dock-swap.json" --process shell)"
  check dock-swap "$(jq -r .status <<<"$judged")" \
    "① Dock A/B re-bound against the real Shell (Shell PSS judged): $(jq -r .detail <<<"$judged")" \
    "$(jq -c --arg snapshots "$evidence/dock-swap.json" '(.evidence // {}) + {snapshots: $snapshots}' <<<"$judged")"
}
dock_swap

g1_finish
