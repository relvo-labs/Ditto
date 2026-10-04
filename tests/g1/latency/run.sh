#!/usr/bin/env bash
# EX1-11: local operations, plugin switches and application survival.
#   ① NFR-03: a simple local operation (switch workspace, focus a window,
#     change one appearance token), accepted → read back, p95 ≤100 ms, 200×;
#   ② NFR-04: an installed UI plugin switch (Dock A↔B), prepared → committed,
#     p95 ≤2 s, 100×; the Cordis service replacement listed separately;
#   ③ NFR-09: during those 300 operations no reference application ends
#     unexpectedly and Kate's unsaved buffer hash is unchanged.
# Timestamps are Core's (the updated_at of each state), never a UI estimate.
# ①②③ need the logged-in Wayfire session with the Shell and the reference
# applications. This fixture measures the Cordis service number of ② with the
# real hostd (enable and disable of the tasks service, 100 each). Samples go
# to artifacts/g1/latency-<run_id>.jsonl.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
trap g1_fixture_stop EXIT INT TERM

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
    "$(python3 -c 'import json,sys; e=json.loads(sys.argv[1])["evidence"]; e["samples"]=sys.argv[2]; print(json.dumps(e))' "$judged" "$samples")"
  g1_fixture_stop
fi

check local-operations environment "① NFR-03 needs the Wayfire session and the Shell (workspace, focus and an appearance token read back)"
check ui-plugin-switch environment "② NFR-04 Dock A↔B needs a Shell participant"
check application-survival environment "③ NFR-09 needs the reference applications (Firefox, foot, Kate) in the session"
g1_note "per-change samples: $samples"

g1_finish
