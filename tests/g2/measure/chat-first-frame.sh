#!/usr/bin/env bash
# NFR-02 for the chat (EX2-13 method), development headless desktop: 200
# warm opens of the chat by its shortcut. Each sample runs from the moment
# the synthetic Super+A is injected (this script, wall clock) to the first
# frame the chat surface swaps (Shell's `ditto-mark … chat.frame`, same host
# and clock). The model is not involved: opening the chat never waits for
# it. Target p95 ≤150 ms. Headless software rendering: not the reference
# measurement with real presentation timing.
set -euo pipefail
export DITTO_ARTIFACTS="${DITTO_ARTIFACTS:-$(cd "$(dirname "$0")/../../.." && pwd)/artifacts/g2}"
source "$(cd "$(dirname "$0")/../../g1" && pwd)/lib/common.sh"
source "$WORKSPACE/tests/g1/lib/shell-fixture.sh"
WINDOW_PIDS=()
trap shell_fixture_stop EXIT INT TERM
runs="${1:-200}"
g1_begin g2-chat-first-frame "NFR-02 chat (development)"
g1_preflight
evidence="$(g1_evidence_dir)"
start_compositor >/dev/null
shell_fixture_start --hostd || { check fixture fail "the desktop did not come up"; g1_finish; }
samples="$evidence/samples.jsonl"; : >"$samples"
for i in $(seq 1 $((runs + 5))); do
  before="$(grep -c 'ditto-mark .* chat.frame' "$RUNTIME_DIR/core.log" || true)"
  t0="$(date +%s%3N)"
  "${G1_GUI[@]}" chord KEY_LEFTMETA KEY_A
  frame=""
  for _ in $(seq 1 100); do
    count="$(grep -c 'ditto-mark .* chat.frame' "$RUNTIME_DIR/core.log" || true)"
    if (( count > before )); then frame="$(grep -a 'ditto-mark .* chat.frame' "$RUNTIME_DIR/core.log" | tail -1 | sed -E 's/.*ditto-mark ([0-9]+) chat.frame.*/\1/')"; break; fi
    sleep 0.02
  done
  [[ -n "$frame" ]] || { check sample-$i fail "no chat frame after the shortcut"; break; }
  # The first five warm the path and are kept but not judged.
  printf '{"run":%d,"warmup":%s,"ms":%d}\n' "$i" "$([[ $i -le 5 ]] && echo true || echo false)" "$((frame - t0))" >>"$samples"
  "${G1_GUI[@]}" chord KEY_LEFTMETA KEY_A   # close again
  sleep 0.15
done
python3 - "$samples" <<'PYEOF' >"$evidence/summary.json"
import json, sys
xs = sorted(s["ms"] for s in map(json.loads, open(sys.argv[1])) if not s["warmup"])
p = lambda q: xs[min(len(xs) - 1, int(-(-q * len(xs) // 1)) - 1)]
print(json.dumps({"runs": len(xs), "p50_ms": p(0.5), "p95_ms": p(0.95), "max_ms": xs[-1], "target_p95_ms": 150}))
PYEOF
summary="$(cat "$evidence/summary.json")"
if jq -e '.runs >= 1 and .p95_ms <= 150' <<<"$summary" >/dev/null; then
  check chat-first-frame pass "warm chat open → first frame within target" "$summary"
else
  check chat-first-frame fail "warm chat open → first frame over target or no samples" "$summary"
fi
g1_finish
