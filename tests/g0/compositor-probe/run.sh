#!/usr/bin/env bash
# Run both probe layers against the compositor in this environment and keep the
# document. The capability matrix is written from these documents; rows this
# environment cannot exercise stay without a verdict.
set -euo pipefail

source "$(cd "$(dirname "$0")/.." && pwd)/lib/session.sh"

WINDOW_PIDS=()
trap stop_all EXIT INT TERM

RUN_ID="$(run_id)"
mkdir -p "$ARTIFACTS"
start_compositor
label="$(compositor_label)"
OUTPUT="$ARTIFACTS/compositor-probe-$label-$RUN_ID.json"
bash "$WORKSPACE/tools/compositor-probe/run.sh" "$label" --functional >"$OUTPUT"
python3 - "$OUTPUT" <<'PYEOF'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
print(f'{document["compositor_label"]}: {len(document["globals"])} globals, coverage {document["coverage"]}')
for result in document["functional_results"]:
    evidence = result["evidence"]
    if isinstance(evidence, list):
        state = ", ".join(f'{item["request"]}={item["observed"]}' for item in evidence) or "no result"
    elif evidence.get("probed") is False:
        state = f'not probed: {evidence["reason"]}'
    elif "supported" in evidence:
        state = f'supported={evidence["supported"]}' + (f' ({evidence.get("reason")})' if evidence.get("reason") else "")
    else:
        state = json.dumps(evidence, ensure_ascii=False)
    print(f'{result["row"]:6} {result["protocol"]:42} {state}')
PYEOF
echo "probe document -> $OUTPUT"
