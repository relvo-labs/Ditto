#!/usr/bin/env bash
# EX1-11: local operations, plugin switches and application survival.
#   ① NFR-03: a simple local operation (switch workspace, focus a window,
#     change one appearance token), accepted → read back, p95 ≤100 ms, 200×;
#   ② NFR-04: an installed UI plugin switch (Dock A↔B), prepared → committed,
#     p95 ≤2 s, 100×; the Cordis service replacement listed separately;
#   ③ NFR-09: during those 300 operations no reference application ends
#     unexpectedly and Kate's unsaved buffer hash is unchanged.
#
# Two fixtures, both started by this script:
#   - the Cordis service number of ② (listed separately): Core on the fixture
#     compositor with the real hostd; enable and disable of the tasks service,
#     100 each, prepared → committed from Core's change_updated stamps;
#   - ①②③: headless Wayfire with the real Shell, hostd and the reference
#     applications (tests/g1/lib/shell-fixture.sh). A driver Core launched
#     (driver.mjs `session`) runs the operations once run.sh has the
#     applications up and Kate's unsaved buffer hashed.
# What each number is, exactly:
#   ① workspace and focus: one call that Core reads back from the compositor
#     before answering; the time is `_meta.handled_us`, Core's monotonic clock
#     from reading the request to the verified result. Appearance token: a
#     ChangeSet; from its `created_at` (acceptance) to the `ended_at` of its
#     last readback operation, both written by Core (millisecond stamps).
#     Five warm-up operations per kind are kept but not judged (warm state).
#   ② `updated_at` of the `prepared` and `committed` change_updated events.
#   ③ the PIDs the compositor mapped for the reference windows, checked every
#     half second while the driver runs and at the end; Kate's buffer hash
#     before and after (tests/g0/lib/reference-apps.sh).
# The driver's round trip is recorded beside each sample and never judged.
# Samples go to artifacts/g1/latency-<run_id>.jsonl.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
WINDOW_PIDS=()
trap 'g1_fixture_stop; shell_fixture_stop' EXIT INT TERM

g1_begin latency "EX1-11 ①②③"
g1_preflight
evidence="$(g1_evidence_dir)"
samples="$ARTIFACTS/latency-$RUN_ID.jsonl"
count="${DITTO_LATENCY_COUNT:-100}"
[[ "$count" == 100 ]] || g1_note "DITTO_LATENCY_COUNT=$count: not the 100 the gate asks for"

node="$(command -v node || true)"
hostd="$WORKSPACE/packages/host-runtime/dist/ditto-hostd.mjs"
packages="${DITTO_BUILTIN_PACKAGES:-$WORKSPACE/target/ditto-packages}"
if [[ -z "$node" || ! -f "$hostd" || ! -f "$packages/ditto.svc.tasks-1.0.0.dittopkg" ]]; then
  check cordis-service-switch fail "needs node, $hostd and $packages (scripts/build-builtin-packages.sh)"
else
  node="$(readlink -f "$node")"
  FIXTURE_ROOT="$(mktemp -d /tmp/ditto-g1.XXXXXX)"
  work="$FIXTURE_ROOT/work"
  mkdir -p "$work"
  export DITTO_RUNTIME_DIR="$FIXTURE_ROOT/run" DITTO_DATA_DIR="$FIXTURE_ROOT/store" DITTO_SYSTEM=none WAYFIRE_SOCKET='' SWAYSOCK=''
  unset DITTO_DEV_TOKEN
  "$BINARIES/ditto-core" serve --compositor fixture --builtin-packages "$packages" \
    --hostd "$(g1_hostd_spec "$node" "$hostd")" \
    --launch "dittoctl 0.2.0 $node $WORKSPACE/tests/g1/latency/driver.mjs $work service-toggle $count" \
    >"$FIXTURE_ROOT/core.log" 2>&1 &
  CORE_PID=$!
  for _ in $(seq 1 $((count * 20 + 600))); do
    [[ -f "$work/done.json" ]] && break
    kill -0 "$CORE_PID" 2>/dev/null || break
    sleep 0.1
  done
  cp "$FIXTURE_ROOT/core.log" "$evidence/core.log"
  cp "$work/samples.jsonl" "$samples" 2>/dev/null || : >"$samples"
  judged="$(python3 - "$samples" "$work/done.json" <<'PYEOF'
import json, math, sys
try:
    done = json.load(open(sys.argv[2]))
except (OSError, ValueError):
    done = {"ok": False, "error": "the driver wrote no result"}
samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
def p95(values):
    values = sorted(values)
    return values[max(0, math.ceil(0.95 * len(values)) - 1)] if values else None
report = {}
for action in ("enable", "disable"):
    values = [s["prepared_to_committed_ms"] for s in samples if s["action"] == action and s["prepared_to_committed_ms"] is not None]
    report[action] = {"n": len(values), "p95_ms": p95(values), "max_ms": max(values) if values else None}
not_committed = [s["change_id"] for s in samples if s["state"] != "committed"]
problems = []
if not done.get("ok"):
    problems.append(done.get("error"))
if not_committed:
    problems.append(f"{len(not_committed)} changes did not commit")
for action, figures in report.items():
    if figures["p95_ms"] is None:
        problems.append(f"no {action} sample has both stamps")
    elif figures["p95_ms"] > 2000:
        problems.append(f"{action} p95 {figures['p95_ms']} ms > 2000")
status = "fail" if problems else "pass"
detail = "; ".join(problems) or "prepared→committed p95: enable {} ms, disable {} ms (n={}/{})".format(
    report["enable"]["p95_ms"], report["disable"]["p95_ms"], report["enable"]["n"], report["disable"]["n"])
print(json.dumps({"status": status, "detail": detail, "evidence": report}))
PYEOF
)"
  check cordis-service-switch "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$judged")" \
    "② (listed separately) Cordis service, Core stamps: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["detail"])' "$judged")" \
    "$(python3 -c 'import json,sys; e=json.loads(sys.argv[1]); e["samples"]=sys.argv[2]; print(json.dumps(e))' "$judged" "$samples")"
  g1_fixture_stop
fi

# ---- ①②③ in the headless desktop ----------------------------------------------
local_count="${DITTO_LATENCY_LOCAL_COUNT:-200}"
[[ "$local_count" == 200 ]] || g1_note "DITTO_LATENCY_LOCAL_COUNT=$local_count: not the 200 the gate asks for"
missing=()
for tool in quickshell node wl-copy wl-paste qdbus foot kate; do command -v "$tool" >/dev/null || missing+=("$tool"); done
[[ -f "$packages/ditto.dock.pill-1.0.0.dittopkg" ]] || missing+=("$packages/ditto.dock.pill-1.0.0.dittopkg")
[[ -f "$hostd" ]] || missing+=("$hostd")
if (( ${#missing[@]} > 0 )); then
  for id in local-operations ui-plugin-switch application-survival; do check "$id" environment "missing: ${missing[*]}"; done
  g1_note "per-change samples: $samples"
  g1_finish
fi

start_compositor
NODE="$(readlink -f "$(command -v node)")"
session_work="$RUNTIME_DIR/latency-work"
mkdir -p "$session_work"
if ! shell_fixture_start --hostd \
  --launch "dittoctl 0.2.0 $NODE $WORKSPACE/tests/g1/latency/driver.mjs $session_work session $local_count $count"; then
  cp "$RUNTIME_DIR/core.log" "$evidence/session-core.log" 2>/dev/null || true
  for id in local-operations ui-plugin-switch application-survival; do
    check "$id" fail "the desktop fixture did not come up (Core, Shell, hostd, relay); log in $evidence/session-core.log"
  done
  g1_finish
fi

fixture_reference_apps
kate_open_unsaved "Ditto EX1-11 未儲存緩衝 $RUN_ID"
sleep 1
kate_before="$(kate_unsaved_hash)"
mapped_before=()
for app_id in "${REFERENCE_APP_IDS[@]}"; do mapped_before+=("$(compositor_window_pid "$app_id")"); done

touch "$session_work/go"
deaths=()
for _ in $(seq 1 $(( (local_count + count) * 20 + 1200 ))); do
  [[ -f "$session_work/done.json" ]] && break
  kill -0 "$CORE_PID" 2>/dev/null || break
  for i in "${!REFERENCE_APP_PIDS[@]}"; do
    kill -0 "${REFERENCE_APP_PIDS[$i]}" 2>/dev/null || deaths+=("${REFERENCE_APP_IDS[$i]} (pid ${REFERENCE_APP_PIDS[$i]}) gone at $(date -u +%H:%M:%S.%N)")
  done
  sleep 0.5
done
cp "$RUNTIME_DIR/core.log" "$evidence/session-core.log" 2>/dev/null || true
[[ -f "$session_work/samples.jsonl" ]] && cat "$session_work/samples.jsonl" >>"$samples"
[[ -f "$session_work/done.json" ]] || echo '{"ok": false, "error": "the session driver did not finish (see session-core.log)"}' >"$session_work/done.json"

judged="$(python3 "$WORKSPACE/tests/g1/latency/judge.py" "$session_work/samples.jsonl" "$session_work/done.json" "$local_count" "$count")"
field() { python3 -c 'import json,sys; v=json.loads(sys.argv[1])
for k in sys.argv[2:]: v=v[k]
print(v if isinstance(v, str) else json.dumps(v))' "$judged" "$@"; }
with_samples() { python3 -c 'import json,sys; e=json.loads(sys.argv[1]); e["samples"]=sys.argv[2]; print(json.dumps(e))' "$1" "$samples"; }
check local-operations "$(field local status)" "① NFR-03, Core's clock: $(field local detail)" "$(with_samples "$(field local evidence)")"
check ui-plugin-switch "$(field dock status)" "② NFR-04 Dock A↔B with the real Shell, Core stamps: $(field dock detail)" "$(with_samples "$(field dock evidence)")"

kate_after="$(kate_unsaved_hash)"
mapped_after=()
for app_id in "${REFERENCE_APP_IDS[@]}"; do mapped_after+=("$(compositor_window_pid "$app_id")"); done
survival=()
(( ${#deaths[@]} == 0 )) || survival+=("terminated: ${deaths[0]}")
apps_alive || survival+=("a reference application is not running at the end")
[[ "${mapped_before[*]}" == "${mapped_after[*]}" ]] || survival+=("mapped PIDs changed: ${mapped_before[*]} → ${mapped_after[*]}")
[[ -n "$kate_before" && "$kate_before" == "$kate_after" ]] || survival+=("Kate's unsaved buffer hash changed or could not be read ($kate_before → $kate_after)")
operations="$(field operations)"
evidence_survival="$(python3 -c 'import json,sys; print(json.dumps({"apps": sys.argv[1].split(), "pids": sys.argv[2].split(), "kate_sha256": sys.argv[3], "operations": int(sys.argv[4])}))' \
  "${REFERENCE_APP_IDS[*]}" "${mapped_after[*]}" "$kate_after" "$operations")"
if (( ${#survival[@]} == 0 )); then
  check application-survival pass "③ NFR-09: over $operations operations ${REFERENCE_APP_IDS[*]} kept their PIDs and Kate's unsaved buffer hash is unchanged" "$evidence_survival"
else
  check application-survival fail "③ NFR-09: ${survival[*]}" "$evidence_survival"
fi
g1_note "per-change samples: $samples"

g1_finish
